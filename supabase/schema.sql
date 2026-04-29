create extension if not exists pgcrypto;

do $$
begin
  if not exists (select 1 from pg_type where typname = 'user_role') then
    create type user_role as enum ('customer', 'electrician', 'admin');
  end if;
  if not exists (select 1 from pg_type where typname = 'electrician_status') then
    create type electrician_status as enum ('pending', 'approved', 'rejected', 'suspended');
  end if;
  if not exists (select 1 from pg_type where typname = 'job_status') then
    create type job_status as enum (
      'requested',
      'matching',
      'assigned',
      'accepted',
      'assessment_fee_pending',
      'assessment_payment_pending_verification',
      'assessment_confirmed',
      'en_route',
      'on_site',
      'quoted',
      'quote_accepted',
      'work_payment_pending_verification',
      'payment_confirmed',
      'work_in_progress',
      'electrician_completed',
      'customer_confirmed',
      'payout_pending',
      'payout_complete',
      'rated',
      'cancelled'
    );
  end if;
  if not exists (select 1 from pg_type where typname = 'job_urgency') then
    create type job_urgency as enum ('emergency', 'today', 'this_week');
  end if;
  if not exists (select 1 from pg_type where typname = 'payment_type') then
    create type payment_type as enum ('assessment_fee', 'quote_payment', 'material_payment', 'payout');
  end if;
  if not exists (select 1 from pg_type where typname = 'payment_status') then
    create type payment_status as enum ('submitted', 'verified', 'rejected');
  end if;
  if not exists (select 1 from pg_type where typname = 'notification_event') then
    create type notification_event as enum (
      'new_job_created',
      'electrician_assigned',
      'electrician_accepted',
      'payment_proof_submitted',
      'payment_verified',
      'quote_submitted',
      'work_completed',
      'payout_released'
    );
  end if;
end $$;

