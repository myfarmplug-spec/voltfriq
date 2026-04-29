do $$
begin
  if not exists (
    select 1 from pg_enum
    where enumtypid = 'notification_event'::regtype
      and enumlabel = 'electrician_suspended'
  ) then
    alter type notification_event add value 'electrician_suspended';
  end if;
  if not exists (
    select 1 from pg_enum
    where enumtypid = 'notification_event'::regtype
      and enumlabel = 'appeal_submitted'
  ) then
    alter type notification_event add value 'appeal_submitted';
  end if;
  if not exists (
    select 1 from pg_enum
    where enumtypid = 'notification_event'::regtype
      and enumlabel = 'appeal_resolved'
  ) then
    alter type notification_event add value 'appeal_resolved';
  end if;
  if not exists (
    select 1 from pg_enum
    where enumtypid = 'notification_event'::regtype
      and enumlabel = 'review_submitted'
  ) then
    alter type notification_event add value 'review_submitted';
  end if;
end $$;

alter table public.admin_settings
  add column if not exists trust_settings jsonb not null default '{
    "negative_rating_limit": 3,
    "negative_rating_max_score": 2,
    "watchlist_rank_penalty_km": 8,
    "rising_jobs": 3,
    "trusted_jobs": 10,
    "top_rated_jobs": 25,
    "elite_jobs": 60
  }'::jsonb;

alter table public.electricians
  add column if not exists level_badge text not null default 'Verified Pro',
  add column if not exists negative_rating_count integer not null default 0,
  add column if not exists last_suspended_negative_count integer not null default 0,
  add column if not exists watchlist boolean not null default false,
  add column if not exists watchlist_reason text,
  add column if not exists suspended_reason text,
  add column if not exists suspended_at timestamptz;

alter table public.customers
  add column if not exists average_behavior_rating numeric(3,2) not null default 0,
  add column if not exists total_behavior_ratings integer not null default 0,
  add column if not exists completed_requests integer not null default 0,
  add column if not exists cancellation_count integer not null default 0,
  add column if not exists no_show_reports integer not null default 0,
  add column if not exists dispute_count integer not null default 0,
  add column if not exists payment_issue_count integer not null default 0,
  add column if not exists trust_status text not null default 'clear',
  add column if not exists trust_notes text;

alter table public.ratings
  drop constraint if exists ratings_job_id_key;

alter table public.ratings
  add column if not exists review_direction text not null default 'customer_to_electrician',
  add column if not exists reviewer_profile_id uuid references public.profiles(id) on delete set null,
  add column if not exists reviewee_profile_id uuid references public.profiles(id) on delete set null,
  add column if not exists reviewee_role user_role,
  add column if not exists behavior_tags text[] not null default '{}';

update public.ratings r
set review_direction = coalesce(r.review_direction, 'customer_to_electrician'),
    reviewer_profile_id = coalesce(r.reviewer_profile_id, c.profile_id),
    reviewee_profile_id = coalesce(r.reviewee_profile_id, e.profile_id),
    reviewee_role = coalesce(r.reviewee_role, 'electrician'::user_role)
from public.customers c, public.electricians e
where r.customer_id = c.id
  and r.electrician_id = e.id
  and r.review_direction = 'customer_to_electrician';

do $$
begin
  if not exists (
    select 1 from pg_constraint
    where conname = 'ratings_job_direction_key'
      and conrelid = 'public.ratings'::regclass
  ) then
    alter table public.ratings
      add constraint ratings_job_direction_key unique (job_id, review_direction);
  end if;
end $$;

create table if not exists public.electrician_appeals (
  id uuid primary key default gen_random_uuid(),
  electrician_id uuid not null references public.electricians(id) on delete cascade,
  status text not null default 'open',
  appeal_note text not null,
  supporting_file_path text,
  admin_note text,
  reviewed_by uuid references public.profiles(id) on delete set null,
  reviewed_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint electrician_appeals_status_check check (status in ('open', 'approved', 'rejected'))
);

create index if not exists electrician_appeals_electrician_id_idx
on public.electrician_appeals (electrician_id);

