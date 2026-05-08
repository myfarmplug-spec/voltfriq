-- Operational maturity pass:
-- - canonical job event log with public/internal separation
-- - idempotent dispatch/accept/reject guards
-- - admin queues and operational metrics

create table if not exists public.job_events (
  id uuid primary key default gen_random_uuid(),
  job_id uuid not null references public.jobs(id) on delete cascade,
  event_type text not null,
  actor_role text,
  actor_id uuid,
  public_message text,
  internal_note text,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);

do $$
begin
  if not exists (
    select 1
    from pg_constraint
    where conname = 'job_events_event_type_check'
      and conrelid = 'public.job_events'::regclass
  ) then
    alter table public.job_events
      add constraint job_events_event_type_check
      check (event_type in (
        'JOB_CREATED',
        'PAIRING_STARTED',
        'ELECTRICIAN_ASSIGNED',
        'ASSIGNMENT_ACCEPTED',
        'ASSIGNMENT_REJECTED',
        'ASSIGNMENT_EXPIRED',
        'PAYMENT_SUBMITTED',
        'PAYMENT_VERIFIED',
        'WORK_STARTED',
        'WORK_COMPLETED',
        'CUSTOMER_CONFIRMED',
        'DISPUTE_OPENED',
        'JOB_CANCELLED',
        'QUOTE_SUBMITTED',
        'PAYOUT_RELEASED',
        'RATING_SUBMITTED',
        'JOB_UPDATED'
      ));
  end if;
end $$;

create index if not exists job_events_job_created_idx
  on public.job_events (job_id, created_at);

create index if not exists job_events_type_created_idx
  on public.job_events (event_type, created_at desc);

alter table public.job_events enable row level security;

drop policy if exists "job events admin read" on public.job_events;
create policy "job events admin read" on public.job_events
for select
using (public.is_admin());

drop policy if exists "job events service role write" on public.job_events;
create policy "job events service role write" on public.job_events
for all
using (auth.role() = 'service_role')
with check (auth.role() = 'service_role');

revoke all on table public.job_events from public, anon, authenticated;
grant select on table public.job_events to authenticated;
grant all on table public.job_events to service_role;

alter table public.disputes
  add column if not exists guest_customer_id uuid references public.guest_customers(id) on delete cascade;

alter table public.disputes
  alter column customer_id drop not null;

create or replace function public.job_event_type_for_status(p_status public.job_status)
returns text
language sql
immutable
set search_path = public
as $$
  select case p_status::text
    when 'requested' then 'JOB_CREATED'
    when 'matching' then 'PAIRING_STARTED'
    when 'assigned' then 'ELECTRICIAN_ASSIGNED'
    when 'accepted' then 'ASSIGNMENT_ACCEPTED'
    when 'assessment_fee_pending' then 'ASSIGNMENT_ACCEPTED'
    when 'assessment_payment_pending_verification' then 'PAYMENT_SUBMITTED'
    when 'assessment_confirmed' then 'PAYMENT_VERIFIED'
    when 'en_route' then 'JOB_UPDATED'
    when 'on_site' then 'JOB_UPDATED'
    when 'quoted' then 'QUOTE_SUBMITTED'
    when 'quote_accepted' then 'QUOTE_SUBMITTED'
    when 'work_payment_pending_verification' then 'PAYMENT_SUBMITTED'
    when 'payment_confirmed' then 'PAYMENT_VERIFIED'
    when 'work_in_progress' then 'WORK_STARTED'
    when 'electrician_completed' then 'WORK_COMPLETED'
    when 'customer_confirmed' then 'CUSTOMER_CONFIRMED'
    when 'payout_pending' then 'CUSTOMER_CONFIRMED'
    when 'payout_complete' then 'PAYOUT_RELEASED'
    when 'rated' then 'RATING_SUBMITTED'
    when 'cancelled' then 'JOB_CANCELLED'
    else 'JOB_UPDATED'
  end;
$$;

create or replace function public.actor_role_for_profile(p_profile_id uuid)
returns text
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(
    (select role::text from public.profiles where id = p_profile_id limit 1),
    case when p_profile_id is null then 'system' else 'unknown' end
  );
$$;