create table if not exists public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  role user_role not null default 'customer',
  full_name text not null default '',
  phone text,
  avatar_url text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.customers (
  id uuid primary key default gen_random_uuid(),
  profile_id uuid not null unique references public.profiles(id) on delete cascade,
  primary_service_area text,
  latitude double precision,
  longitude double precision,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.electricians (
  id uuid primary key default gen_random_uuid(),
  profile_id uuid not null unique references public.profiles(id) on delete cascade,
  status electrician_status not null default 'pending',
  years_experience integer not null default 0,
  service_areas text[] not null default '{}',
  location_label text,
  latitude double precision,
  longitude double precision,
  bank_name text,
  bank_account_number text,
  bank_account_name text,
  average_rating numeric(3,2) not null default 0,
  total_ratings integer not null default 0,
  completed_jobs integer not null default 0,
  availability_status text not null default 'available',
  last_offered_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.electrician_documents (
  id uuid primary key default gen_random_uuid(),
  electrician_id uuid not null references public.electricians(id) on delete cascade,
  document_type text not null,
  file_path text,
  file_url text,
  status text not null default 'pending',
  created_at timestamptz not null default now()
);

create table if not exists public.electrician_skills (
  id uuid primary key default gen_random_uuid(),
  electrician_id uuid not null references public.electricians(id) on delete cascade,
  category text not null,
  created_at timestamptz not null default now(),
  unique (electrician_id, category)
);

create table if not exists public.admin_settings (
  id uuid primary key default gen_random_uuid(),
  service_areas text[] not null default '{"Lekki Phase 1","Victoria Island","Ikeja","Surulere","Yaba","Ajah"}',
  issue_categories text[] not null default '{"Power outage","Wiring issue","Tripped breaker","Light fitting","Socket repair","Generator","CCTV Installation","Solar Installation","General Installation","Security Alarm","Inverter","Other"}',
  assessment_fee numeric(12,2) not null default 5000,
  ranking_weights jsonb not null default '{"distance":20,"rating":50,"availability":20,"completed_jobs":30,"skill_match":70}'::jsonb,
  platform_bank_name text not null default 'First Bank of Nigeria',
  platform_account_number text not null default '3012845678',
  platform_account_name text not null default 'Voltfriq Services Ltd',
  workmanship_prices jsonb not null default '[]'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.jobs (
  id uuid primary key default gen_random_uuid(),
  ticket text not null unique default ('VFQ-' || upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 8))),
  customer_id uuid not null references public.customers(id) on delete cascade,
  assigned_electrician_id uuid references public.electricians(id) on delete set null,
  service_area text not null,
  location_label text,
  latitude double precision,
  longitude double precision,
  issue_category text not null,
  urgency job_urgency not null default 'today',
  customer_note text,
  requires_assessment boolean not null default true,
  material_handling text not null default 'voltfriq_supplied',
  status job_status not null default 'requested',
  current_quote_id uuid,
  candidate_queue uuid[] not null default '{}',
  attempted_electrician_ids uuid[] not null default '{}',
  dispatch_attempts integer not null default 0,
  last_dispatch_at timestamptz,
  assignment_expires_at timestamptz,
  accepted_at timestamptz,
  customer_confirmed_at timestamptz,
  electrician_completed_at timestamptz,
  payout_released_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.job_photos (
  id uuid primary key default gen_random_uuid(),
  job_id uuid not null references public.jobs(id) on delete cascade,
  file_path text not null,
  created_at timestamptz not null default now()
);

create table if not exists public.job_quotes (
  id uuid primary key default gen_random_uuid(),
  job_id uuid not null references public.jobs(id) on delete cascade,
  electrician_id uuid not null references public.electricians(id) on delete cascade,
  findings text,
  measurements text,
  labor_total numeric(12,2) not null default 0,
  material_total numeric(12,2) not null default 0,
  grand_total numeric(12,2) not null default 0,
  created_at timestamptz not null default now()
);

create table if not exists public.quote_items (
  id uuid primary key default gen_random_uuid(),
  quote_id uuid not null references public.job_quotes(id) on delete cascade,
  item_type text not null default 'labor',
  description text not null,
  quantity numeric(12,2) not null default 1,
  unit_price numeric(12,2) not null default 0,
  line_total numeric(12,2) not null default 0,
  created_at timestamptz not null default now()
);

create table if not exists public.job_payments (
  id uuid primary key default gen_random_uuid(),
  job_id uuid not null references public.jobs(id) on delete cascade,
  submitted_by uuid not null references public.profiles(id) on delete cascade,
  payment_type payment_type not null,
  amount numeric(12,2) not null default 0,
  proof_path text,
  reference text,
  status payment_status not null default 'submitted',
  admin_note text,
  verified_by uuid references public.profiles(id) on delete set null,
  verified_at timestamptz,
  created_at timestamptz not null default now()
);

create table if not exists public.job_timeline (
  id uuid primary key default gen_random_uuid(),
  job_id uuid not null references public.jobs(id) on delete cascade,
  status job_status not null,
  note text,
  actor_profile_id uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now()
);

create table if not exists public.ratings (
  id uuid primary key default gen_random_uuid(),
  job_id uuid not null unique references public.jobs(id) on delete cascade,
  customer_id uuid not null references public.customers(id) on delete cascade,
  electrician_id uuid not null references public.electricians(id) on delete cascade,
  score integer not null check (score between 1 and 5),
  comment text,
  created_at timestamptz not null default now()
);

create table if not exists public.notifications (
  id uuid primary key default gen_random_uuid(),
  profile_id uuid not null references public.profiles(id) on delete cascade,
  job_id uuid references public.jobs(id) on delete cascade,
  event notification_event not null,
  title text not null,
  body text not null,
  metadata jsonb not null default '{}'::jsonb,
  read_at timestamptz,
  created_at timestamptz not null default now()
);

create table if not exists public.job_messages (
  id uuid primary key default gen_random_uuid(),
  job_id uuid not null references public.jobs(id) on delete cascade,
  sender_profile_id uuid not null references public.profiles(id) on delete cascade,
  sender_role user_role not null,
  message_type text not null default 'text',
  content jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);

alter table public.jobs
  add column if not exists attempted_electrician_ids uuid[] not null default '{}';

alter table public.jobs
  add constraint jobs_current_quote_fk
  foreign key (current_quote_id) references public.job_quotes(id) on delete set null;

create or replace function public.touch_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

drop trigger if exists profiles_touch_updated_at on public.profiles;
create trigger profiles_touch_updated_at before update on public.profiles for each row execute function public.touch_updated_at();
drop trigger if exists customers_touch_updated_at on public.customers;
create trigger customers_touch_updated_at before update on public.customers for each row execute function public.touch_updated_at();
drop trigger if exists electricians_touch_updated_at on public.electricians;
create trigger electricians_touch_updated_at before update on public.electricians for each row execute function public.touch_updated_at();
drop trigger if exists jobs_touch_updated_at on public.jobs;
create trigger jobs_touch_updated_at before update on public.jobs for each row execute function public.touch_updated_at();
drop trigger if exists admin_settings_touch_updated_at on public.admin_settings;
create trigger admin_settings_touch_updated_at before update on public.admin_settings for each row execute function public.touch_updated_at();

create or replace function public.handle_job_status_notifications()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  customer_profile uuid;
  electrician_profile uuid;
begin
  if tg_op <> 'UPDATE' or new.status = old.status then
    return new;
  end if;

  select c.profile_id into customer_profile from public.customers c where c.id = new.customer_id;
  select e.profile_id into electrician_profile from public.electricians e where e.id = new.assigned_electrician_id;

  if new.status = 'electrician_completed' and customer_profile is not null then
    perform public.create_notification(customer_profile, new.id, 'work_completed', 'Work marked complete', 'Your VoltFriq marked the job complete and is waiting for your confirmation.', '{}'::jsonb);
  end if;

  if new.status = 'payout_complete' then
    if customer_profile is not null then
      perform public.create_notification(customer_profile, new.id, 'payout_released', 'Payout released', 'The payout has been released and your receipt is ready.', '{}'::jsonb);
    end if;
    if electrician_profile is not null then
      perform public.create_notification(electrician_profile, new.id, 'payout_released', 'Payout released', 'Admin released payout for this completed job.', '{}'::jsonb);
    end if;
  end if;

  return new;
end;
$$;

drop trigger if exists jobs_status_notifications on public.jobs;
create trigger jobs_status_notifications after update on public.jobs for each row execute function public.handle_job_status_notifications();

create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  requested_role user_role;
begin
  requested_role := coalesce((new.raw_user_meta_data ->> 'requested_role')::user_role, 'customer');
  insert into public.profiles (id, role, full_name, phone)
  values (
    new.id,
    case when requested_role = 'admin' then 'customer' else requested_role end,
    coalesce(new.raw_user_meta_data ->> 'full_name', ''),
    new.raw_user_meta_data ->> 'phone'
  )
  on conflict (id) do nothing;
  return new;
exception
  when others then
    return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created after insert on auth.users for each row execute function public.handle_new_user();

create or replace function public.is_admin()
returns boolean
language sql
stable
as $$
  select exists (
    select 1
    from public.profiles
    where id = auth.uid() and role = 'admin'
  );
$$;

create or replace function public.current_customer_id()
returns uuid
language sql
stable
as $$
  select id from public.customers where profile_id = auth.uid() limit 1;
$$;

create or replace function public.current_electrician_id()
returns uuid
language sql
stable
as $$
  select id from public.electricians where profile_id = auth.uid() limit 1;
$$;

create or replace function public.create_notification(
  p_profile_id uuid,
  p_job_id uuid,
  p_event notification_event,
  p_title text,
  p_body text,
  p_metadata jsonb default '{}'::jsonb
)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.notifications (profile_id, job_id, event, title, body, metadata)
  values (p_profile_id, p_job_id, p_event, p_title, p_body, coalesce(p_metadata, '{}'::jsonb));
end;
$$;

create or replace function public.append_job_timeline(
  p_job_id uuid,
  p_status job_status,
  p_note text default null,
  p_actor_profile_id uuid default auth.uid()
)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.job_timeline (job_id, status, note, actor_profile_id)
  values (p_job_id, p_status, p_note, p_actor_profile_id);
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
  last_assigned_at timestamptz
)
language sql
security definer
set search_path = public
as $$
  with settings as (
    select coalesce((ranking_weights ->> 'max_distance_km')::numeric, 25) as max_distance_km
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
      e.last_offered_at as last_assigned_at
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
  select *
  from ranked
  order by
    distance_km asc,
    average_rating desc nulls last,
    completed_jobs desc,
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
    target_electrician := p_manual_electrician_id;
    candidate_list := array[]::uuid[];
    remaining_candidates := array[]::uuid[];
  else
    if coalesce(array_length(job_row.candidate_queue, 1), 0) > 0 then
      candidate_list := job_row.candidate_queue;
    else
      select array_agg(electrician_id order by distance_km asc, average_rating desc nulls last, completed_jobs desc, average_response_seconds asc nulls last, coalesce(last_assigned_at, to_timestamp(0)) asc)
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
      perform public.create_notification(admin_profile, p_job_id, 'new_job_created', 'Manual assignment required', 'No approved available VoltFriq accepted this job. Admin follow-up is needed.', '{}'::jsonb);
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

create or replace function public.create_customer_job(
  p_service_area text,
  p_location_label text,
  p_latitude double precision,
  p_longitude double precision,
  p_issue_category text,
  p_urgency job_urgency,
  p_customer_note text,
  p_requires_assessment boolean,
  p_material_handling text,
  p_photo_paths text[] default '{}'
)
returns public.jobs
language plpgsql
security definer
set search_path = public
as $$
declare
  customer_row public.customers;
  created_job public.jobs;
begin
  select * into customer_row from public.customers where profile_id = auth.uid();
  if not found then
    raise exception 'Customer profile not found';
  end if;

  insert into public.jobs (
    customer_id,
    service_area,
    location_label,
    latitude,
    longitude,
    issue_category,
    urgency,
    customer_note,
    requires_assessment,
    material_handling,
    status
  )
  values (
    customer_row.id,
    p_service_area,
    p_location_label,
    p_latitude,
    p_longitude,
    p_issue_category,
    p_urgency,
    p_customer_note,
    coalesce(p_requires_assessment, true),
    coalesce(p_material_handling, 'voltfriq_supplied'),
    'matching'
  )
  returning * into created_job;

  insert into public.job_photos (job_id, file_path)
  select created_job.id, photo_path
  from unnest(coalesce(p_photo_paths, '{}'::text[])) as photo_path;

  perform public.append_job_timeline(created_job.id, 'requested', 'Customer created a new booking request.', auth.uid());
  perform public.append_job_timeline(created_job.id, 'matching', 'Automatic dispatch started.', auth.uid());
  perform public.create_notification(auth.uid(), created_job.id, 'new_job_created', 'Booking created', 'We are finding the nearest verified VoltFriq for you.', '{}'::jsonb);

  select * into created_job from public.dispatch_job(created_job.id, null);
  return created_job;
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
  if job_row.assigned_electrician_id is distinct from electrician_row.id then
    raise exception 'Job is not assigned to this electrician';
  end if;

  update public.jobs
  set status = case when job_row.requires_assessment then 'assessment_fee_pending' else 'accepted' end,
      accepted_at = now(),
      assignment_expires_at = null
  where id = p_job_id
  returning * into job_row;

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
  if job_row.assigned_electrician_id is distinct from electrician_row.id then
    raise exception 'Job is not assigned to this electrician';
  end if;

  update public.jobs
  set status = 'matching',
      assigned_electrician_id = null
  where id = p_job_id
  returning * into job_row;

  perform public.append_job_timeline(p_job_id, 'matching', 'Assigned VoltFriq declined the booking. Re-dispatch started.', auth.uid());
  select * into job_row from public.dispatch_job(p_job_id, null);
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
    select id
    from public.jobs
    where status = 'assigned'
      and assignment_expires_at is not null
      and assignment_expires_at <= now()
  loop
    update public.jobs
    set status = 'matching',
        assigned_electrician_id = null,
        assignment_expires_at = null
    where id = expired_job.id;

    perform public.append_job_timeline(expired_job.id, 'matching', 'Assigned VoltFriq did not respond within 5 minutes. Re-dispatch started.', auth.uid());
    perform public.dispatch_job(expired_job.id, null);
    processed_count := processed_count + 1;
  end loop;

  for matching_job in
    select id
    from public.jobs
    where status = 'matching'
      and assigned_electrician_id is null
      and coalesce(array_length(candidate_queue, 1), 0) > 0
  loop
    perform public.dispatch_job(matching_job.id, null);
    processed_count := processed_count + 1;
  end loop;

  return processed_count;
end;
$$;

create or replace function public.submit_job_quote(
  p_job_id uuid,
  p_findings text,
  p_measurements text,
  p_items jsonb
)
returns public.job_quotes
language plpgsql
security definer
set search_path = public
as $$
declare
  electrician_row public.electricians;
  quote_row public.job_quotes;
  item jsonb;
  labor_total_value numeric := 0;
  material_total_value numeric := 0;
  line_total numeric := 0;
  customer_profile uuid;
begin
  select * into electrician_row from public.electricians where profile_id = auth.uid();
  if not found then
    raise exception 'Electrician profile not found';
  end if;

  insert into public.job_quotes (job_id, electrician_id, findings, measurements)
  values (p_job_id, electrician_row.id, p_findings, p_measurements)
  returning * into quote_row;

  for item in select * from jsonb_array_elements(coalesce(p_items, '[]'::jsonb))
  loop
    line_total := coalesce((item ->> 'quantity')::numeric, 1) * coalesce((item ->> 'unit_price')::numeric, 0);
    insert into public.quote_items (quote_id, item_type, description, quantity, unit_price, line_total)
    values (
      quote_row.id,
      coalesce(item ->> 'item_type', 'labor'),
      coalesce(item ->> 'description', 'Item'),
      coalesce((item ->> 'quantity')::numeric, 1),
      coalesce((item ->> 'unit_price')::numeric, 0),
      line_total
    );
    if coalesce(item ->> 'item_type', 'labor') = 'material' then
      material_total_value := material_total_value + line_total;
    else
      labor_total_value := labor_total_value + line_total;
    end if;
  end loop;

  update public.job_quotes
  set labor_total = labor_total_value,
      material_total = material_total_value,
      grand_total = labor_total_value + material_total_value
  where id = quote_row.id
  returning * into quote_row;

  update public.jobs
  set status = 'quoted',
      current_quote_id = quote_row.id
  where id = p_job_id;

  select c.profile_id into customer_profile
  from public.jobs j
  join public.customers c on c.id = j.customer_id
  where j.id = p_job_id;

  perform public.append_job_timeline(p_job_id, 'quoted', 'VoltFriq submitted a quote.', auth.uid());
  perform public.create_notification(customer_profile, p_job_id, 'quote_submitted', 'Quote ready', 'A new quote is ready for review.', jsonb_build_object('quote_id', quote_row.id));
  return quote_row;
end;
$$;

create or replace function public.submit_payment_proof(
  p_job_id uuid,
  p_payment_type payment_type,
  p_amount numeric,
  p_reference text,
  p_proof_path text
)
returns public.job_payments
language plpgsql
security definer
set search_path = public
as $$
declare
  payment_row public.job_payments;
begin
  insert into public.job_payments (job_id, submitted_by, payment_type, amount, proof_path, reference)
  values (p_job_id, auth.uid(), p_payment_type, coalesce(p_amount, 0), p_proof_path, p_reference)
  returning * into payment_row;

  update public.jobs
  set status = case
    when p_payment_type = 'assessment_fee' then 'assessment_payment_pending_verification'
    else 'work_payment_pending_verification'
  end
  where id = p_job_id;

  perform public.append_job_timeline(p_job_id, (select status from public.jobs where id = p_job_id), 'Payment proof submitted for manual verification.', auth.uid());
  perform public.create_notification(
    (select id from public.profiles where role = 'admin' order by created_at asc limit 1),
    p_job_id,
    'payment_proof_submitted',
    'Payment verification needed',
    'A customer submitted payment proof that needs review.',
    jsonb_build_object('payment_id', payment_row.id, 'payment_type', p_payment_type)
  );
  return payment_row;
end;
$$;

create or replace function public.verify_job_payment(
  p_payment_id uuid,
  p_approved boolean,
  p_admin_note text default null
)
returns public.job_payments
language plpgsql
security definer
set search_path = public
as $$
declare
  payment_row public.job_payments;
  next_status job_status;
  customer_profile uuid;
begin
  if not public.is_admin() then
    raise exception 'Admin access required';
  end if;

  select * into payment_row from public.job_payments where id = p_payment_id for update;
  if not found then
    raise exception 'Payment not found';
  end if;

  update public.job_payments
  set status = case when p_approved then 'verified' else 'rejected' end,
      admin_note = p_admin_note,
      verified_by = auth.uid(),
      verified_at = now()
  where id = p_payment_id
  returning * into payment_row;

  if p_approved then
    next_status := case
      when payment_row.payment_type = 'assessment_fee' then 'assessment_confirmed'
      else 'payment_confirmed'
    end;
  else
    next_status := case
      when payment_row.payment_type = 'assessment_fee' then 'assessment_fee_pending'
      else 'quote_accepted'
    end;
  end if;

  update public.jobs set status = next_status where id = payment_row.job_id;

  select c.profile_id into customer_profile
  from public.jobs j
  join public.customers c on c.id = j.customer_id
  where j.id = payment_row.job_id;

  perform public.append_job_timeline(payment_row.job_id, next_status, case when p_approved then 'Payment verified by admin.' else 'Payment rejected by admin.' end, auth.uid());
  if p_approved then
    perform public.create_notification(customer_profile, payment_row.job_id, 'payment_verified', 'Payment verified', 'Your payment was verified and the job can move forward.', jsonb_build_object('payment_id', payment_row.id));
  end if;
  return payment_row;
end;
$$;

create or replace function public.submit_rating(
  p_job_id uuid,
  p_score integer,
  p_comment text default null
)
returns public.ratings
language plpgsql
security definer
set search_path = public
as $$
declare
  customer_row public.customers;
  job_row public.jobs;
  rating_row public.ratings;
begin
  select * into customer_row from public.customers where profile_id = auth.uid();
  if not found then
    raise exception 'Customer profile not found';
  end if;

  select * into job_row from public.jobs where id = p_job_id;
  if not found then
    raise exception 'Job not found';
  end if;

  insert into public.ratings (job_id, customer_id, electrician_id, score, comment)
  values (p_job_id, customer_row.id, job_row.assigned_electrician_id, p_score, p_comment)
  on conflict (job_id) do update
  set score = excluded.score,
      comment = excluded.comment
  returning * into rating_row;

  update public.jobs set status = 'rated' where id = p_job_id;

  update public.electricians e
  set total_ratings = sub.total_ratings,
      average_rating = sub.average_rating,
      completed_jobs = greatest(completed_jobs, sub.completed_jobs)
  from (
    select
      electrician_id,
      count(*)::integer as total_ratings,
      round(avg(score)::numeric, 2) as average_rating,
      count(*)::integer as completed_jobs
    from public.ratings
    where electrician_id = job_row.assigned_electrician_id
    group by electrician_id
  ) sub
  where e.id = sub.electrician_id;

  perform public.append_job_timeline(p_job_id, 'rated', 'Customer submitted a rating.', auth.uid());
  return rating_row;
end;
$$;

insert into public.admin_settings (id)
select gen_random_uuid()
where not exists (select 1 from public.admin_settings);

alter table public.profiles enable row level security;
alter table public.customers enable row level security;
alter table public.electricians enable row level security;
alter table public.electrician_documents enable row level security;
alter table public.electrician_skills enable row level security;
alter table public.admin_settings enable row level security;
alter table public.jobs enable row level security;
alter table public.job_photos enable row level security;
alter table public.job_quotes enable row level security;
alter table public.quote_items enable row level security;
alter table public.job_payments enable row level security;
alter table public.job_timeline enable row level security;
alter table public.ratings enable row level security;
alter table public.notifications enable row level security;
alter table public.job_messages enable row level security;

create policy "profiles self or admin" on public.profiles
for select using (auth.uid() = id or public.is_admin());

create policy "profiles self update" on public.profiles
for update using (auth.uid() = id) with check (auth.uid() = id);

create policy "customers self or admin" on public.customers
for all using (profile_id = auth.uid() or public.is_admin())
with check (profile_id = auth.uid() or public.is_admin());

create policy "electricians self or admin read" on public.electricians
for select using (profile_id = auth.uid() or public.is_admin() or status = 'approved');

create policy "electricians self insert" on public.electricians
for insert with check (profile_id = auth.uid());

create policy "electricians self update or admin" on public.electricians
for update using (profile_id = auth.uid() or public.is_admin())
with check (profile_id = auth.uid() or public.is_admin());

create policy "electrician documents visible to owner or admin" on public.electrician_documents
for all using (
  public.is_admin() or exists (
    select 1 from public.electricians e where e.id = electrician_id and e.profile_id = auth.uid()
  )
)
with check (
  public.is_admin() or exists (
    select 1 from public.electricians e where e.id = electrician_id and e.profile_id = auth.uid()
  )
);

create policy "electrician skills visible broadly" on public.electrician_skills
for select using (true);

create policy "electrician skills owner or admin write" on public.electrician_skills
for all using (
  public.is_admin() or exists (
    select 1 from public.electricians e where e.id = electrician_id and e.profile_id = auth.uid()
  )
)
with check (
  public.is_admin() or exists (
    select 1 from public.electricians e where e.id = electrician_id and e.profile_id = auth.uid()
  )
);

create policy "admin settings readable by authenticated" on public.admin_settings
for select using (auth.uid() is not null);

create policy "admin settings admin write" on public.admin_settings
for all using (public.is_admin()) with check (public.is_admin());

create policy "jobs customer electrician or admin" on public.jobs
for select using (
  public.is_admin()
  or customer_id = public.current_customer_id()
  or assigned_electrician_id = public.current_electrician_id()
);

create policy "job photos customer electrician or admin" on public.job_photos
for select using (
  public.is_admin()
  or exists (select 1 from public.jobs j where j.id = job_id and (j.customer_id = public.current_customer_id() or j.assigned_electrician_id = public.current_electrician_id()))
);

create policy "job quotes customer electrician or admin" on public.job_quotes
for select using (
  public.is_admin()
  or exists (select 1 from public.jobs j where j.id = job_id and (j.customer_id = public.current_customer_id() or j.assigned_electrician_id = public.current_electrician_id()))
);

create policy "quote items customer electrician or admin" on public.quote_items
for select using (
  public.is_admin()
  or exists (
    select 1 from public.job_quotes q
    join public.jobs j on j.id = q.job_id
    where q.id = quote_id and (j.customer_id = public.current_customer_id() or j.assigned_electrician_id = public.current_electrician_id())
  )
);

create policy "job payments customer electrician or admin" on public.job_payments
for select using (
  public.is_admin()
  or exists (
    select 1 from public.jobs j
    where j.id = job_id and (j.customer_id = public.current_customer_id() or j.assigned_electrician_id = public.current_electrician_id())
  )
);

create policy "job timeline customer electrician or admin" on public.job_timeline
for select using (
  public.is_admin()
  or exists (
    select 1 from public.jobs j
    where j.id = job_id and (j.customer_id = public.current_customer_id() or j.assigned_electrician_id = public.current_electrician_id())
  )
);

create policy "ratings customer electrician or admin" on public.ratings
for select using (
  public.is_admin()
  or customer_id = public.current_customer_id()
  or electrician_id = public.current_electrician_id()
);

create policy "notifications own or admin" on public.notifications
for select using (profile_id = auth.uid() or public.is_admin());

create policy "notifications own update" on public.notifications
for update using (profile_id = auth.uid() or public.is_admin())
with check (profile_id = auth.uid() or public.is_admin());

create policy "job messages customer electrician or admin read" on public.job_messages
for select using (
  public.is_admin()
  or exists (
    select 1 from public.jobs j
    where j.id = job_id and (j.customer_id = public.current_customer_id() or j.assigned_electrician_id = public.current_electrician_id())
  )
);

create policy "job messages customer electrician or admin write" on public.job_messages
for insert with check (
  public.is_admin()
  or sender_profile_id = auth.uid()
);

insert into storage.buckets (id, name, public)
select 'avatars', 'avatars', true
where not exists (select 1 from storage.buckets where id = 'avatars');

insert into storage.buckets (id, name, public)
select 'electrician-documents', 'electrician-documents', false
where not exists (select 1 from storage.buckets where id = 'electrician-documents');

insert into storage.buckets (id, name, public)
select 'job-photos', 'job-photos', false
where not exists (select 1 from storage.buckets where id = 'job-photos');

insert into storage.buckets (id, name, public)
select 'payment-proofs', 'payment-proofs', false
where not exists (select 1 from storage.buckets where id = 'payment-proofs');