create index if not exists ratings_review_direction_idx
on public.ratings (review_direction);

create or replace function public.calculate_electrician_level(
  p_completed_jobs integer,
  p_average_rating numeric,
  p_total_ratings integer,
  p_response_rate numeric,
  p_watchlist boolean
)
returns text
language sql
stable
as $$
  select case
    when coalesce(p_watchlist, false) then 'Verified Pro'
    when coalesce(p_completed_jobs, 0) >= 60
      and coalesce(p_average_rating, 0) >= 4.8
      and coalesce(p_total_ratings, 0) >= 20
      and coalesce(p_response_rate, 0) >= 85 then 'Elite Pro'
    when coalesce(p_completed_jobs, 0) >= 25
      and coalesce(p_average_rating, 0) >= 4.6
      and coalesce(p_total_ratings, 0) >= 10
      and coalesce(p_response_rate, 0) >= 75 then 'Top Rated'
    when coalesce(p_completed_jobs, 0) >= 10
      and coalesce(p_average_rating, 0) >= 4.3
      and coalesce(p_total_ratings, 0) >= 5
      and coalesce(p_response_rate, 0) >= 60 then 'Trusted Pro'
    when coalesce(p_completed_jobs, 0) >= 3
      and coalesce(p_average_rating, 0) >= 4.0
      and coalesce(p_total_ratings, 0) >= 2 then 'Rising Pro'
    else 'Verified Pro'
  end;
$$;

create or replace function public.electrician_level_rank(p_level text)
returns integer
language sql
stable
as $$
  select case p_level
    when 'Elite Pro' then 5
    when 'Top Rated' then 4
    when 'Trusted Pro' then 3
    when 'Rising Pro' then 2
    else 1
  end;
$$;

create or replace function public.refresh_customer_trust_metrics(p_customer_id uuid)
returns public.customers
language plpgsql
security definer
set search_path = public
as $$
declare
  updated_row public.customers;
begin
  update public.customers c
  set total_behavior_ratings = coalesce(stats.total_behavior_ratings, 0),
      average_behavior_rating = coalesce(stats.average_behavior_rating, 0),
      completed_requests = coalesce(stats.completed_requests, 0),
      cancellation_count = coalesce(stats.cancellation_count, 0),
      no_show_reports = coalesce(stats.no_show_reports, 0),
      dispute_count = coalesce(stats.dispute_count, 0),
      payment_issue_count = coalesce(stats.payment_issue_count, 0),
      trust_status = case
        when coalesce(stats.average_behavior_rating, 5) < 3 and coalesce(stats.total_behavior_ratings, 0) >= 3 then 'review_required'
        when coalesce(stats.dispute_count, 0) >= 3 then 'review_required'
        when coalesce(stats.payment_issue_count, 0) >= 2 then 'review_required'
        when coalesce(stats.average_behavior_rating, 5) < 4 and coalesce(stats.total_behavior_ratings, 0) >= 2 then 'watch'
        when coalesce(stats.dispute_count, 0) > 0 then 'watch'
        else 'clear'
      end
  from (
    select
      c2.id as customer_id,
      (
        select count(*)::integer
        from public.ratings r
        where r.customer_id = c2.id
          and r.review_direction = 'electrician_to_customer'
      ) as total_behavior_ratings,
      (
        select round(avg(r.score)::numeric, 2)
        from public.ratings r
        where r.customer_id = c2.id
          and r.review_direction = 'electrician_to_customer'
      ) as average_behavior_rating,
      (
        select count(*)::integer
        from public.jobs j
        where j.customer_id = c2.id
          and j.status in ('customer_confirmed', 'payout_pending', 'payout_complete', 'rated')
      ) as completed_requests,
      (
        select count(*)::integer
        from public.jobs j
        where j.customer_id = c2.id
          and j.status = 'cancelled'
      ) as cancellation_count,
      (
        select count(*)::integer
        from public.ratings r
        where r.customer_id = c2.id
          and r.review_direction = 'electrician_to_customer'
          and 'no_show' = any(coalesce(r.behavior_tags, '{}'::text[]))
      ) as no_show_reports,
      (
        select count(*)::integer
        from public.disputes d
        where d.customer_id = c2.id
      ) as dispute_count,
      (
        select count(*)::integer
        from public.job_payments p
        join public.jobs j on j.id = p.job_id
        where j.customer_id = c2.id
          and p.status = 'rejected'
      ) as payment_issue_count
    from public.customers c2
    where c2.id = p_customer_id
  ) stats
  where c.id = stats.customer_id
  returning c.* into updated_row;

  return updated_row;