create or replace function public.public_message_for_job_event(
  p_event_type text,
  p_status public.job_status default null,
  p_note text default null
) returns text
language sql
stable
set search_path = public
as $$
  select case
    when lower(coalesce(p_note, '')) like any (array[
      '%manual assignment required%',
      '%admin assignment%',
      '%admin manually assigned%',
      '%no electrician available%',
      '%dispatch failed%'
    ]) then 'VoltFriq support is helping route your request.'
    when p_event_type = 'JOB_CREATED' then 'Booking confirmed.'
    when p_event_type = 'PAIRING_STARTED' then 'Pairing you with a VoltFriq.'
    when p_event_type = 'ELECTRICIAN_ASSIGNED' then 'Electrician assigned.'
    when p_event_type = 'ASSIGNMENT_ACCEPTED' then 'Your VoltFriq has accepted the booking.'
    when p_event_type = 'ASSIGNMENT_REJECTED' then 'Pairing you with a VoltFriq.'
    when p_event_type = 'ASSIGNMENT_EXPIRED' then 'Still finding a verified VoltFriq near you.'
    when p_event_type = 'PAYMENT_SUBMITTED' then 'Payment proof received for review.'
    when p_event_type = 'PAYMENT_VERIFIED' then 'Payment confirmed.'
    when p_event_type = 'WORK_STARTED' then 'Work is in progress.'
    when p_event_type = 'WORK_COMPLETED' then 'Completed.'
    when p_event_type = 'CUSTOMER_CONFIRMED' then 'Completion confirmed.'
    when p_event_type = 'DISPUTE_OPENED' then 'VoltFriq support is reviewing your issue.'
    when p_event_type = 'JOB_CANCELLED' then 'Booking cancelled.'
    when p_event_type = 'QUOTE_SUBMITTED' then 'Your quote is ready.'
    when p_event_type = 'PAYOUT_RELEASED' then 'Job complete.'
    when p_event_type = 'RATING_SUBMITTED' then 'Thanks for rating your VoltFriq.'
    when p_status = 'en_route' then 'On the way.'
    when p_status = 'on_site' then 'Your VoltFriq is on site.'
    else public.guest_public_timeline_note(coalesce(p_status, 'matching'::public.job_status))
  end;
$$;

create or replace function public.log_job_event(
  p_job_id uuid,
  p_event_type text,
  p_actor_role text default null,
  p_actor_id uuid default auth.uid(),
  p_public_message text default null,
  p_internal_note text default null,
  p_metadata jsonb default '{}'::jsonb
) returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  event_id uuid;
  job_status_value public.job_status;
  event_public_message text;
begin
  select status into job_status_value
  from public.jobs
  where id = p_job_id;

  if not found then
    raise exception 'Job not found';
  end if;

  event_public_message := coalesce(
    nullif(btrim(p_public_message), ''),
    public.public_message_for_job_event(p_event_type, job_status_value, p_internal_note)
  );

  insert into public.job_events (
    job_id,
    event_type,
    actor_role,
    actor_id,
    public_message,
    internal_note,
    metadata
  )
  values (
    p_job_id,
    p_event_type,
    coalesce(nullif(p_actor_role, ''), public.actor_role_for_profile(p_actor_id)),
    p_actor_id,
    event_public_message,
    nullif(btrim(p_internal_note), ''),
    coalesce(p_metadata, '{}'::jsonb)
  )
  returning id into event_id;

  return event_id;
end;
$$;

create or replace function public.job_timeline_to_event()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  event_type_value text;
begin
  if coalesce(new.metadata, '{}'::jsonb) ? 'skip_job_event_log' then
    return new;
  end if;

  event_type_value := public.job_event_type_for_status(new.status);
  perform public.log_job_event(
    new.job_id,
    event_type_value,
    public.actor_role_for_profile(new.actor_profile_id),
    new.actor_profile_id,
    public.public_message_for_job_event(event_type_value, new.status, new.note),
    new.note,
    coalesce(new.metadata, '{}'::jsonb) || jsonb_build_object('timeline_id', new.id)
  );
  return new;
end;
$$;

drop trigger if exists job_timeline_to_event_trigger on public.job_timeline;
create trigger job_timeline_to_event_trigger
after insert on public.job_timeline
for each row
execute function public.job_timeline_to_event();

create or replace function public.append_job_timeline(
  p_job_id uuid,
  p_status public.job_status,
  p_note text default null,
  p_actor_profile_id uuid default auth.uid()
) returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  event_type_value text;
  safe_note text;
