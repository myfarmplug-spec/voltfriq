-- Final hardening pass:
-- - public grants are removed from internal/admin RPCs
-- - only token-scoped guest RPCs remain callable by anon
-- - guest booking is rate limited and guest uploads are tied to the booking token

create table if not exists public.guest_booking_attempts (
  id uuid primary key default gen_random_uuid(),
  phone_hash text not null,
  device_key text,
  job_id uuid references public.jobs(id) on delete set null,
  created_at timestamptz not null default now()
);

create index if not exists guest_booking_attempts_phone_created_idx
  on public.guest_booking_attempts (phone_hash, created_at desc);

create index if not exists guest_booking_attempts_device_created_idx
  on public.guest_booking_attempts (device_key, created_at desc)
  where device_key is not null;

alter table public.guest_booking_attempts enable row level security;
revoke all on table public.guest_booking_attempts from public, anon, authenticated;
grant all on table public.guest_booking_attempts to service_role;

drop function if exists public.create_guest_customer_job(
  text,
  text,
  text,
  double precision,
  double precision,
  text,
  public.job_urgency,
  text,
  boolean,
  text,
  text[]
);

create or replace function public.create_guest_customer_job(
  p_phone text,
  p_service_area text,
  p_location_label text,
  p_latitude double precision,
  p_longitude double precision,
  p_issue_category text,
  p_urgency public.job_urgency,
  p_customer_note text,
  p_requires_assessment boolean,
  p_material_handling text,
  p_photo_paths text[] default '{}'::text[],
  p_client_fingerprint text default null
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  guest_row public.guest_customers;
  created_job public.jobs;
  access_token text;
  normalized_phone text;
  phone_hash_value text;
  device_key_value text;
  recent_count integer;
  attempt_id uuid;
begin
  normalized_phone := regexp_replace(coalesce(p_phone, ''), '\D', '', 'g');
  if length(normalized_phone) < 7 then
    raise exception 'Enter a valid mobile number before submitting.';
  end if;

  if coalesce(array_length(p_photo_paths, 1), 0) > 0 then
    raise exception 'Photos must be attached after the booking is confirmed.';
  end if;

  phone_hash_value := md5('voltfriq:' || normalized_phone);
  device_key_value := nullif(
    left(regexp_replace(lower(coalesce(p_client_fingerprint, '')), '[^a-z0-9_-]', '', 'g'), 96),
    ''
  );

  select count(*) into recent_count
  from public.guest_booking_attempts
  where phone_hash = phone_hash_value
    and created_at > now() - interval '10 minutes';

  if recent_count > 0 then
    raise exception 'A booking was recently submitted with this phone. Please wait a few minutes before trying again.';
  end if;

  if device_key_value is not null then
    select count(*) into recent_count
    from public.guest_booking_attempts
    where device_key = device_key_value
      and created_at > now() - interval '10 minutes';

    if recent_count > 0 then
      raise exception 'A booking was recently submitted from this device. Please wait a few minutes before trying again.';
    end if;
  end if;

  select count(*) into recent_count
  from public.guest_booking_attempts
  where phone_hash = phone_hash_value
    and created_at > now() - interval '1 hour';

  if recent_count >= 3 then
    raise exception 'Too many recent booking attempts. Please wait a little while before submitting another booking.';
  end if;

  insert into public.guest_booking_attempts (phone_hash, device_key)
  values (phone_hash_value, device_key_value)
  returning id into attempt_id;

  insert into public.guest_customers (phone, location_label, latitude, longitude)
  values (btrim(p_phone), p_location_label, p_latitude, p_longitude)
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

  update public.guest_booking_attempts
  set job_id = created_job.id
  where id = attempt_id;

  insert into public.job_timeline (job_id, status, note, actor_profile_id, metadata)
  values
    (created_job.id, 'requested', 'Guest customer created a new booking request.', null, jsonb_build_object('guest_customer_id', guest_row.id)),
    (created_job.id, 'matching', 'Automatic dispatch started.', null, '{}'::jsonb);

  select * into created_job from public.dispatch_job_internal(created_job.id, null);

  return jsonb_build_object(
    'access_token', access_token,
    'job', public.guest_job_payload(created_job.id, access_token)
  );
end;
$$;

create or replace function public.attach_guest_job_photos(
  p_job_id uuid,
  p_access_token text,
  p_photo_paths text[]
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  job_row public.jobs;
  expected_prefix text;
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

  if coalesce(array_length(p_photo_paths, 1), 0) > 3 then
    raise exception 'Add up to 3 photos only.';
  end if;

  expected_prefix := 'guest/' || p_job_id::text || '/' || left(p_access_token, 16) || '/';

  if exists (
    select 1
    from unnest(coalesce(p_photo_paths, '{}'::text[])) as paths(photo_path)
    where photo_path is null
       or photo_path = ''
       or length(photo_path) > 500
       or photo_path not like expected_prefix || '%'
  ) then
    raise exception 'Upload photos again before submitting them.';
  end if;

  insert into public.job_photos (job_id, file_path)
  select p_job_id, paths.photo_path
  from unnest(coalesce(p_photo_paths, '{}'::text[])) as paths(photo_path)
  where not exists (
    select 1
    from public.job_photos existing
    where existing.job_id = p_job_id
      and existing.file_path = paths.photo_path
  );

  return public.guest_job_payload(p_job_id, p_access_token);
end;
$$;

create or replace function public.submit_guest_payment_proof(
  p_job_id uuid,
  p_access_token text,
  p_payment_type public.payment_type,
  p_amount numeric,
  p_reference text,
  p_proof_path text
) returns public.job_payments
language plpgsql
security definer
set search_path = public
as $$
declare
  job_row public.jobs;
  payment_row public.job_payments;
  next_status public.job_status;
  expected_prefix text;
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

  expected_prefix := 'guest/' || p_job_id::text || '/' || left(p_access_token, 16) || '/';
  if nullif(btrim(p_proof_path), '') is not null and p_proof_path not like expected_prefix || '%' then
    raise exception 'Upload the payment proof again before submitting.';
  end if;

  if job_row.status in ('electrician_completed', 'customer_confirmed', 'payout_pending', 'payout_complete', 'rated', 'cancelled') then
    raise exception 'Payment proof cannot be submitted after the job has moved past payment stages';
  end if;

  if exists (
    select 1 from public.job_payments
    where job_id = p_job_id
      and status = 'submitted'
  ) then
    raise exception 'A payment proof is already waiting for manual verification for this job';
  end if;

  if p_payment_type = 'assessment_fee' then
    if job_row.status <> 'assessment_fee_pending' then
      raise exception 'Assessment fee proof can only be submitted when the job is awaiting the assessment fee';
    end if;
    next_status := 'assessment_payment_pending_verification';
  elsif p_payment_type in ('quote_payment', 'material_payment') then
    if job_row.status <> 'quote_accepted' then
      raise exception 'Work payment proof can only be submitted after the quote is accepted';
    end if;
    next_status := 'work_payment_pending_verification';
  else
    raise exception 'Unsupported payment type for guest submission';
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

drop policy if exists "voltfriq guest upload write" on storage.objects;
create policy "voltfriq guest upload write" on storage.objects
for insert to anon
with check (
  bucket_id in ('job-photos', 'payment-proofs')
  and split_part(name, '/', 1) = 'guest'
  and length(split_part(name, '/', 2)) = 36
  and length(split_part(name, '/', 3)) >= 12
  and split_part(name, '/', 4) <> ''
  and (
    (bucket_id = 'job-photos' and ((metadata->>'size') is null or (metadata->>'size')::bigint <= 5242880))
    or (bucket_id = 'payment-proofs' and ((metadata->>'size') is null or (metadata->>'size')::bigint <= 8388608))
  )
);

revoke all on all functions in schema public from public;
revoke all on all functions in schema public from anon;
revoke all on all functions in schema public from authenticated;

grant execute on all functions in schema public to service_role;

grant execute on function public.create_guest_customer_job(text,text,text,double precision,double precision,text,public.job_urgency,text,boolean,text,text[],text) to anon, authenticated;
grant execute on function public.get_guest_job(uuid,text) to anon, authenticated;
grant execute on function public.update_guest_job_status(uuid,text,public.job_status,text,jsonb) to anon, authenticated;
grant execute on function public.submit_guest_payment_proof(uuid,text,public.payment_type,numeric,text,text) to anon, authenticated;
grant execute on function public.attach_guest_job_photos(uuid,text,text[]) to service_role;

grant execute on function public.admin_set_electrician_status(uuid,public.electrician_status,text) to authenticated;
grant execute on function public.admin_set_electrician_watchlist(uuid,boolean,text) to authenticated;
grant execute on function public.calculate_electrician_level(integer,numeric,integer,numeric,boolean) to authenticated;
grant execute on function public.create_customer_job(text,text,double precision,double precision,text,public.job_urgency,text,boolean,text,text[]) to authenticated;
grant execute on function public.create_dispute(uuid,text,text) to authenticated;
grant execute on function public.current_customer_id() to authenticated;
grant execute on function public.current_electrician_id() to authenticated;
grant execute on function public.dispatch_job(uuid,uuid) to authenticated;
grant execute on function public.electrician_accept_job(uuid) to authenticated;
grant execute on function public.electrician_level_rank(text) to authenticated;
grant execute on function public.electrician_reject_job(uuid) to authenticated;
grant execute on function public.ensure_app_account_for_current_user() to authenticated;
grant execute on function public.ensure_profile_for_current_user() to authenticated;
grant execute on function public.ensure_wallet_for_profile(uuid) to authenticated;
grant execute on function public.find_matching_electricians(text,text,double precision,double precision,integer) to authenticated;
grant execute on function public.is_admin() to authenticated;
grant execute on function public.link_referral_code(text) to authenticated;
grant execute on function public.resolve_dispute(uuid,text,text,text) to authenticated;
grant execute on function public.resolve_electrician_appeal(uuid,boolean,text) to authenticated;
grant execute on function public.set_job_status(uuid,public.job_status,text,jsonb) to authenticated;
grant execute on function public.submit_customer_review(uuid,integer,text,text[]) to authenticated;
grant execute on function public.submit_electrician_appeal(text,text) to authenticated;
grant execute on function public.submit_job_quote(uuid,text,text,jsonb) to authenticated;
grant execute on function public.submit_payment_proof(uuid,public.payment_type,numeric,text,text) to authenticated;
grant execute on function public.submit_rating(uuid,integer,text,text[]) to authenticated;
grant execute on function public.verify_job_payment(uuid,boolean,text) to authenticated;

notify pgrst, 'reload schema';