end;
$$;

create or replace function public.refresh_electrician_trust_metrics(p_electrician_id uuid)
returns public.electricians
language plpgsql
security definer
set search_path = public
as $$
declare
  updated_row public.electricians;
  negative_limit integer := 3;
  negative_max_score integer := 2;
  admin_profile uuid;
begin
  select coalesce((trust_settings ->> 'negative_rating_limit')::integer, 3),
         coalesce((trust_settings ->> 'negative_rating_max_score')::integer, 2)
  into negative_limit, negative_max_score
  from public.admin_settings
  order by updated_at desc
  limit 1;

  update public.electricians e
  set total_ratings = coalesce(stats.total_ratings, 0),
      average_rating = coalesce(stats.average_rating, 0),
      completed_jobs = coalesce(stats.completed_jobs, 0),
      response_rate = coalesce(stats.response_rate, 0),
      negative_rating_count = coalesce(stats.negative_rating_count, 0),
      level_badge = public.calculate_electrician_level(
        coalesce(stats.completed_jobs, 0),
        coalesce(stats.average_rating, 0),
        coalesce(stats.total_ratings, 0),
        coalesce(stats.response_rate, 0),
        e.watchlist
      )
  from (
    select
      e2.id as electrician_id,
      (
        select count(*)::integer
        from public.ratings r
        where r.electrician_id = e2.id
          and r.review_direction = 'customer_to_electrician'
      ) as total_ratings,
      (
        select round(avg(r.score)::numeric, 2)
        from public.ratings r
        where r.electrician_id = e2.id
          and r.review_direction = 'customer_to_electrician'
      ) as average_rating,
      (
        select count(*)::integer
        from public.jobs j
        where j.assigned_electrician_id = e2.id
          and j.status in ('customer_confirmed', 'payout_pending', 'payout_complete', 'rated')
      ) as completed_jobs,
      (
        select count(*)::integer
        from public.ratings r
        where r.electrician_id = e2.id
          and r.review_direction = 'customer_to_electrician'
          and r.score <= negative_max_score
      ) as negative_rating_count,
      (
        case
          when (
            select count(*)
            from public.jobs j
            where e2.id = any(coalesce(j.attempted_electrician_ids, '{}'::uuid[]))
          ) = 0 then 0
          else round(
            (
              (
                select count(*)
                from public.jobs j
                where j.assigned_electrician_id = e2.id
                  and j.accepted_at is not null
              )::numeric
              /
              (
                select count(*)
                from public.jobs j
                where e2.id = any(coalesce(j.attempted_electrician_ids, '{}'::uuid[]))
              )::numeric
            ) * 100,
            2
          )
        end
      ) as response_rate
    from public.electricians e2
    where e2.id = p_electrician_id
  ) stats
  where e.id = stats.electrician_id
  returning e.* into updated_row;

  if updated_row.id is not null
    and updated_row.negative_rating_count >= negative_limit
    and updated_row.negative_rating_count > updated_row.last_suspended_negative_count
    and updated_row.status = 'approved'
  then
    update public.electricians
    set status = 'suspended',
        availability_status = 'offline',
        suspended_reason = 'Automatic suspension after ' || updated_row.negative_rating_count || ' negative customer ratings.',
        suspended_at = now(),
        last_suspended_negative_count = updated_row.negative_rating_count
    where id = p_electrician_id
    returning * into updated_row;

    perform public.create_notification(
      updated_row.profile_id,
      null,
      'electrician_suspended',
      'Account temporarily suspended',
      'Your VoltFriq account was suspended after repeated negative ratings. You can submit an appeal for admin review.',
      jsonb_build_object('negative_rating_count', updated_row.negative_rating_count)
    );

    for admin_profile in
      select id from public.profiles where role = 'admin'
    loop
      perform public.create_notification(
        admin_profile,
        null,
        'electrician_suspended',
        'VoltFriq auto-suspended',
        'A VoltFriq reached the negative rating limit and needs admin review.',
        jsonb_build_object('electrician_id', p_electrician_id, 'negative_rating_count', updated_row.negative_rating_count)
      );
    end loop;
  end if;

  return updated_row;