begin
  event_type_value := public.job_event_type_for_status(p_status);
  safe_note := public.public_message_for_job_event(event_type_value, p_status, p_note);

  perform public.log_job_event(
    p_job_id,
    event_type_value,
    public.actor_role_for_profile(p_actor_profile_id),
    p_actor_profile_id,
    safe_note,
    p_note,
    '{}'::jsonb
  );

  insert into public.job_timeline (job_id, status, note, actor_profile_id, metadata)
  values (
    p_job_id,
    p_status,
    safe_note,
    p_actor_profile_id,
    jsonb_build_object('skip_job_event_log', true)
  );
end;
$$;

create or replace function public.get_public_job_events(
  p_job_id uuid,
  p_access_token text default null
) returns table (
  id uuid,
  job_id uuid,
  event_type text,
  public_message text,
  created_at timestamptz
)
language plpgsql
security definer
set search_path = public
as $$
declare
  can_read boolean;
begin
  select exists (
    select 1
    from public.jobs j
    where j.id = p_job_id
      and (
        public.is_admin()
        or j.customer_id = public.current_customer_id()
        or j.assigned_electrician_id = public.current_electrician_id()
        or (
          p_access_token is not null
          and j.customer_access_token = p_access_token
          and j.guest_customer_id is not null
        )
      )
  ) into can_read;

  if not can_read then
    raise exception 'Job not found';
  end if;

  return query
  select e.id, e.job_id, e.event_type, e.public_message, e.created_at
  from public.job_events e
  where e.job_id = p_job_id
    and nullif(btrim(e.public_message), '') is not null
  order by e.created_at asc, e.id asc;
end;
$$;

create or replace function public.get_admin_job_events(p_job_id uuid default null)
returns table (
  id uuid,
  job_id uuid,
  event_type text,
  actor_role text,
  actor_id uuid,
  public_message text,
  internal_note text,
  metadata jsonb,
  created_at timestamptz
)
language plpgsql
security definer
set search_path = public
as $$
begin
  if not (public.is_admin() or auth.role() = 'service_role') then
    raise exception 'Admin access required';
  end if;

  return query
  select e.id, e.job_id, e.event_type, e.actor_role, e.actor_id, e.public_message, e.internal_note, e.metadata, e.created_at
  from public.job_events e
  where p_job_id is null or e.job_id = p_job_id
  order by e.created_at asc, e.id asc;
end;
$$;

