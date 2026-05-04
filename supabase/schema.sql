-- Auto-generated from supabase/migrations.
-- Rebuild with ./scripts/rebuild-schema.sh


-- >>> 20260429003500_initial_schema.sql
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
  match_score numeric
)
language sql
security definer
set search_path = public
as $$
  with ranked as (
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
        case when p_service_area = any(e.service_areas) then 30 else 0 end +
        case when exists (
          select 1 from public.electrician_skills s
          where s.electrician_id = e.id and s.category = p_issue_category
        ) then 70 else 0 end +
        coalesce(e.average_rating, 0) * 12 +
        least(coalesce(e.completed_jobs, 0), 100) * 0.6 +
        case when e.availability_status = 'available' then 20 else 0 end -
        case
          when p_latitude is null or p_longitude is null or e.latitude is null or e.longitude is null then 0
          else least(40, (
            6371 * acos(
              least(1, greatest(-1,
                cos(radians(p_latitude)) * cos(radians(e.latitude)) * cos(radians(e.longitude) - radians(p_longitude)) +
                sin(radians(p_latitude)) * sin(radians(e.latitude))
              ))
            )
          ))
        end
      )::numeric as match_score
    from public.electricians e
    join public.profiles p on p.id = e.profile_id
    where e.status = 'approved'
      and e.availability_status = 'available'
      and (p_service_area = any(e.service_areas) or p_service_area is null)
  )
  select *
  from ranked
  order by match_score desc, average_rating desc nulls last, completed_jobs desc, distance_km asc
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
  customer_profile uuid;
  assigned_profile uuid;
  job_row public.jobs;
begin
  select * into job_row from public.jobs where id = p_job_id for update;
  if not found then
    raise exception 'Job not found';
  end if;

  if p_manual_electrician_id is not null then
    target_electrician := p_manual_electrician_id;
    candidate_list := array[p_manual_electrician_id];
  else
    select array_agg(electrician_id order by match_score desc)
    into candidate_list
    from public.find_matching_electricians(job_row.service_area, job_row.issue_category, job_row.latitude, job_row.longitude, 10);

    if job_row.assigned_electrician_id is not null then
      candidate_list := array_remove(candidate_list, job_row.assigned_electrician_id);
    end if;

    target_electrician := candidate_list[1];
  end if;

  if target_electrician is null then
    update public.jobs
    set status = 'matching',
        assigned_electrician_id = null,
        candidate_queue = coalesce(candidate_list, '{}'::uuid[]),
        dispatch_attempts = dispatch_attempts + 1,
        last_dispatch_at = now(),
        assignment_expires_at = null
    where id = p_job_id
    returning * into job_row;

    perform public.append_job_timeline(p_job_id, 'matching', 'No approved available VoltFriq matched yet.', auth.uid());
    return job_row;
  end if;

  update public.jobs
  set status = 'assigned',
      assigned_electrician_id = target_electrician,
      candidate_queue = coalesce(candidate_list, '{}'::uuid[]),
      dispatch_attempts = dispatch_attempts + 1,
      last_dispatch_at = now(),
      assignment_expires_at = now() + interval '3 minutes'
  where id = p_job_id
  returning * into job_row;

  select c.profile_id into customer_profile from public.customers c where c.id = job_row.customer_id;
  select e.profile_id into assigned_profile from public.electricians e where e.id = target_electrician;

  perform public.append_job_timeline(p_job_id, 'assigned', 'Nearest available VoltFriq dispatched to the job.', auth.uid());
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


-- >>> 20260429004500_matching_automation.sql
alter table public.jobs
  add column if not exists attempted_electrician_ids uuid[] not null default '{}';

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


-- >>> 20260429011000_trust_growth_phase.sql
do $$
begin
  if not exists (
    select 1
    from pg_enum
    where enumtypid = 'notification_event'::regtype
      and enumlabel = 'payment_pending_verification'
  ) then
    alter type notification_event add value 'payment_pending_verification';
  end if;
  if not exists (
    select 1
    from pg_enum
    where enumtypid = 'notification_event'::regtype
      and enumlabel = 'dispute_raised'
  ) then
    alter type notification_event add value 'dispute_raised';
  end if;
  if not exists (
    select 1
    from pg_enum
    where enumtypid = 'notification_event'::regtype
      and enumlabel = 'payout_ready'
  ) then
    alter type notification_event add value 'payout_ready';
  end if;
  if not exists (
    select 1
    from pg_enum
    where enumtypid = 'notification_event'::regtype
      and enumlabel = 'job_stuck'
  ) then
    alter type notification_event add value 'job_stuck';
  end if;
  if not exists (
    select 1
    from pg_enum
    where enumtypid = 'notification_event'::regtype
      and enumlabel = 'reward_issued'
  ) then
    alter type notification_event add value 'reward_issued';
  end if;
end $$;

alter table public.profiles
  add column if not exists referral_code text;

alter table public.electricians
  add column if not exists response_rate numeric(5,2) not null default 0;

create unique index if not exists profiles_referral_code_key
on public.profiles (referral_code)
where referral_code is not null;

create table if not exists public.wallets (
  id uuid primary key default gen_random_uuid(),
  profile_id uuid not null unique references public.profiles(id) on delete cascade,
  balance numeric(12,2) not null default 0,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.wallet_transactions (
  id uuid primary key default gen_random_uuid(),
  wallet_id uuid not null references public.wallets(id) on delete cascade,
  profile_id uuid not null references public.profiles(id) on delete cascade,
  job_id uuid references public.jobs(id) on delete set null,
  transaction_type text not null,
  amount numeric(12,2) not null,
  note text,
  created_at timestamptz not null default now()
);

create table if not exists public.referrals (
  id uuid primary key default gen_random_uuid(),
  referrer_profile_id uuid not null references public.profiles(id) on delete cascade,
  referred_profile_id uuid not null unique references public.profiles(id) on delete cascade,
  referral_code text not null,
  status text not null default 'pending',
  reward_amount numeric(12,2) not null default 0,
  completed_at timestamptz,
  rewarded_at timestamptz,
  created_at timestamptz not null default now()
);

create table if not exists public.disputes (
  id uuid primary key default gen_random_uuid(),
  job_id uuid not null references public.jobs(id) on delete cascade,
  customer_id uuid not null references public.customers(id) on delete cascade,
  electrician_id uuid references public.electricians(id) on delete set null,
  issue_type text not null,
  details text,
  status text not null default 'open',
  resolution_action text,
  resolution_note text,
  resolved_by uuid references public.profiles(id) on delete set null,
  resolved_at timestamptz,
  created_at timestamptz not null default now()
);

create or replace function public.ensure_wallet_for_profile(p_profile_id uuid)
returns public.wallets
language plpgsql
security definer
set search_path = public
as $$
declare
  wallet_row public.wallets;
begin
  insert into public.wallets (profile_id)
  values (p_profile_id)
  on conflict (profile_id) do nothing;

  select * into wallet_row
  from public.wallets
  where profile_id = p_profile_id;

  return wallet_row;
end;
$$;

create or replace function public.generate_referral_code()
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  next_code text;
begin
  loop
    next_code := 'VFQ' || upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 8));
    exit when not exists (select 1 from public.profiles where referral_code = next_code);
  end loop;
  return next_code;