end;
$$;

drop function if exists public.find_matching_electricians(text, text, double precision, double precision, integer);

create or replace function public.find_matching_electricians(
  p_service_area text,
  p_issue_category text,
  p_latitude double precision default null,
  p_longitude double precision default null,
  p_limit integer default 5
)
returns table (
  electrician_id uuid,
  profile_id uuid,
  full_name text,
  phone text,
  avatar_url text,
  service_areas text[],
  years_experience integer,
  average_rating numeric,
  completed_jobs integer,
  availability_status text,
  distance_km numeric,
  average_response_seconds numeric,
  last_assigned_at timestamptz,
  level_badge text,
  watchlist boolean,
  negative_rating_count integer,
  level_rank integer
)
language sql
security definer
set search_path = public
as $$
  with settings as (
    select
      coalesce((ranking_weights ->> 'max_distance_km')::numeric, 25) as max_distance_km,
      coalesce((trust_settings ->> 'watchlist_rank_penalty_km')::numeric, 8) as watchlist_rank_penalty_km
    from public.admin_settings
    order by updated_at desc
    limit 1
  ),
  ranked as (
    select
      e.id as electrician_id,
      e.profile_id,
      p.full_name,
      p.phone,
      p.avatar_url,
      e.service_areas,
      e.years_experience,
      e.average_rating,
      e.completed_jobs,
      e.availability_status,
      case
        when p_latitude is null or p_longitude is null or e.latitude is null or e.longitude is null then 999
        else (
          6371 * acos(
            least(1, greatest(-1,
              cos(radians(p_latitude)) * cos(radians(e.latitude)) * cos(radians(e.longitude) - radians(p_longitude)) +
              sin(radians(p_latitude)) * sin(radians(e.latitude))
            ))
          )
        )
      end as distance_km,
      (
        select round(avg(extract(epoch from (j.accepted_at - j.last_dispatch_at)))::numeric, 2)
        from public.jobs j
        where j.assigned_electrician_id = e.id
          and j.accepted_at is not null
          and j.last_dispatch_at is not null
          and j.accepted_at >= j.last_dispatch_at
      ) as average_response_seconds,
      e.last_offered_at as last_assigned_at,
      e.level_badge,
      e.watchlist,
      e.negative_rating_count,
      public.electrician_level_rank(e.level_badge) as level_rank,
      settings.watchlist_rank_penalty_km
    from public.electricians e
    join public.profiles p on p.id = e.profile_id
    cross join settings
    where e.status = 'approved'
      and e.availability_status = 'available'
      and exists (
        select 1 from public.electrician_skills s
        where s.electrician_id = e.id and s.category = p_issue_category
      )
      and (
        p_service_area = any(e.service_areas)
        or p_service_area is null
        or (
          p_latitude is not null
          and p_longitude is not null
          and e.latitude is not null
          and e.longitude is not null
          and (
            6371 * acos(
              least(1, greatest(-1,
                cos(radians(p_latitude)) * cos(radians(e.latitude)) * cos(radians(e.longitude) - radians(p_longitude)) +
                sin(radians(p_latitude)) * sin(radians(e.latitude))
              ))
            )
          ) <= settings.max_distance_km
        )
      )
  )
  select
    electrician_id,
    profile_id,
    full_name,
    phone,
    avatar_url,
    service_areas,
    years_experience,
    average_rating,
    completed_jobs,
    availability_status,
    distance_km,
    average_response_seconds,
    last_assigned_at,
    level_badge,
    watchlist,
    negative_rating_count,
    level_rank
  from ranked
  order by
    (distance_km + case when watchlist then watchlist_rank_penalty_km else 0 end) asc,
    average_rating desc nulls last,
    completed_jobs desc,
    level_rank desc,
    average_response_seconds asc nulls last,
    coalesce(last_assigned_at, to_timestamp(0)) asc
  limit greatest(p_limit, 1);
