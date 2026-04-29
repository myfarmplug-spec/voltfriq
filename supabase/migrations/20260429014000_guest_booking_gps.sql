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