end;
$$;

create or replace function public.handle_profile_rewards_setup()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.referral_code is null then
    new.referral_code := public.generate_referral_code();
  end if;
  return new;
end;
$$;

drop trigger if exists profiles_rewards_setup on public.profiles;
create trigger profiles_rewards_setup
before insert on public.profiles
for each row execute function public.handle_profile_rewards_setup();

create or replace function public.handle_profile_wallet_setup()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  perform public.ensure_wallet_for_profile(new.id);
  return new;
end;
$$;

drop trigger if exists profiles_wallet_setup on public.profiles;
create trigger profiles_wallet_setup
after insert on public.profiles
for each row execute function public.handle_profile_wallet_setup();

update public.profiles
set referral_code = public.generate_referral_code()
where referral_code is null;

insert into public.wallets (profile_id)
select id
from public.profiles
where not exists (
  select 1 from public.wallets w where w.profile_id = public.profiles.id
);

create or replace function public.refresh_electrician_trust_metrics(p_electrician_id uuid)
returns public.electricians
language plpgsql
security definer
set search_path = public
as $$
declare
  updated_row public.electricians;
begin
  update public.electricians e
  set total_ratings = coalesce(stats.total_ratings, 0),
      average_rating = coalesce(stats.average_rating, 0),
      completed_jobs = coalesce(stats.completed_jobs, 0),
      response_rate = coalesce(stats.response_rate, 0)
  from (
    select
      e2.id as electrician_id,
      (
        select count(*)::integer
        from public.ratings r
        where r.electrician_id = e2.id
      ) as total_ratings,
      (
        select round(avg(r.score)::numeric, 2)
        from public.ratings r
        where r.electrician_id = e2.id
      ) as average_rating,
      (
        select count(*)::integer
        from public.jobs j
        where j.assigned_electrician_id = e2.id
          and j.status in ('customer_confirmed', 'payout_pending', 'payout_complete', 'rated')
      ) as completed_jobs,
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

  return updated_row;
end;
$$;

create or replace function public.link_referral_code(p_referral_code text)
returns public.referrals
language plpgsql
security definer
set search_path = public
as $$
declare
  referrer_row public.profiles;
  referral_row public.referrals;
begin
  if auth.uid() is null then
    raise exception 'Authentication required';
  end if;

  if p_referral_code is null or btrim(p_referral_code) = '' then
    raise exception 'Referral code is required';
  end if;

  select * into referrer_row
  from public.profiles
  where referral_code = upper(btrim(p_referral_code));

  if not found then
    raise exception 'Referral code not found';
  end if;

  if referrer_row.id = auth.uid() then
    raise exception 'You cannot use your own referral code';
  end if;

  insert into public.referrals (referrer_profile_id, referred_profile_id, referral_code)
  values (referrer_row.id, auth.uid(), referrer_row.referral_code)
  on conflict (referred_profile_id) do update
  set referral_code = excluded.referral_code
  returning * into referral_row;

  return referral_row;
end;
$$;

create or replace function public.create_dispute(
  p_job_id uuid,
  p_issue_type text,
  p_details text default null
)
returns public.disputes
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
    and customer_id = customer_row.id;

  if not found then
    raise exception 'Job not found';
  end if;

  insert into public.disputes (job_id, customer_id, electrician_id, issue_type, details)
  values (p_job_id, customer_row.id, job_row.assigned_electrician_id, p_issue_type, p_details)
  returning * into dispute_row;

  perform public.append_job_timeline(p_job_id, job_row.status, 'Customer reported an issue: ' || coalesce(p_issue_type, 'general dispute') || '.', auth.uid());
  select id into admin_profile from public.profiles where role = 'admin' order by created_at asc limit 1;
  if admin_profile is not null then
    perform public.create_notification(admin_profile, p_job_id, 'dispute_raised', 'Dispute raised', 'A customer reported an issue and admin review is needed.', jsonb_build_object('dispute_id', dispute_row.id, 'issue_type', p_issue_type));
  end if;

  return dispute_row;
end;
$$;

create or replace function public.resolve_dispute(
  p_dispute_id uuid,
  p_status text,
  p_resolution_action text default null,
  p_resolution_note text default null
)
returns public.disputes
language plpgsql
security definer
set search_path = public
as $$
declare
  dispute_row public.disputes;
begin
  if not public.is_admin() then
    raise exception 'Admin access required';
  end if;

  update public.disputes
  set status = coalesce(nullif(p_status, ''), status),
      resolution_action = p_resolution_action,
      resolution_note = p_resolution_note,
      resolved_by = auth.uid(),
      resolved_at = now()
  where id = p_dispute_id
  returning * into dispute_row;

  if not found then
    raise exception 'Dispute not found';
  end if;

  perform public.append_job_timeline(dispute_row.job_id, (select status from public.jobs where id = dispute_row.job_id), 'Admin resolved dispute: ' || coalesce(p_resolution_action, dispute_row.status) || '.', auth.uid());
  return dispute_row;
end;
$$;

create or replace function public.reward_completed_referral(p_referred_profile_id uuid, p_job_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  referral_row public.referrals;
  reward_value numeric := 2500;
  wallet_row public.wallets;
begin
  select * into referral_row
  from public.referrals
  where referred_profile_id = p_referred_profile_id
    and status <> 'rewarded'
  order by created_at asc
  limit 1
  for update;

  if not found then
    return;
  end if;

  select * into wallet_row
  from public.ensure_wallet_for_profile(referral_row.referrer_profile_id);

  update public.wallets
  set balance = balance + reward_value
  where id = wallet_row.id
  returning * into wallet_row;

  insert into public.wallet_transactions (wallet_id, profile_id, job_id, transaction_type, amount, note)
  values (wallet_row.id, referral_row.referrer_profile_id, p_job_id, 'referral_reward', reward_value, 'Referral reward for first completed job.');

  update public.referrals
  set status = 'rewarded',
      reward_amount = reward_value,
      completed_at = coalesce(completed_at, now()),
      rewarded_at = now()
  where id = referral_row.id;

  perform public.create_notification(referral_row.referrer_profile_id, p_job_id, 'reward_issued', 'Referral reward added', 'A wallet reward has been added to your VoltFriq wallet.', jsonb_build_object('amount', reward_value));
end;
$$;

create or replace function public.handle_wallets_touch_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

drop trigger if exists wallets_touch_updated_at on public.wallets;
create trigger wallets_touch_updated_at
before update on public.wallets
for each row execute function public.handle_wallets_touch_updated_at();

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

  if exists (
    select 1
    from public.jobs j
    where j.customer_id = customer_row.id
      and j.issue_category = p_issue_category
      and j.service_area = p_service_area
      and j.status not in ('rated', 'cancelled')
      and j.created_at >= now() - interval '15 minutes'
  ) then
    raise exception 'A similar booking is already active. Track the existing job instead of creating a duplicate.';
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
  customer_profile uuid;
begin
  if exists (
    select 1
    from public.job_payments
    where job_id = p_job_id
      and payment_type = p_payment_type
      and status = 'submitted'
  ) then
    raise exception 'A payment proof is already waiting for manual verification for this step.';
  end if;

  insert into public.job_payments (job_id, submitted_by, payment_type, amount, proof_path, reference)
  values (p_job_id, auth.uid(), p_payment_type, coalesce(p_amount, 0), p_proof_path, p_reference)
  returning * into payment_row;

  update public.jobs
  set status = case
    when p_payment_type = 'assessment_fee' then 'assessment_payment_pending_verification'
    else 'work_payment_pending_verification'
  end
  where id = p_job_id;

  select c.profile_id into customer_profile
  from public.jobs j
  join public.customers c on c.id = j.customer_id
  where j.id = p_job_id;

  perform public.append_job_timeline(p_job_id, (select status from public.jobs where id = p_job_id), 'Payment proof submitted for manual verification.', auth.uid());
  perform public.create_notification(
    (select id from public.profiles where role = 'admin' order by created_at asc limit 1),
    p_job_id,
    'payment_proof_submitted',
    'Payment verification needed',
    'A customer submitted payment proof that needs review.',
    jsonb_build_object('payment_id', payment_row.id, 'payment_type', p_payment_type)
  );
  if customer_profile is not null then
    perform public.create_notification(customer_profile, p_job_id, 'payment_pending_verification', 'Payment received', 'Your payment proof was received and is pending manual verification.', jsonb_build_object('payment_id', payment_row.id));
  end if;
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
  electrician_profile uuid;
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

  select p.id into electrician_profile
  from public.jobs j
  join public.electricians e on e.id = j.assigned_electrician_id
  join public.profiles p on p.id = e.profile_id
  where j.id = payment_row.job_id;

  perform public.append_job_timeline(payment_row.job_id, next_status, case when p_approved then 'Payment verified by admin.' else 'Payment rejected by admin.' end, auth.uid());
  if p_approved then
    if customer_profile is not null then
      perform public.create_notification(customer_profile, payment_row.job_id, 'payment_verified', 'Payment verified', 'Your payment was verified and the job can move forward.', jsonb_build_object('payment_id', payment_row.id));
    end if;
    if electrician_profile is not null then
      perform public.create_notification(electrician_profile, payment_row.job_id, 'payment_verified', 'Payment confirmed', 'Admin verified customer payment for this job.', jsonb_build_object('payment_id', payment_row.id));
    end if;
  end if;
  return payment_row;
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

  perform public.refresh_electrician_trust_metrics(electrician_row.id);

  select c.profile_id into customer_profile from public.customers c where c.id = job_row.customer_id;
  perform public.append_job_timeline(p_job_id, job_row.status, 'VoltFriq accepted the booking.', auth.uid());
  perform public.create_notification(customer_profile, p_job_id, 'electrician_accepted', 'VoltFriq accepted', 'Your assigned VoltFriq accepted the booking.', '{}'::jsonb);
  return job_row;
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
  perform public.refresh_electrician_trust_metrics(job_row.assigned_electrician_id);
  perform public.reward_completed_referral(auth.uid(), p_job_id);
  perform public.append_job_timeline(p_job_id, 'rated', 'Customer submitted a rating.', auth.uid());
  return rating_row;
end;
$$;

create or replace function public.handle_job_status_notifications()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  customer_profile uuid;
  electrician_profile uuid;
  admin_profile uuid;
begin
  if tg_op <> 'UPDATE' or new.status = old.status then
    return new;
  end if;

  select c.profile_id into customer_profile from public.customers c where c.id = new.customer_id;
  select e.profile_id into electrician_profile from public.electricians e where e.id = new.assigned_electrician_id;
  select id into admin_profile from public.profiles where role = 'admin' order by created_at asc limit 1;

  if new.status = 'electrician_completed' and customer_profile is not null then
    perform public.create_notification(customer_profile, new.id, 'work_completed', 'Work marked complete', 'Your VoltFriq marked the job complete and is waiting for your confirmation.', '{}'::jsonb);
  end if;

  if new.status = 'payout_pending' and electrician_profile is not null then
    perform public.create_notification(electrician_profile, new.id, 'payout_ready', 'Payout ready', 'Customer confirmed the job. Admin will release payout next.', '{}'::jsonb);
  end if;

  if new.status = 'matching' and new.assigned_electrician_id is null and admin_profile is not null and coalesce(array_length(new.candidate_queue, 1), 0) = 0 then
    perform public.create_notification(admin_profile, new.id, 'job_stuck', 'Job stuck in matching', 'This job needs manual dispatch follow-up.', '{}'::jsonb);
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

alter table public.wallets enable row level security;
alter table public.wallet_transactions enable row level security;
alter table public.referrals enable row level security;
alter table public.disputes enable row level security;

create policy "wallets self or admin" on public.wallets
for select using (profile_id = auth.uid() or public.is_admin());

create policy "wallets admin write" on public.wallets
for all using (public.is_admin()) with check (public.is_admin());

create policy "wallet transactions self or admin" on public.wallet_transactions
for select using (profile_id = auth.uid() or public.is_admin());

create policy "wallet transactions admin write" on public.wallet_transactions
for all using (public.is_admin()) with check (public.is_admin());

create policy "referrals self or admin read" on public.referrals
for select using (referrer_profile_id = auth.uid() or referred_profile_id = auth.uid() or public.is_admin());

create policy "referrals self insert" on public.referrals
for insert with check (referred_profile_id = auth.uid() or public.is_admin());

create policy "referrals admin update" on public.referrals
for update using (public.is_admin()) with check (public.is_admin());

create policy "disputes customer electrician or admin read" on public.disputes
for select using (
  public.is_admin()
  or customer_id = public.current_customer_id()
  or electrician_id = public.current_electrician_id()
);

create policy "disputes customer insert" on public.disputes
for insert with check (customer_id = public.current_customer_id() or public.is_admin());

create policy "disputes admin update" on public.disputes
for update using (public.is_admin()) with check (public.is_admin());


-- >>> 20260429012500_two_sided_trust_levels.sql
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


-- >>> 20260429014000_guest_booking_gps.sql
create table if not exists public.guest_customers (
  id uuid primary key default gen_random_uuid(),
  phone text not null unique,
  location_label text,
  latitude double precision,
  longitude double precision,
  created_at timestamptz not null default now(),
  last_seen_at timestamptz not null default now()
);

alter table public.jobs
  add column if not exists guest_customer_id uuid references public.guest_customers(id) on delete set null,
  add column if not exists customer_access_token text;

alter table public.jobs
  alter column customer_id drop not null;

create unique index if not exists jobs_customer_access_token_key
on public.jobs (customer_access_token)
where customer_access_token is not null;

do $$
begin
  if not exists (
    select 1 from pg_constraint where conname = 'jobs_customer_or_guest_check'
  ) then
    alter table public.jobs
      add constraint jobs_customer_or_guest_check
      check (customer_id is not null or guest_customer_id is not null) not valid;
  end if;
end $$;

alter table public.job_payments
  add column if not exists guest_customer_id uuid references public.guest_customers(id) on delete set null;

alter table public.job_payments
  alter column submitted_by drop not null;

do $$
begin
  if not exists (
    select 1 from pg_constraint where conname = 'job_payments_submitter_check'
  ) then
    alter table public.job_payments
      add constraint job_payments_submitter_check
      check (submitted_by is not null or guest_customer_id is not null) not valid;
  end if;
end $$;

alter table public.job_timeline
  add column if not exists metadata jsonb not null default '{}'::jsonb;

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
  if p_profile_id is null then
    return;
  end if;

  insert into public.notifications (profile_id, job_id, event, title, body, metadata)
  values (p_profile_id, p_job_id, p_event, p_title, p_body, coalesce(p_metadata, '{}'::jsonb));
end;
$$;

create or replace function public.ensure_profile_for_current_user()
returns public.profiles
language plpgsql
security definer
set search_path = public
as $$
declare
  user_row auth.users;
  requested_role user_role;
  profile_row public.profiles;
begin
  select * into user_row from auth.users where id = auth.uid();
  if not found then
    raise exception 'No authenticated user';
  end if;

  requested_role := coalesce((user_row.raw_user_meta_data ->> 'requested_role')::user_role, 'customer');

  insert into public.profiles (id, role, full_name, phone)
  values (
    user_row.id,
    case when requested_role = 'admin' then 'customer' else requested_role end,
    coalesce(user_row.raw_user_meta_data ->> 'full_name', user_row.email, ''),
    user_row.raw_user_meta_data ->> 'phone'
  )
  on conflict (id) do update
    set full_name = coalesce(nullif(public.profiles.full_name, ''), excluded.full_name),
        phone = coalesce(public.profiles.phone, excluded.phone)
  returning * into profile_row;

  return profile_row;
end;
$$;

create or replace function public.guest_job_payload(
  p_job_id uuid,
  p_access_token text
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  payload jsonb;
begin
  select jsonb_build_object(
    'id', j.id,
    'ticket', j.ticket,
    'customer_id', j.customer_id,
    'guest_customer_id', j.guest_customer_id,
    'assigned_electrician_id', j.assigned_electrician_id,
    'service_area', j.service_area,
    'location_label', j.location_label,
    'latitude', j.latitude,
    'longitude', j.longitude,
    'issue_category', j.issue_category,
    'urgency', j.urgency,
    'customer_note', j.customer_note,
    'requires_assessment', j.requires_assessment,
    'material_handling', j.material_handling,
    'status', j.status,
    'current_quote_id', j.current_quote_id,
    'candidate_queue', j.candidate_queue,
    'attempted_electrician_ids', j.attempted_electrician_ids,
    'dispatch_attempts', j.dispatch_attempts,
    'last_dispatch_at', j.last_dispatch_at,
    'assignment_expires_at', j.assignment_expires_at,
    'accepted_at', j.accepted_at,
    'customer_confirmed_at', j.customer_confirmed_at,
    'electrician_completed_at', j.electrician_completed_at,
    'payout_released_at', j.payout_released_at,
    'created_at', j.created_at,
    'updated_at', j.updated_at,
    'customer', null,
    'guest_customer', to_jsonb(g),
    'assigned_electrician', case when e.id is null then null else (
      to_jsonb(e) ||
      jsonb_build_object(
        'profile', to_jsonb(p),
        'electrician_skills', coalesce((
          select jsonb_agg(to_jsonb(s))
          from public.electrician_skills s
          where s.electrician_id = e.id
        ), '[]'::jsonb),
        'electrician_documents', coalesce((
          select jsonb_agg(to_jsonb(d))
          from public.electrician_documents d
          where d.electrician_id = e.id
        ), '[]'::jsonb)
      )
    ) end,
    'job_photos', coalesce((
      select jsonb_agg(to_jsonb(photo) order by photo.created_at)
      from public.job_photos photo
      where photo.job_id = j.id
    ), '[]'::jsonb),
    'job_quotes', coalesce((
      select jsonb_agg(
        to_jsonb(q) ||
        jsonb_build_object(
          'quote_items', coalesce((
            select jsonb_agg(to_jsonb(item) order by item.created_at)
            from public.quote_items item
            where item.quote_id = q.id
          ), '[]'::jsonb)
        )
        order by q.created_at
      )
      from public.job_quotes q
      where q.job_id = j.id
    ), '[]'::jsonb),
    'job_payments', coalesce((
      select jsonb_agg(to_jsonb(payment) order by payment.created_at)
      from public.job_payments payment
      where payment.job_id = j.id
    ), '[]'::jsonb),
    'job_timeline', coalesce((
      select jsonb_agg(to_jsonb(timeline) order by timeline.created_at)
      from public.job_timeline timeline
      where timeline.job_id = j.id
    ), '[]'::jsonb),
    'ratings', '[]'::jsonb
  )
  into payload
  from public.jobs j
  join public.guest_customers g on g.id = j.guest_customer_id
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

create or replace function public.get_guest_job(
  p_job_id uuid,
  p_access_token text
)
returns jsonb
language sql
security definer
set search_path = public
as $$
  select public.guest_job_payload(p_job_id, p_access_token);
$$;

create or replace function public.create_guest_customer_job(
  p_phone text,
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
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  guest_row public.guest_customers;
  created_job public.jobs;
  access_token text;
begin
  if nullif(trim(p_phone), '') is null then
    raise exception 'Phone number is required';
  end if;

  insert into public.guest_customers (phone, location_label, latitude, longitude)
  values (trim(p_phone), p_location_label, p_latitude, p_longitude)
  on conflict (phone) do update
    set location_label = excluded.location_label,
        latitude = excluded.latitude,
        longitude = excluded.longitude,
        last_seen_at = now()
  returning * into guest_row;

  access_token := replace(gen_random_uuid()::text, '-', '') || replace(gen_random_uuid()::text, '-', '');

  insert into public.jobs (
    customer_id,
    guest_customer_id,
    customer_access_token,
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
    null,
    guest_row.id,
    access_token,
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

  insert into public.job_timeline (job_id, status, note, actor_profile_id, metadata)
  values
    (created_job.id, 'requested', 'Guest customer created a new booking request.', null, jsonb_build_object('guest_customer_id', guest_row.id)),
    (created_job.id, 'matching', 'Automatic dispatch started.', null, '{}'::jsonb);

  select * into created_job from public.dispatch_job(created_job.id, null);

  return jsonb_build_object(
    'access_token', access_token,
    'job', public.guest_job_payload(created_job.id, access_token)
  );
end;
$$;

create or replace function public.set_job_status(
  p_job_id uuid,
  p_next_status job_status,
  p_note text default null,
  p_metadata jsonb default '{}'::jsonb
)
returns public.jobs
language plpgsql
security definer
set search_path = public
as $$
declare
  job_row public.jobs;
begin
  select * into job_row from public.jobs where id = p_job_id for update;
  if not found then
    raise exception 'Job not found';
  end if;

  if not (
    public.is_admin()
    or job_row.customer_id = public.current_customer_id()
    or job_row.assigned_electrician_id = public.current_electrician_id()
  ) then
    raise exception 'You do not have permission to update this job';
  end if;

  update public.jobs
  set status = p_next_status,
      customer_confirmed_at = case when p_next_status = 'customer_confirmed' then now() else customer_confirmed_at end,
      electrician_completed_at = case when p_next_status = 'electrician_completed' then now() else electrician_completed_at end,
      payout_released_at = case when p_next_status = 'payout_complete' then now() else payout_released_at end
  where id = p_job_id
  returning * into job_row;

  insert into public.job_timeline (job_id, status, note, actor_profile_id, metadata)
  values (p_job_id, p_next_status, p_note, auth.uid(), coalesce(p_metadata, '{}'::jsonb));

  return job_row;
end;
$$;

create or replace function public.update_guest_job_status(
  p_job_id uuid,
  p_access_token text,
  p_next_status job_status,
  p_note text default null,
  p_metadata jsonb default '{}'::jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  job_row public.jobs;
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

  if p_next_status not in ('quote_accepted', 'customer_confirmed', 'cancelled') then
    raise exception 'Guest customers cannot set this job status';
  end if;

  update public.jobs
  set status = p_next_status,
      customer_confirmed_at = case when p_next_status = 'customer_confirmed' then now() else customer_confirmed_at end
  where id = p_job_id
  returning * into job_row;

  insert into public.job_timeline (job_id, status, note, actor_profile_id, metadata)
  values (p_job_id, p_next_status, p_note, null, coalesce(p_metadata, '{}'::jsonb));

  return public.guest_job_payload(p_job_id, p_access_token);
end;
$$;

create or replace function public.submit_guest_payment_proof(
  p_job_id uuid,
  p_access_token text,
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
  job_row public.jobs;
  payment_row public.job_payments;
  next_status job_status;
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

  if exists (
    select 1
    from public.job_payments
    where job_id = p_job_id
      and payment_type = p_payment_type
      and status in ('submitted', 'verified')
  ) then
    raise exception 'Payment proof for this step has already been submitted';
  end if;

  insert into public.job_payments (job_id, guest_customer_id, submitted_by, payment_type, amount, proof_path, reference)
  values (p_job_id, job_row.guest_customer_id, null, p_payment_type, coalesce(p_amount, 0), p_proof_path, p_reference)
  returning * into payment_row;

  next_status := case
    when p_payment_type = 'assessment_fee' then 'assessment_payment_pending_verification'
    when p_payment_type in ('quote_payment', 'material_payment') then 'work_payment_pending_verification'
    else job_row.status
  end;

  update public.jobs
  set status = next_status
  where id = p_job_id;

  insert into public.job_timeline (job_id, status, note, actor_profile_id, metadata)
  values (
    p_job_id,
    next_status,
    'Guest payment proof submitted for manual verification.',
    null,
    jsonb_build_object('payment_id', payment_row.id, 'payment_type', p_payment_type)
  );

  perform public.create_notification(
    (select id from public.profiles where role = 'admin' order by created_at asc limit 1),
    p_job_id,
    'payment_proof_submitted',
    'Payment proof submitted',
    'A guest customer submitted payment proof for manual verification.',
    jsonb_build_object('payment_id', payment_row.id, 'payment_type', p_payment_type)
  );

  return payment_row;
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

  update public.customers
  set primary_service_area = coalesce(p_location_label, p_service_area, primary_service_area),
      latitude = coalesce(p_latitude, latitude),
      longitude = coalesce(p_longitude, longitude)
  where id = customer_row.id
  returning * into customer_row;

  insert into public.jobs (
    customer_id,
    guest_customer_id,
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
    null,
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

alter table public.guest_customers enable row level security;

do $$
begin
  if not exists (
    select 1 from pg_policies where schemaname = 'public' and tablename = 'guest_customers' and policyname = 'guest customers admin or assigned electrician read'
  ) then
    execute $policy$
      create policy "guest customers admin or assigned electrician read" on public.guest_customers
      for select using (
        public.is_admin()
        or exists (
          select 1 from public.jobs j
          where j.guest_customer_id = guest_customers.id
            and j.assigned_electrician_id = public.current_electrician_id()
        )
      )
    $policy$;
  end if;
end $$;

do $$
begin
  if not exists (
    select 1 from pg_policies where schemaname = 'storage' and tablename = 'objects' and policyname = 'voltfriq authenticated uploads'
  ) then
    execute $policy$
      create policy "voltfriq authenticated uploads" on storage.objects
      for insert to authenticated
      with check (bucket_id in ('avatars', 'electrician-documents', 'job-photos', 'payment-proofs'))
    $policy$;
  end if;

  if not exists (
    select 1 from pg_policies where schemaname = 'storage' and tablename = 'objects' and policyname = 'voltfriq guest uploads'
  ) then
    execute $policy$
      create policy "voltfriq guest uploads" on storage.objects
      for insert to anon
      with check (
        bucket_id in ('job-photos', 'payment-proofs')
        and name like 'guest/%'
      )
    $policy$;
  end if;
end $$;


-- >>> 20260429014500_guest_payout_pending.sql
create or replace function public.update_guest_job_status(
  p_job_id uuid,
  p_access_token text,
  p_next_status job_status,
  p_note text default null,
  p_metadata jsonb default '{}'::jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  job_row public.jobs;
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

  if p_next_status not in ('quote_accepted', 'customer_confirmed', 'payout_pending', 'cancelled') then
    raise exception 'Guest customers cannot set this job status';
  end if;

  update public.jobs
  set status = p_next_status,
      customer_confirmed_at = case when p_next_status in ('customer_confirmed', 'payout_pending') then coalesce(customer_confirmed_at, now()) else customer_confirmed_at end
  where id = p_job_id
  returning * into job_row;

  insert into public.job_timeline (job_id, status, note, actor_profile_id, metadata)
  values (p_job_id, p_next_status, p_note, null, coalesce(p_metadata, '{}'::jsonb));

  return public.guest_job_payload(p_job_id, p_access_token);
end;
$$;


-- >>> 20260429015000_guest_token_generation_fix.sql
create or replace function public.create_guest_customer_job(
  p_phone text,
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
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  guest_row public.guest_customers;
  created_job public.jobs;
  access_token text;
begin
  if nullif(trim(p_phone), '') is null then
    raise exception 'Phone number is required';
  end if;

  insert into public.guest_customers (phone, location_label, latitude, longitude)
  values (trim(p_phone), p_location_label, p_latitude, p_longitude)
  on conflict (phone) do update
    set location_label = excluded.location_label,
        latitude = excluded.latitude,
        longitude = excluded.longitude,
        last_seen_at = now()
  returning * into guest_row;

  access_token := replace(gen_random_uuid()::text, '-', '') || replace(gen_random_uuid()::text, '-', '');

  insert into public.jobs (
    customer_id,
    guest_customer_id,
    customer_access_token,
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
    null,
    guest_row.id,
    access_token,
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

  insert into public.job_timeline (job_id, status, note, actor_profile_id, metadata)
  values
    (created_job.id, 'requested', 'Guest customer created a new booking request.', null, jsonb_build_object('guest_customer_id', guest_row.id)),
    (created_job.id, 'matching', 'Automatic dispatch started.', null, '{}'::jsonb);

  select * into created_job from public.dispatch_job(created_job.id, null);

  return jsonb_build_object(
    'access_token', access_token,
    'job', public.guest_job_payload(created_job.id, access_token)
  );
end;
$$;


-- >>> 20260429015500_status_casts_and_rating_constraint.sql
alter table public.ratings
  drop constraint if exists ratings_job_id_key;

do $$
begin
  if not exists (
    select 1
    from pg_constraint
    where conname = 'ratings_job_direction_key'
      and conrelid = 'public.ratings'::regclass
  ) then
    alter table public.ratings
      add constraint ratings_job_direction_key unique (job_id, review_direction);
  end if;
end $$;

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
  set status = case
        when job_row.requires_assessment then 'assessment_fee_pending'::job_status
        else 'accepted'::job_status
      end,
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
    when p_payment_type = 'assessment_fee' then 'assessment_payment_pending_verification'::job_status
    else 'work_payment_pending_verification'::job_status
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
  electrician_profile uuid;
begin
  if not public.is_admin() then
    raise exception 'Admin access required';
  end if;

  select * into payment_row from public.job_payments where id = p_payment_id for update;
  if not found then
    raise exception 'Payment not found';
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

  update public.jobs set status = next_status where id = payment_row.job_id;

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


-- >>> 20260429016000_submit_rating_without_conflict.sql
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

  select * into rating_row
  from public.ratings
  where job_id = p_job_id
    and review_direction = 'customer_to_electrician'
  limit 1;

  if found then
    update public.ratings
    set score = p_score,
        comment = p_comment,
        reviewer_profile_id = auth.uid(),
        reviewee_profile_id = electrician_profile,
        reviewee_role = 'electrician',
        behavior_tags = coalesce(p_behavior_tags, '{}'::text[])
    where id = rating_row.id
    returning * into rating_row;
  else
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
    returning * into rating_row;
  end if;

  update public.jobs set status = 'rated' where id = p_job_id;
  perform public.refresh_electrician_trust_metrics(job_row.assigned_electrician_id);
  perform public.reward_completed_referral(auth.uid(), p_job_id);
  perform public.append_job_timeline(p_job_id, 'rated', 'Customer submitted a VoltFriq rating.', auth.uid());
  perform public.create_notification(electrician_profile, p_job_id, 'review_submitted', 'Customer review received', 'A customer submitted feedback for your completed job.', jsonb_build_object('score', p_score));
  return rating_row;
end;
$$;


-- >>> 20260429016500_drop_old_rating_overload.sql
drop function if exists public.submit_rating(uuid, integer, text);

create or replace function public.update_guest_job_status(
  p_job_id uuid,
  p_access_token text,
  p_next_status job_status,
  p_note text default null,
  p_metadata jsonb default '{}'::jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
begin
  perform 1
  from public.jobs
  where id = p_job_id
    and customer_access_token = p_access_token
    and guest_customer_id is not null
  for update;

  if not found then
    raise exception 'Guest job not found';
  end if;

  if p_next_status not in ('quote_accepted', 'customer_confirmed', 'payout_pending', 'cancelled') then
    raise exception 'Guest customers cannot set this job status';
  end if;

  update public.jobs
  set status = p_next_status,
      customer_confirmed_at = case when p_next_status in ('customer_confirmed', 'payout_pending') then coalesce(customer_confirmed_at, now()) else customer_confirmed_at end
  where id = p_job_id;

  insert into public.job_timeline (job_id, status, note, actor_profile_id, metadata)
  values (p_job_id, p_next_status, p_note, null, coalesce(p_metadata, '{}'::jsonb));

  return public.guest_job_payload(p_job_id, p_access_token);
end;
$$;


-- >>> 20260429017000_customer_saved_addresses.sql
-- Add saved addresses for authenticated customers.
-- Guest saved addresses remain device-local in the browser.

create table if not exists public.customer_addresses (
  id uuid primary key default gen_random_uuid(),
  profile_id uuid not null references public.profiles(id) on delete cascade,
  label text not null default 'Saved address',
  address_text text not null,
  location_label text,
  latitude double precision,
  longitude double precision,
  last_used_at timestamptz not null default now(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists customer_addresses_profile_idx
on public.customer_addresses(profile_id, last_used_at desc);

create index if not exists customer_addresses_profile_address_idx
on public.customer_addresses(profile_id, lower(address_text));

drop trigger if exists customer_addresses_touch_updated_at on public.customer_addresses;
create trigger customer_addresses_touch_updated_at
before update on public.customer_addresses
for each row execute function public.touch_updated_at();

alter table public.customer_addresses enable row level security;

do $$
begin
  if not exists (
    select 1
    from pg_policies
    where schemaname = 'public'
      and tablename = 'customer_addresses'
      and policyname = 'customer addresses owner or admin'
  ) then
    create policy "customer addresses owner or admin" on public.customer_addresses
    for all
    using (profile_id = auth.uid() or public.is_admin())
    with check (profile_id = auth.uid() or public.is_admin());
  end if;
end $$;


-- >>> 20260429105000_integration_stability.sql
-- Integration stability guardrails.
-- This migration is additive/idempotent: it does not recreate existing data.

create table if not exists public.wallets (
  id uuid primary key default gen_random_uuid(),
  profile_id uuid not null unique references public.profiles(id) on delete cascade,
  balance numeric(12,2) not null default 0,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.wallet_transactions (
  id uuid primary key default gen_random_uuid(),
  wallet_id uuid not null references public.wallets(id) on delete cascade,
  profile_id uuid not null references public.profiles(id) on delete cascade,
  job_id uuid references public.jobs(id) on delete set null,
  transaction_type text not null,
  amount numeric(12,2) not null,
  note text,
  created_at timestamptz not null default now()
);

create table if not exists public.referrals (
  id uuid primary key default gen_random_uuid(),
  referrer_profile_id uuid not null references public.profiles(id) on delete cascade,
  referred_profile_id uuid not null unique references public.profiles(id) on delete cascade,
  referral_code text not null,
  status text not null default 'pending',
  reward_amount numeric(12,2) not null default 0,
  completed_at timestamptz,
  rewarded_at timestamptz,
  created_at timestamptz not null default now()
);

create table if not exists public.disputes (
  id uuid primary key default gen_random_uuid(),
  job_id uuid not null references public.jobs(id) on delete cascade,
  customer_id uuid not null references public.customers(id) on delete cascade,
  electrician_id uuid references public.electricians(id) on delete set null,
  issue_type text not null,
  details text,
  status text not null default 'open',
  resolution_action text,
  resolution_note text,
  resolved_by uuid references public.profiles(id) on delete set null,
  resolved_at timestamptz,
  created_at timestamptz not null default now()
);

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
  updated_at timestamptz not null default now()
);

create table if not exists public.customer_addresses (
  id uuid primary key default gen_random_uuid(),
  profile_id uuid not null references public.profiles(id) on delete cascade,
  label text not null default 'Saved address',
  address_text text not null,
  location_label text,
  latitude double precision,
  longitude double precision,
  last_used_at timestamptz not null default now(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

alter table public.wallets enable row level security;
alter table public.wallet_transactions enable row level security;
alter table public.referrals enable row level security;
alter table public.disputes enable row level security;
alter table public.electrician_appeals enable row level security;
alter table public.customer_addresses enable row level security;

insert into storage.buckets (id, name, public)
values
  ('avatars', 'avatars', true),
  ('electrician-documents', 'electrician-documents', false),
  ('job-photos', 'job-photos', true),
  ('payment-proofs', 'payment-proofs', false)
on conflict (id) do update
set public = excluded.public;

do $$
begin
  if not exists (
    select 1 from pg_policies
    where schemaname = 'storage' and tablename = 'objects' and policyname = 'voltfriq storage public reads'
  ) then
    create policy "voltfriq storage public reads" on storage.objects
    for select to anon, authenticated
    using (bucket_id in ('avatars', 'job-photos'));
  end if;

  if not exists (
    select 1 from pg_policies
    where schemaname = 'storage' and tablename = 'objects' and policyname = 'voltfriq storage authenticated reads'
  ) then
    create policy "voltfriq storage authenticated reads" on storage.objects
    for select to authenticated
    using (
      bucket_id in ('avatars', 'job-photos')
      or owner = auth.uid()
      or public.is_admin()
    );
  end if;

  if not exists (
    select 1 from pg_policies
    where schemaname = 'storage' and tablename = 'objects' and policyname = 'voltfriq storage authenticated writes'
  ) then
    create policy "voltfriq storage authenticated writes" on storage.objects
    for insert to authenticated
    with check (bucket_id in ('avatars', 'electrician-documents', 'job-photos', 'payment-proofs'));
  end if;

  if not exists (
    select 1 from pg_policies
    where schemaname = 'storage' and tablename = 'objects' and policyname = 'voltfriq storage authenticated updates'
  ) then
    create policy "voltfriq storage authenticated updates" on storage.objects
    for update to authenticated
    using (owner = auth.uid() or public.is_admin())
    with check (bucket_id in ('avatars', 'electrician-documents', 'job-photos', 'payment-proofs'));
  end if;

  if not exists (
    select 1 from pg_policies
    where schemaname = 'storage' and tablename = 'objects' and policyname = 'voltfriq storage guest writes'
  ) then
    create policy "voltfriq storage guest writes" on storage.objects
    for insert to anon
    with check (
      bucket_id in ('job-photos', 'payment-proofs')
      and name like 'guest/%'
    );
  end if;
end $$;


-- >>> 20260429120000_onboarding_expertise_upgrade.sql
create table if not exists public.expertise_categories (
  id uuid primary key default gen_random_uuid(),
  label text not null unique,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.electrician_certifications (
  id uuid primary key default gen_random_uuid(),
  electrician_id uuid not null references public.electricians(id) on delete cascade,
  title text not null,
  license_number text,
  issuer text,
  created_at timestamptz not null default now()
);

alter table public.electricians
  add column if not exists onboarding_score numeric(5,2) not null default 0,
  add column if not exists onboarding_review_status text not null default 'pending',
  add column if not exists onboarding_feedback text,
  add column if not exists onboarding_answers jsonb not null default '[]'::jsonb;

alter table public.expertise_categories enable row level security;
alter table public.electrician_certifications enable row level security;

do $$
begin
  if not exists (
    select 1 from pg_policies
    where schemaname = 'public' and tablename = 'expertise_categories' and policyname = 'expertise categories readable by all'
  ) then
    create policy "expertise categories readable by all" on public.expertise_categories
    for select to anon, authenticated
    using (true);
  end if;

  if not exists (
    select 1 from pg_policies
    where schemaname = 'public' and tablename = 'expertise_categories' and policyname = 'expertise categories admin write'
  ) then
    create policy "expertise categories admin write" on public.expertise_categories
    for all to authenticated
    using (public.is_admin())
    with check (public.is_admin());
  end if;

  if not exists (
    select 1 from pg_policies
    where schemaname = 'public' and tablename = 'electrician_certifications' and policyname = 'electrician certifications own or admin read'
  ) then
    create policy "electrician certifications own or admin read" on public.electrician_certifications
    for select to authenticated
    using (
      public.is_admin()
      or exists (
        select 1
        from public.electricians e
        where e.id = electrician_certifications.electrician_id
          and e.profile_id = auth.uid()
      )
    );
  end if;

  if not exists (
    select 1 from pg_policies
    where schemaname = 'public' and tablename = 'electrician_certifications' and policyname = 'electrician certifications own insert'
  ) then
    create policy "electrician certifications own insert" on public.electrician_certifications
    for insert to authenticated
    with check (
      public.is_admin()
      or exists (
        select 1
        from public.electricians e
        where e.id = electrician_certifications.electrician_id
          and e.profile_id = auth.uid()
      )
    );
  end if;
end $$;

insert into public.expertise_categories (label)
select category
from (
  values
    ('Light fitting'),
    ('Socket repair'),
    ('Wiring issue'),
    ('Inverter'),
    ('Generator'),
    ('Tripped breaker'),
    ('General Installation'),
    ('Inspection'),
    ('Solar'),
    ('Other')
) as defaults(category)
on conflict (label) do nothing;


-- >>> 20260504083000_storage_policy_hardening.sql
-- Tighten storage access around VoltFriq uploads while keeping live customer flows working.

insert into storage.buckets (id, name, public)
values
  ('avatars', 'avatars', true),
  ('electrician-documents', 'electrician-documents', false),
  ('job-photos', 'job-photos', true),
  ('payment-proofs', 'payment-proofs', false)
on conflict (id) do update
set public = excluded.public;

drop policy if exists "voltfriq storage public reads" on storage.objects;
drop policy if exists "voltfriq storage authenticated reads" on storage.objects;
drop policy if exists "voltfriq storage authenticated writes" on storage.objects;
drop policy if exists "voltfriq storage authenticated updates" on storage.objects;
drop policy if exists "voltfriq storage guest writes" on storage.objects;
drop policy if exists "voltfriq authenticated uploads" on storage.objects;
drop policy if exists "voltfriq guest uploads" on storage.objects;

create policy "voltfriq avatar public read" on storage.objects
for select to anon, authenticated
using (bucket_id = 'avatars');

create policy "voltfriq job photos public read" on storage.objects
for select to anon, authenticated
using (bucket_id = 'job-photos');

create policy "voltfriq electrician docs read" on storage.objects
for select to authenticated
using (
  bucket_id = 'electrician-documents'
  and (
    public.is_admin()
    or exists (
      select 1
      from public.electrician_documents d
      join public.electricians e on e.id = d.electrician_id
      where d.file_path = storage.objects.name
        and e.profile_id = auth.uid()
    )
    or exists (
      select 1
      from public.electrician_appeals a
      join public.electricians e on e.id = a.electrician_id
      where a.supporting_file_path = storage.objects.name
        and e.profile_id = auth.uid()
    )
  )
);

create policy "voltfriq payment proof read" on storage.objects
for select to authenticated
using (
  bucket_id = 'payment-proofs'
  and (
    public.is_admin()
    or exists (
      select 1
      from public.job_payments jp
      join public.jobs j on j.id = jp.job_id
      left join public.customers c on c.id = j.customer_id
      left join public.electricians e on e.id = j.assigned_electrician_id
      where jp.proof_path = storage.objects.name
        and (
          jp.submitted_by = auth.uid()
          or c.profile_id = auth.uid()
          or e.profile_id = auth.uid()
        )
    )
  )
);

create policy "voltfriq avatar owner write" on storage.objects
for insert to authenticated
with check (
  bucket_id = 'avatars'
  and owner = auth.uid()
  and split_part(name, '/', 1) = auth.uid()::text
);

create policy "voltfriq avatar owner update" on storage.objects
for update to authenticated
using (
  bucket_id = 'avatars'
  and (owner = auth.uid() or public.is_admin())
)
with check (
  bucket_id = 'avatars'
  and (owner = auth.uid() or public.is_admin())
);

create policy "voltfriq electrician docs write" on storage.objects
for insert to authenticated
with check (
  bucket_id = 'electrician-documents'
  and (
    public.is_admin()
    or exists (
      select 1
      from public.electricians e
      where e.profile_id = auth.uid()
        and (
          split_part(storage.objects.name, '/', 1) = e.id::text
          or split_part(storage.objects.name, '/', 1) = 'appeals'
        )
    )
  )
);

create policy "voltfriq electrician docs update" on storage.objects
for update to authenticated
using (
  bucket_id = 'electrician-documents'
  and (owner = auth.uid() or public.is_admin())
)
with check (
  bucket_id = 'electrician-documents'
  and (owner = auth.uid() or public.is_admin())
);

create policy "voltfriq authenticated job photo write" on storage.objects
for insert to authenticated
with check (
  bucket_id = 'job-photos'
  and split_part(name, '/', 1) = 'job-photos'
  and split_part(name, '/', 2) = auth.uid()::text
);

create policy "voltfriq authenticated job photo update" on storage.objects
for update to authenticated
using (
  bucket_id = 'job-photos'
  and (owner = auth.uid() or public.is_admin())
)
with check (
  bucket_id = 'job-photos'
  and (owner = auth.uid() or public.is_admin())
);

create policy "voltfriq authenticated payment proof write" on storage.objects
for insert to authenticated
with check (
  bucket_id = 'payment-proofs'
  and (
    public.is_admin()
    or split_part(name, '/', 1) = 'payments'
  )
);

create policy "voltfriq authenticated payment proof update" on storage.objects
for update to authenticated
using (
  bucket_id = 'payment-proofs'
  and (owner = auth.uid() or public.is_admin())
)
with check (
  bucket_id = 'payment-proofs'
  and (owner = auth.uid() or public.is_admin())
);

create policy "voltfriq guest upload write" on storage.objects
for insert to anon
with check (
  bucket_id in ('job-photos', 'payment-proofs')
  and split_part(name, '/', 1) = 'guest'
);