$$;

create or replace function public.dispatch_job(
  p_job_id uuid,
  p_manual_electrician_id uuid default null
)
returns public.jobs
language plpgsql
security definer
set search_path = public
as $$
declare
  target_electrician uuid;
  candidate_list uuid[];
  remaining_candidates uuid[];
  customer_profile uuid;
  assigned_profile uuid;
  admin_profile uuid;
  job_row public.jobs;
begin
  select * into job_row from public.jobs where id = p_job_id for update;
  if not found then
    raise exception 'Job not found';
  end if;

  if p_manual_electrician_id is not null then
    select id into target_electrician
    from public.electricians
    where id = p_manual_electrician_id
      and status = 'approved';
    if target_electrician is null then
      raise exception 'Only approved VoltFriqs can be assigned to jobs';
    end if;
    candidate_list := array[]::uuid[];
    remaining_candidates := array[]::uuid[];
  else
    if coalesce(array_length(job_row.candidate_queue, 1), 0) > 0 then
      candidate_list := job_row.candidate_queue;
    else
      select array_agg(electrician_id order by (distance_km + case when watchlist then 8 else 0 end) asc, average_rating desc nulls last, completed_jobs desc, level_rank desc, average_response_seconds asc nulls last, coalesce(last_assigned_at, to_timestamp(0)) asc)
      into candidate_list
      from public.find_matching_electricians(job_row.service_area, job_row.issue_category, job_row.latitude, job_row.longitude, 10)
      where electrician_id <> all(coalesce(job_row.attempted_electrician_ids, '{}'::uuid[]));
    end if;

    target_electrician := candidate_list[1];
    remaining_candidates := case
      when coalesce(array_length(candidate_list, 1), 0) > 1 then candidate_list[2:array_length(candidate_list, 1)]
      else array[]::uuid[]
    end;
  end if;

  if target_electrician is null then
    update public.jobs
    set status = 'matching',
        assigned_electrician_id = null,
        candidate_queue = coalesce(remaining_candidates, '{}'::uuid[]),
        dispatch_attempts = dispatch_attempts + 1,
        last_dispatch_at = now(),
        assignment_expires_at = null
    where id = p_job_id
    returning * into job_row;

    select id into admin_profile from public.profiles where role = 'admin' order by created_at asc limit 1;
    perform public.append_job_timeline(p_job_id, 'matching', 'No electrician available yet. Manual assignment required.', auth.uid());
    if admin_profile is not null then
      perform public.create_notification(admin_profile, p_job_id, 'job_stuck', 'Manual assignment required', 'No approved available VoltFriq accepted this job. Admin follow-up is needed.', '{}'::jsonb);
    end if;
    return job_row;
  end if;

  update public.jobs
  set status = 'assigned',
      assigned_electrician_id = target_electrician,
      candidate_queue = coalesce(remaining_candidates, '{}'::uuid[]),
      attempted_electrician_ids = array_append(coalesce(attempted_electrician_ids, '{}'::uuid[]), target_electrician),
      dispatch_attempts = dispatch_attempts + 1,
      last_dispatch_at = now(),
      assignment_expires_at = now() + interval '5 minutes'
  where id = p_job_id
  returning * into job_row;

  update public.electricians
  set last_offered_at = now()
  where id = target_electrician;

  select c.profile_id into customer_profile from public.customers c where c.id = job_row.customer_id;
  select e.profile_id into assigned_profile from public.electricians e where e.id = target_electrician;

  perform public.append_job_timeline(
    p_job_id,
    'assigned',
    case
      when p_manual_electrician_id is not null then 'Admin manually assigned a VoltFriq to this job.'
      else 'Nearest available VoltFriq dispatched to the job.'
    end,
    auth.uid()
  );
  perform public.create_notification(customer_profile, p_job_id, 'electrician_assigned', 'VoltFriq assigned', 'A verified VoltFriq has been dispatched to your job.', jsonb_build_object('electrician_id', target_electrician));
  perform public.create_notification(assigned_profile, p_job_id, 'electrician_assigned', 'New booking request', 'A nearby customer needs help in your service area.', jsonb_build_object('job_id', p_job_id));
  return job_row;