create or replace function public.admin_operational_summary()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  result jsonb;
begin
  if not (public.is_admin() or auth.role() = 'service_role') then
    raise exception 'Admin access required';
  end if;

  with queue_counts as (
    select
      (select count(*) from public.job_payments where status = 'submitted') as pending_payments,
      (select count(*) from public.electricians where status = 'pending') as pending_electricians,
      (select count(*) from public.disputes where status = 'open') as open_disputes,
      (
        select count(*)
        from public.jobs
        where status = 'assigned'
          and assignment_expires_at is not null
          and assignment_expires_at <= now()
      ) as expired_assignments,
      (
        select count(*)
        from public.jobs
        where (
          status = 'matching'
          and coalesce(last_dispatch_at, updated_at, created_at) < now() - interval '5 minutes'
        ) or (
          status = 'assigned'
          and coalesce(assignment_expires_at, last_dispatch_at + interval '5 minutes', updated_at + interval '5 minutes') <= now()
        ) or (
          status in ('assessment_payment_pending_verification', 'work_payment_pending_verification')
          and updated_at < now() - interval '30 minutes'
        ) or (
          status = 'electrician_completed'
          and coalesce(electrician_completed_at, updated_at) < now() - interval '24 hours'
        )
      ) as stuck_jobs
  ),
  created_events as (
    select job_id, min(created_at) as created_at
    from public.job_events
    where event_type = 'JOB_CREATED'
    group by job_id
  ),
  assigned_events as (
    select job_id, min(created_at) as assigned_at
    from public.job_events
    where event_type = 'ELECTRICIAN_ASSIGNED'
    group by job_id
  ),
  accepted_events as (
    select job_id, min(created_at) as accepted_at
    from public.job_events
    where event_type = 'ASSIGNMENT_ACCEPTED'
    group by job_id
  ),
  payment_submitted as (
    select job_id, min(created_at) as submitted_at
    from public.job_events
    where event_type = 'PAYMENT_SUBMITTED'
    group by job_id
  ),
  payment_verified as (
    select job_id, min(created_at) as verified_at
    from public.job_events
    where event_type = 'PAYMENT_VERIFIED'
    group by job_id
  ),
  metric_counts as (
    select
      (
        select avg(extract(epoch from (a.assigned_at - c.created_at)))
        from created_events c
        join assigned_events a on a.job_id = c.job_id
        where a.assigned_at >= c.created_at
      ) as avg_time_to_assign_seconds,
      (
        select avg(extract(epoch from (ac.accepted_at - a.assigned_at)))
        from assigned_events a
        join accepted_events ac on ac.job_id = a.job_id
        where ac.accepted_at >= a.assigned_at
      ) as avg_time_to_accept_seconds,
      (
        select case
          when count(*) filter (where event_type = 'ELECTRICIAN_ASSIGNED') = 0 then 0
          else (
            count(*) filter (where event_type = 'ASSIGNMENT_REJECTED')
          )::numeric / nullif(count(*) filter (where event_type = 'ELECTRICIAN_ASSIGNED'), 0)::numeric * 100
        end
        from public.job_events
      ) as rejection_rate,
      (
        select avg(extract(epoch from (v.verified_at - s.submitted_at)))
        from payment_submitted s
        join payment_verified v on v.job_id = s.job_id
        where v.verified_at >= s.submitted_at
      ) as payment_verification_delay_seconds
  )
  select jsonb_build_object(
    'queues', jsonb_build_object(
      'pending_payments', coalesce(q.pending_payments, 0),
      'pending_electricians', coalesce(q.pending_electricians, 0),
      'stuck_pairing_jobs', coalesce(q.stuck_jobs, 0),
      'open_disputes', coalesce(q.open_disputes, 0),
      'expired_assignments', coalesce(q.expired_assignments, 0)
    ),
    'metrics', jsonb_build_object(
      'average_time_to_assign_seconds', coalesce(round(m.avg_time_to_assign_seconds::numeric, 1), 0),
      'average_time_to_accept_seconds', coalesce(round(m.avg_time_to_accept_seconds::numeric, 1), 0),
      'rejection_rate', coalesce(round(m.rejection_rate::numeric, 1), 0),
      'payment_verification_delay_seconds', coalesce(round(m.payment_verification_delay_seconds::numeric, 1), 0),
      'stuck_jobs_count', coalesce(q.stuck_jobs, 0)
    )
  )
  into result
  from queue_counts q
  cross join metric_counts m;

  return coalesce(result, jsonb_build_object(
    'queues', '{}'::jsonb,
    'metrics', '{}'::jsonb
  ));
end;
$$;