end;
$$;

create or replace function public.submit_rating(
  p_job_id uuid,
  p_score integer,
  p_comment text default null,
  p_behavior_tags text[] default '{}'::text[]
)
returns public.ratings
language plpgsql
security definer
set search_path = public
as $$
declare
  customer_row public.customers;
  job_row public.jobs;
  electrician_profile uuid;
  rating_row public.ratings;
begin
  if p_score < 1 or p_score > 5 then
    raise exception 'Rating must be between 1 and 5';
  end if;

  select * into customer_row from public.customers where profile_id = auth.uid();
  if not found then
    raise exception 'Customer profile not found';
  end if;

  select * into job_row from public.jobs where id = p_job_id;
  if not found then
    raise exception 'Job not found';
  end if;

  if job_row.customer_id is distinct from customer_row.id then
    raise exception 'You can only rate your own job';
  end if;

  if job_row.assigned_electrician_id is null then
    raise exception 'No VoltFriq was assigned to this job';
  end if;

  select profile_id into electrician_profile
  from public.electricians
  where id = job_row.assigned_electrician_id;

  insert into public.ratings (
    job_id,
    customer_id,
    electrician_id,
    score,
    comment,
    review_direction,
    reviewer_profile_id,
    reviewee_profile_id,
    reviewee_role,
    behavior_tags
  )
  values (
    p_job_id,
    customer_row.id,
    job_row.assigned_electrician_id,
    p_score,
    p_comment,
    'customer_to_electrician',
    auth.uid(),
    electrician_profile,
    'electrician',
    coalesce(p_behavior_tags, '{}'::text[])
  )
  on conflict on constraint ratings_job_direction_key do update
  set score = excluded.score,
      comment = excluded.comment,
      reviewer_profile_id = excluded.reviewer_profile_id,
      reviewee_profile_id = excluded.reviewee_profile_id,
      reviewee_role = excluded.reviewee_role,
      behavior_tags = excluded.behavior_tags
  returning * into rating_row;

  update public.jobs set status = 'rated' where id = p_job_id;
  perform public.refresh_electrician_trust_metrics(job_row.assigned_electrician_id);
  perform public.reward_completed_referral(auth.uid(), p_job_id);
  perform public.append_job_timeline(p_job_id, 'rated', 'Customer submitted a VoltFriq rating.', auth.uid());
  perform public.create_notification(electrician_profile, p_job_id, 'review_submitted', 'Customer review received', 'A customer submitted feedback for your completed job.', jsonb_build_object('score', p_score));
  return rating_row;
end;
$$;

create or replace function public.submit_customer_review(
  p_job_id uuid,
  p_score integer,
  p_comment text default null,
  p_behavior_tags text[] default '{}'::text[]
)
returns public.ratings
language plpgsql
security definer
set search_path = public
as $$
declare
  electrician_row public.electricians;
  job_row public.jobs;
  customer_profile uuid;
  rating_row public.ratings;
begin
  if p_score < 1 or p_score > 5 then
    raise exception 'Rating must be between 1 and 5';
  end if;

  select * into electrician_row from public.electricians where profile_id = auth.uid();
  if not found then
    raise exception 'Electrician profile not found';
  end if;

  select * into job_row from public.jobs where id = p_job_id;
  if not found then
    raise exception 'Job not found';
  end if;

  if job_row.assigned_electrician_id is distinct from electrician_row.id then
    raise exception 'You can only review customers for jobs assigned to you';
  end if;

  if job_row.status not in ('electrician_completed', 'customer_confirmed', 'payout_pending', 'payout_complete', 'rated') then
    raise exception 'Customer review is available after work completion';
  end if;

  select profile_id into customer_profile
  from public.customers
  where id = job_row.customer_id;

  insert into public.ratings (
    job_id,
    customer_id,
    electrician_id,
    score,
    comment,
    review_direction,
    reviewer_profile_id,
    reviewee_profile_id,
    reviewee_role,
    behavior_tags
  )
  values (
    p_job_id,
    job_row.customer_id,
    electrician_row.id,
    p_score,
    p_comment,
    'electrician_to_customer',
    auth.uid(),
    customer_profile,
    'customer',
    coalesce(p_behavior_tags, '{}'::text[])
  )
  on conflict on constraint ratings_job_direction_key do update
  set score = excluded.score,
      comment = excluded.comment,
      reviewer_profile_id = excluded.reviewer_profile_id,
      reviewee_profile_id = excluded.reviewee_profile_id,
      reviewee_role = excluded.reviewee_role,
      behavior_tags = excluded.behavior_tags
  returning * into rating_row;

  perform public.refresh_customer_trust_metrics(job_row.customer_id);
  perform public.append_job_timeline(p_job_id, job_row.status, 'VoltFriq submitted a private customer behavior review.', auth.uid());
  return rating_row;
end;
$$;

create or replace function public.submit_electrician_appeal(
  p_appeal_note text,
  p_supporting_file_path text default null
)
returns public.electrician_appeals
language plpgsql
security definer
set search_path = public
as $$
declare
  electrician_row public.electricians;
  appeal_row public.electrician_appeals;
  admin_profile uuid;
begin
  select * into electrician_row from public.electricians where profile_id = auth.uid();
  if not found then
    raise exception 'Electrician profile not found';
  end if;

  if electrician_row.status <> 'suspended' then
    raise exception 'Appeals are only available for suspended accounts';
  end if;

  if p_appeal_note is null or length(btrim(p_appeal_note)) < 20 then
    raise exception 'Add a short appeal note so admin can review your case';
  end if;

  insert into public.electrician_appeals (electrician_id, appeal_note, supporting_file_path)
  values (electrician_row.id, btrim(p_appeal_note), p_supporting_file_path)
  returning * into appeal_row;

  for admin_profile in
    select id from public.profiles where role = 'admin'
  loop
    perform public.create_notification(
      admin_profile,
      null,
      'appeal_submitted',
      'Suspension appeal submitted',
      'A suspended VoltFriq submitted an appeal for admin review.',
      jsonb_build_object('electrician_id', electrician_row.id, 'appeal_id', appeal_row.id)
    );
  end loop;

  return appeal_row;
end;
$$;

create or replace function public.resolve_electrician_appeal(
  p_appeal_id uuid,
  p_approved boolean,
  p_admin_note text default null
)
returns public.electrician_appeals
language plpgsql
security definer
set search_path = public
as $$
declare
  appeal_row public.electrician_appeals;
  electrician_profile uuid;
begin
  if not public.is_admin() then
    raise exception 'Only admins can resolve appeals';
  end if;

  update public.electrician_appeals
  set status = case when p_approved then 'approved' else 'rejected' end,
      admin_note = p_admin_note,
      reviewed_by = auth.uid(),
      reviewed_at = now(),
      updated_at = now()
  where id = p_appeal_id
  returning * into appeal_row;

  if appeal_row.id is null then
    raise exception 'Appeal not found';
  end if;

  if p_approved then
    update public.electricians
    set status = 'approved',
        availability_status = 'available',
        watchlist = true,
        watchlist_reason = coalesce(p_admin_note, 'Restored after suspension appeal.'),
        suspended_reason = null
    where id = appeal_row.electrician_id;
  end if;

  select profile_id into electrician_profile
  from public.electricians
  where id = appeal_row.electrician_id;

  perform public.create_notification(
    electrician_profile,
    null,
    'appeal_resolved',
    case when p_approved then 'Appeal approved' else 'Appeal rejected' end,
    case when p_approved then 'Your VoltFriq account is active again and will be monitored on watchlist.' else 'Your appeal was reviewed and your account remains suspended.' end,
    jsonb_build_object('appeal_id', appeal_row.id, 'approved', p_approved)
  );

  return appeal_row;