create or replace function public.guest_job_payload(
  p_job_id uuid,
  p_access_token text
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  payload jsonb;
begin
  select jsonb_strip_nulls(jsonb_build_object(
    'id', j.id,
    'ticket', j.ticket,
    'status', j.status,
    'issue_category', j.issue_category,
    'urgency', j.urgency,
    'location_label', j.location_label,
    'created_at', j.created_at,
    'assigned_electrician', case when e.id is null then null else jsonb_build_object(
      'display_name', coalesce(nullif(p.full_name, ''), 'VoltFriq'),
      'avatar_url', p.avatar_url,
      'rating', e.average_rating
    ) end,
    'progress_timeline', coalesce((
      select jsonb_agg(jsonb_build_object(
        'event_type', event.event_type,
        'note', event.public_message,
        'created_at', event.created_at
      ) order by event.created_at, event.id)
      from public.job_events event
      where event.job_id = j.id
        and nullif(btrim(event.public_message), '') is not null
    ), '[]'::jsonb),
    'quote_summary', (
      select jsonb_build_object(
        'total', q.grand_total,
        'created_at', q.created_at
      )
      from public.job_quotes q
      where q.job_id = j.id
      order by q.created_at desc
      limit 1
    ),
    'payment_status', (
      select payment.status
      from public.job_payments payment
      where payment.job_id = j.id
      order by payment.created_at desc
      limit 1
    )
  ))
  into payload
  from public.jobs j
  left join public.electricians e on e.id = j.assigned_electrician_id
  left join public.profiles p on p.id = e.profile_id
  where j.id = p_job_id
    and j.customer_access_token = p_access_token;

  if payload is null then
    raise exception 'Guest job not found';
  end if;

  return payload;
end;
$$;

create or replace function public.dispatch_job(
  p_job_id uuid,
  p_manual_electrician_id uuid default null
) returns public.jobs
language plpgsql
security definer
set search_path = public
as $$
begin
  if not (public.is_admin() or auth.role() = 'service_role') then
    raise exception 'Admin or service role required';
  end if;

  return public.dispatch_job_internal(p_job_id, p_manual_electrician_id);
end;
$$;

create or replace function public.dispatch_job_internal(
  p_job_id uuid,
  p_manual_electrician_id uuid default null
) returns public.jobs
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
  actor_profile_id uuid;
  job_row public.jobs;
begin
  select * into job_row from public.jobs where id = p_job_id for update;
  if not found then
    raise exception 'Job not found';
  end if;

  if job_row.status = 'cancelled' then
    raise exception 'Cancelled jobs cannot be dispatched';
  end if;

  if job_row.status = 'assigned'
     and job_row.assignment_expires_at is not null
     and job_row.assignment_expires_at > now() then
    if p_manual_electrician_id is null or p_manual_electrician_id = job_row.assigned_electrician_id then
      return job_row;
    end if;
    raise exception 'This job already has an active assignment. Wait for expiry, rejection, or cancel before overriding.';
  end if;

  if p_manual_electrician_id is not null and job_row.status not in ('requested', 'matching', 'assigned') then
    raise exception 'Only unaccepted jobs can be reassigned';
  end if;

  if p_manual_electrician_id is null and job_row.status not in ('requested', 'matching', 'assigned') then
    return job_row;
  end if;

  select c.profile_id into customer_profile from public.customers c where c.id = job_row.customer_id;
  actor_profile_id := coalesce(auth.uid(), customer_profile);

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
    perform public.append_job_timeline(p_job_id, 'matching', 'No electrician available yet. Manual assignment required.', actor_profile_id);
    if admin_profile is not null then
      perform public.create_notification(admin_profile, p_job_id, 'job_stuck', 'Manual assignment required', 'No approved available VoltFriq accepted this job. Admin follow-up is needed.', '{}'::jsonb);
    end if;
    return job_row;
  end if;

  update public.jobs
  set status = 'assigned',
      assigned_electrician_id = target_electrician,
      candidate_queue = coalesce(remaining_candidates, '{}'::uuid[]),
      attempted_electrician_ids = case
        when target_electrician = any(coalesce(attempted_electrician_ids, '{}'::uuid[])) then attempted_electrician_ids
        else array_append(coalesce(attempted_electrician_ids, '{}'::uuid[]), target_electrician)
      end,
      dispatch_attempts = dispatch_attempts + 1,
      last_dispatch_at = now(),
      assignment_expires_at = now() + interval '5 minutes'
  where id = p_job_id
    and status in ('requested', 'matching', 'assigned')
  returning * into job_row;

  if job_row.id is null then
    raise exception 'Job could not be assigned because its state changed';
  end if;

  update public.electricians
  set last_offered_at = now()
  where id = target_electrician;

  select e.profile_id into assigned_profile from public.electricians e where e.id = target_electrician;

  perform public.append_job_timeline(
    p_job_id,
    'assigned',
    case
      when p_manual_electrician_id is not null then 'Admin manually assigned a VoltFriq to this job.'
      else 'Nearest available VoltFriq dispatched to the job.'
    end,
    actor_profile_id
  );
  perform public.create_notification(customer_profile, p_job_id, 'electrician_assigned', 'VoltFriq assigned', 'A verified VoltFriq has been dispatched to your job.', jsonb_build_object('electrician_id', target_electrician));
  perform public.create_notification(assigned_profile, p_job_id, 'electrician_assigned', 'New booking request', 'A nearby customer needs help in your service area.', jsonb_build_object('job_id', p_job_id));
  return job_row;
end;
$$;

create or replace function public.electrician_accept_job(p_job_id uuid)
returns public.jobs
language plpgsql
security definer
set search_path = public
as $$
declare
  job_row public.jobs;
  electrician_row public.electricians;
  customer_profile uuid;
begin
  select * into electrician_row from public.electricians where profile_id = auth.uid();
  if not found then
    raise exception 'Electrician profile not found';
  end if;

  select * into job_row from public.jobs where id = p_job_id for update;
  if not found then
    raise exception 'Job not found';
  end if;

  if job_row.assigned_electrician_id is distinct from electrician_row.id then
    raise exception 'Job is not assigned to this electrician';
  end if;

  if job_row.status <> 'assigned' then
    raise exception 'Only assigned jobs can be accepted';
  end if;

  if job_row.assignment_expires_at is not null and job_row.assignment_expires_at <= now() then
    perform public.log_job_event(
      p_job_id,
      'ASSIGNMENT_EXPIRED',
      'electrician',
      auth.uid(),
      'Still finding a verified VoltFriq near you.',
      'Electrician attempted to accept after assignment expiry.',
      jsonb_build_object('electrician_id', electrician_row.id)
    );
    raise exception 'This assignment has expired and can no longer be accepted.';
  end if;

  update public.jobs
  set status = case
        when job_row.requires_assessment then 'assessment_fee_pending'::job_status
        else 'accepted'::job_status
      end,
      accepted_at = now(),
      assignment_expires_at = null
  where id = p_job_id
    and status = 'assigned'
    and assigned_electrician_id = electrician_row.id
    and (assignment_expires_at is null or assignment_expires_at > now())
  returning * into job_row;

  if job_row.id is null then
    raise exception 'This job was already accepted, rejected, or expired.';
  end if;

  select c.profile_id into customer_profile from public.customers c where c.id = job_row.customer_id;
  perform public.append_job_timeline(p_job_id, job_row.status, 'VoltFriq accepted the booking.', auth.uid());
  perform public.create_notification(customer_profile, p_job_id, 'electrician_accepted', 'VoltFriq accepted', 'Your assigned VoltFriq accepted the booking.', '{}'::jsonb);
  return job_row;
end;
$$;

create or replace function public.electrician_reject_job(p_job_id uuid)
returns public.jobs
language plpgsql
security definer
set search_path = public
as $$
declare
  electrician_row public.electricians;
  job_row public.jobs;
begin
  select * into electrician_row from public.electricians where profile_id = auth.uid();
  if not found then
    raise exception 'Electrician profile not found';
  end if;

  select * into job_row from public.jobs where id = p_job_id for update;
  if not found then
    raise exception 'Job not found';
  end if;

  if job_row.assigned_electrician_id is distinct from electrician_row.id then
    raise exception 'Job is not assigned to this electrician';
  end if;

  if job_row.status <> 'assigned' then
    raise exception 'Only pending assignments can be rejected';
  end if;

  if job_row.assignment_expires_at is not null and job_row.assignment_expires_at <= now() then
    raise exception 'This assignment has already expired.';
  end if;

  perform public.log_job_event(
    p_job_id,
    'ASSIGNMENT_REJECTED',
    'electrician',
    auth.uid(),
    'Pairing you with a VoltFriq.',
    'Assigned VoltFriq declined the booking. Re-dispatch started.',
    jsonb_build_object('electrician_id', electrician_row.id)
  );

  update public.jobs
  set status = 'matching',
      assigned_electrician_id = null,
      assignment_expires_at = null
  where id = p_job_id
    and status = 'assigned'
    and assigned_electrician_id = electrician_row.id
  returning * into job_row;

  if job_row.id is null then
    raise exception 'This assignment is no longer available.';
  end if;

  perform public.append_job_timeline(p_job_id, 'matching', 'Assigned VoltFriq declined the booking. Re-dispatch started.', auth.uid());
  select * into job_row from public.dispatch_job_internal(p_job_id, null);
  return job_row;
end;
$$;

create or replace function public.process_dispatch_queue()
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  expired_job record;
  matching_job record;
  processed_count integer := 0;
begin
  for expired_job in
    select id, assigned_electrician_id
    from public.jobs
    where status = 'assigned'
      and assignment_expires_at is not null
      and assignment_expires_at <= now()
    for update skip locked
  loop
    update public.jobs
    set status = 'matching',
        assigned_electrician_id = null,
        assignment_expires_at = null
    where id = expired_job.id
      and status = 'assigned'
      and assignment_expires_at is not null
      and assignment_expires_at <= now();

    perform public.log_job_event(
      expired_job.id,
      'ASSIGNMENT_EXPIRED',
      'system',
      auth.uid(),
      'Still finding a verified VoltFriq near you.',
      'Assigned VoltFriq did not respond within 5 minutes. Re-dispatch started.',
      jsonb_build_object('electrician_id', expired_job.assigned_electrician_id)
    );
    perform public.append_job_timeline(expired_job.id, 'matching', 'Assigned VoltFriq did not respond within 5 minutes. Re-dispatch started.', auth.uid());
    perform public.dispatch_job_internal(expired_job.id, null);
    processed_count := processed_count + 1;
  end loop;

  for matching_job in
    select id
    from public.jobs
    where status = 'matching'
      and assigned_electrician_id is null
      and coalesce(array_length(candidate_queue, 1), 0) > 0
    for update skip locked
  loop
    perform public.dispatch_job_internal(matching_job.id, null);
    processed_count := processed_count + 1;
  end loop;

  return processed_count;
end;
$$;

create or replace function public.create_dispute(
  p_job_id uuid,
  p_issue_type text,
  p_details text default null
) returns public.disputes
language plpgsql
security definer
set search_path = public
as $$
declare
  customer_row public.customers;
  job_row public.jobs;
  dispute_row public.disputes;
  admin_profile uuid;
begin
  select * into customer_row
  from public.customers
  where profile_id = auth.uid();

  if not found then
    raise exception 'Customer profile not found';
  end if;

  select * into job_row
  from public.jobs
  where id = p_job_id
    and customer_id = customer_row.id
  for update;

  if not found then
    raise exception 'Job not found';
  end if;

  insert into public.disputes (job_id, customer_id, electrician_id, issue_type, details)
  values (p_job_id, customer_row.id, job_row.assigned_electrician_id, p_issue_type, p_details)
  returning * into dispute_row;

  perform public.log_job_event(
    p_job_id,
    'DISPUTE_OPENED',
    'customer',
    auth.uid(),
    'VoltFriq support is reviewing your issue.',
    'Customer reported an issue: ' || coalesce(p_issue_type, 'general dispute') || '.',
    jsonb_build_object('dispute_id', dispute_row.id, 'issue_type', p_issue_type)
  );
  perform public.append_job_timeline(p_job_id, job_row.status, 'Customer reported an issue: ' || coalesce(p_issue_type, 'general dispute') || '.', auth.uid());
  select id into admin_profile from public.profiles where role = 'admin' order by created_at asc limit 1;
  if admin_profile is not null then
    perform public.create_notification(admin_profile, p_job_id, 'dispute_raised', 'Dispute raised', 'A customer reported an issue and admin review is needed.', jsonb_build_object('dispute_id', dispute_row.id, 'issue_type', p_issue_type));
  end if;

  return dispute_row;
end;
$$;

create or replace function public.create_guest_dispute(
  p_job_id uuid,
  p_access_token text,
  p_issue_type text,
  p_details text default null,
  p_phone_confirmation text default null
) returns public.disputes
language plpgsql
security definer
set search_path = public
as $$
declare
  job_row public.jobs;
  guest_phone text;
  dispute_row public.disputes;
  admin_profile uuid;
begin
  select * into job_row
  from public.jobs
  where id = p_job_id
    and customer_access_token = p_access_token
    and guest_customer_id is not null
  for update;

  if not found then
    raise exception 'Guest job not found';
  end if;

  if job_row.created_at < now() - interval '30 days' then
    raise exception 'This guest action link has expired. Contact VoltFriq support to continue.';
  end if;

  select phone into guest_phone
  from public.guest_customers
  where id = job_row.guest_customer_id;

  if right(regexp_replace(coalesce(guest_phone, ''), '\D', '', 'g'), 4) <> right(regexp_replace(coalesce(p_phone_confirmation, ''), '\D', '', 'g'), 4) then
    raise exception 'Confirm the phone number used for this booking.';
  end if;

  insert into public.disputes (job_id, customer_id, guest_customer_id, electrician_id, issue_type, details)
  values (p_job_id, null, job_row.guest_customer_id, job_row.assigned_electrician_id, p_issue_type, p_details)
  returning * into dispute_row;

  perform public.log_job_event(
    p_job_id,
    'DISPUTE_OPENED',
    'guest',
    null,
    'VoltFriq support is reviewing your issue.',
    'Guest customer reported an issue: ' || coalesce(p_issue_type, 'general dispute') || '.',
    jsonb_build_object('dispute_id', dispute_row.id, 'issue_type', p_issue_type)
  );

  select id into admin_profile from public.profiles where role = 'admin' order by created_at asc limit 1;
  if admin_profile is not null then
    perform public.create_notification(admin_profile, p_job_id, 'dispute_raised', 'Guest dispute raised', 'A guest customer reported an issue and admin review is needed.', jsonb_build_object('dispute_id', dispute_row.id, 'issue_type', p_issue_type));
  end if;

  return dispute_row;
end;
$$;

create or replace function public.verify_job_payment(
  p_payment_id uuid,
  p_approved boolean,
  p_admin_note text default null
) returns public.job_payments
language plpgsql
security definer
set search_path = public
as $$
declare
  payment_row public.job_payments;
  job_row public.jobs;
  next_status job_status;
  customer_profile uuid;
  electrician_profile uuid;
begin
  if not public.is_admin() then
    raise exception 'Admin access required';
  end if;

  select * into payment_row from public.job_payments where id = p_payment_id for update;
  if not found then
    raise exception 'Payment not found';
  end if;

  select * into job_row from public.jobs where id = payment_row.job_id for update;
  if not found then
    raise exception 'Job not found';
  end if;

  if job_row.status = 'cancelled' then
    raise exception 'Cancelled jobs cannot receive payment verification.';
  end if;

  update public.job_payments
  set status = case when p_approved then 'verified'::payment_status else 'rejected'::payment_status end,
      admin_note = p_admin_note,
      verified_by = auth.uid(),
      verified_at = now()
  where id = p_payment_id
  returning * into payment_row;

  if p_approved then
    next_status := case
      when payment_row.payment_type = 'assessment_fee' then 'assessment_confirmed'::job_status
      else 'payment_confirmed'::job_status
    end;
  else
    next_status := case
      when payment_row.payment_type = 'assessment_fee' then 'assessment_fee_pending'::job_status
      else 'quote_accepted'::job_status
    end;
  end if;

  update public.jobs
  set status = next_status
  where id = payment_row.job_id
  returning * into job_row;

  select c.profile_id into customer_profile
  from public.jobs j
  join public.customers c on c.id = j.customer_id
  where j.id = payment_row.job_id;

  select e.profile_id into electrician_profile
  from public.jobs j
  join public.electricians e on e.id = j.assigned_electrician_id
  where j.id = payment_row.job_id;

  perform public.append_job_timeline(payment_row.job_id, next_status, case when p_approved then 'Payment verified by admin.' else 'Payment rejected by admin.' end, auth.uid());
  if p_approved then
    perform public.create_notification(customer_profile, payment_row.job_id, 'payment_verified', 'Payment verified', 'Your payment was verified and the job can move forward.', jsonb_build_object('payment_id', payment_row.id));
    perform public.create_notification(electrician_profile, payment_row.job_id, 'payment_verified', 'Payment confirmed', 'Admin verified customer payment for this job.', jsonb_build_object('payment_id', payment_row.id));
  end if;
  return payment_row;
end;
$$;

grant execute on function public.get_public_job_events(uuid,text) to anon, authenticated, service_role;
grant execute on function public.get_admin_job_events(uuid) to authenticated, service_role;
grant execute on function public.admin_operational_summary() to authenticated, service_role;
grant execute on function public.create_guest_dispute(uuid,text,text,text,text) to anon, authenticated, service_role;
grant execute on function public.job_event_type_for_status(public.job_status) to service_role;
grant execute on function public.public_message_for_job_event(text,public.job_status,text) to service_role;
grant execute on function public.actor_role_for_profile(uuid) to service_role;
grant execute on function public.log_job_event(uuid,text,text,uuid,text,text,jsonb) to service_role;
grant execute on function public.job_timeline_to_event() to service_role;

revoke all on function public.process_dispatch_queue() from public, anon, authenticated;
grant execute on function public.process_dispatch_queue() to service_role;
revoke all on function public.append_job_timeline(uuid,public.job_status,text,uuid) from public, anon, authenticated;
grant execute on function public.append_job_timeline(uuid,public.job_status,text,uuid) to service_role;
revoke all on function public.create_notification(uuid,uuid,public.notification_event,text,text,jsonb) from public, anon, authenticated;
grant execute on function public.create_notification(uuid,uuid,public.notification_event,text,text,jsonb) to service_role;

notify pgrst, 'reload schema';