end;
$$;

create or replace function public.admin_set_electrician_status(
  p_electrician_id uuid,
  p_status electrician_status,
  p_reason text default null
)
returns public.electricians
language plpgsql
security definer
set search_path = public
as $$
declare
  updated_row public.electricians;
begin
  if not public.is_admin() then
    raise exception 'Only admins can update VoltFriq status';
  end if;

  update public.electricians
  set status = p_status,
      availability_status = case when p_status = 'approved' then 'available' else 'offline' end,
      suspended_reason = case when p_status = 'suspended' then coalesce(p_reason, 'Suspended by admin.') else suspended_reason end,
      suspended_at = case when p_status = 'suspended' then now() else suspended_at end
  where id = p_electrician_id
  returning * into updated_row;

  if updated_row.id is null then
    raise exception 'Electrician not found';
  end if;

  return updated_row;
end;
$$;

create or replace function public.admin_set_electrician_watchlist(
  p_electrician_id uuid,
  p_watchlist boolean,
  p_reason text default null
)
returns public.electricians
language plpgsql
security definer
set search_path = public
as $$
declare
  updated_row public.electricians;
begin
  if not public.is_admin() then
    raise exception 'Only admins can update watchlist status';
  end if;

  update public.electricians
  set watchlist = p_watchlist,
      watchlist_reason = case when p_watchlist then coalesce(p_reason, 'Admin watchlist review.') else null end
  where id = p_electrician_id
  returning * into updated_row;

  if updated_row.id is null then
    raise exception 'Electrician not found';
  end if;

  perform public.refresh_electrician_trust_metrics(p_electrician_id);
  select * into updated_row from public.electricians where id = p_electrician_id;
  return updated_row;
end;
$$;

alter table public.electrician_appeals enable row level security;

drop policy if exists "electrician appeals own or admin read" on public.electrician_appeals;
create policy "electrician appeals own or admin read" on public.electrician_appeals
for select using (
  public.is_admin()
  or electrician_id = public.current_electrician_id()
);

drop policy if exists "electrician appeals own insert" on public.electrician_appeals;
create policy "electrician appeals own insert" on public.electrician_appeals
for insert with check (
  electrician_id = public.current_electrician_id()
  or public.is_admin()
);

drop policy if exists "electrician appeals admin update" on public.electrician_appeals;
create policy "electrician appeals admin update" on public.electrician_appeals
for update using (public.is_admin()) with check (public.is_admin());

drop trigger if exists electrician_appeals_touch_updated_at on public.electrician_appeals;
create trigger electrician_appeals_touch_updated_at
before update on public.electrician_appeals
for each row execute function public.touch_updated_at();

update public.electricians e
set total_ratings = coalesce(stats.total_ratings, 0),
    average_rating = coalesce(stats.average_rating, 0),
    completed_jobs = coalesce(stats.completed_jobs, 0),
    negative_rating_count = coalesce(stats.negative_rating_count, 0),
    level_badge = public.calculate_electrician_level(
      coalesce(stats.completed_jobs, 0),
      coalesce(stats.average_rating, 0),
      coalesce(stats.total_ratings, 0),
      coalesce(e.response_rate, 0),
      e.watchlist
    )
from (
  select
    e2.id as electrician_id,
    count(r.id)::integer as total_ratings,
    round(avg(r.score)::numeric, 2) as average_rating,
    count(case when r.score <= 2 then 1 end)::integer as negative_rating_count,
    (
      select count(*)::integer
      from public.jobs j
      where j.assigned_electrician_id = e2.id
        and j.status in ('customer_confirmed', 'payout_pending', 'payout_complete', 'rated')
    ) as completed_jobs
  from public.electricians e2
  left join public.ratings r on r.electrician_id = e2.id
    and r.review_direction = 'customer_to_electrician'
  group by e2.id
) stats
where e.id = stats.electrician_id;

select public.refresh_customer_trust_metrics(id)
from public.customers;
