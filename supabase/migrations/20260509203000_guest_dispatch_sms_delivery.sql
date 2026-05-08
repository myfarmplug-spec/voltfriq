-- Guest dispatch OTP delivery:
-- - guest bookings can remain held at requested until phone OTP is verified
-- - OTP code generation for dispatch now happens through a service-role RPC
-- - public clients no longer call the "prepare dispatch OTP" RPC directly

create or replace function public.create_guest_otp_delivery(
  p_job_id uuid,
  p_access_token text,
  p_action_type text,
  p_phone_confirmation text,
  p_client_fingerprint text default null
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  job_row public.jobs;
  guest_phone text;
  otp_payload jsonb;
begin
  if auth.role() <> 'service_role' then
    raise exception 'Service role required';
  end if;

  if p_action_type <> 'dispatch_confirm' then
    raise exception 'Unsupported guest OTP delivery action';
  end if;

  select * into job_row
  from public.jobs
  where id = p_job_id
    and customer_access_token = p_access_token
    and guest_customer_id is not null
  for update;

  if not found then
    raise exception 'Guest job not found';
  end if;

  if job_row.guest_dispatch_verified_at is not null then
    raise exception 'This booking has already been verified for dispatch.';
  end if;

  if job_row.status <> 'requested' then
    raise exception 'This booking is already in dispatch.';
  end if;

  select phone into guest_phone
  from public.guest_customers
  where id = job_row.guest_customer_id;

  if coalesce(guest_phone, '') = '' then
    raise exception 'Guest phone number not found.';
  end if;

  otp_payload := public.request_guest_otp(
    p_job_id,
    p_access_token,
    p_action_type,
    p_phone_confirmation,
    p_client_fingerprint
  );

  return jsonb_strip_nulls(
    otp_payload ||
    jsonb_build_object(
      'phone', guest_phone,
      'delivery_channel', 'sms'
    )
  );
end;
$$;

create or replace function public.mark_guest_otp_delivery(
  p_challenge_id uuid,
  p_delivery_status text,
  p_metadata jsonb default '{}'::jsonb
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  otp_row public.guest_otps;
begin
  if auth.role() <> 'service_role' then
    raise exception 'Service role required';
  end if;

  if p_delivery_status not in ('pending', 'sent', 'failed', 'verified') then
    raise exception 'Unsupported OTP delivery status';
  end if;

  update public.guest_otps
  set delivery_status = p_delivery_status,
      metadata = coalesce(metadata, '{}'::jsonb) ||
        coalesce(p_metadata, '{}'::jsonb) ||
        jsonb_build_object('delivery_updated_at', now())
  where id = p_challenge_id
  returning * into otp_row;

  if not found then
    raise exception 'OTP challenge not found';
  end if;

  return jsonb_build_object(
    'challenge_id', otp_row.id,
    'delivery_status', otp_row.delivery_status
  );
end;
$$;

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
  dispatch_otp_required boolean := public.guest_dispatch_otp_required();
  dispatch_verification jsonb := null;
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
    case when dispatch_otp_required then 'requested'::public.job_status else 'matching'::public.job_status end
  )
  returning * into created_job;

  update public.guest_booking_attempts
  set job_id = created_job.id
  where id = attempt_id;

  insert into public.job_timeline (job_id, status, note, actor_profile_id, metadata)
  values (
    created_job.id,
    'requested',
    'Guest customer created a new booking request.',
    null,
    jsonb_build_object('guest_customer_id', guest_row.id, 'guest_dispatch_otp_required', dispatch_otp_required)
  );

  if dispatch_otp_required then
    dispatch_verification := jsonb_build_object(
      'delivery_status', 'required',
      'masked_phone', '***' || right(normalized_phone, 4)
    );
  else
    insert into public.job_timeline (job_id, status, note, actor_profile_id, metadata)
    values (created_job.id, 'matching', 'Automatic dispatch started.', null, '{}'::jsonb);

    select * into created_job from public.dispatch_job_internal(created_job.id, null);
  end if;

  return jsonb_strip_nulls(jsonb_build_object(
    'access_token', access_token,
    'job', public.guest_job_payload(created_job.id, access_token),
    'dispatch_otp_required', dispatch_otp_required,
    'dispatch_verification', dispatch_verification
  ));
end;
$$;

revoke all on function public.create_guest_otp_delivery(uuid,text,text,text,text) from public, anon, authenticated, service_role;
grant execute on function public.create_guest_otp_delivery(uuid,text,text,text,text) to service_role;

revoke all on function public.mark_guest_otp_delivery(uuid,text,jsonb) from public, anon, authenticated, service_role;
grant execute on function public.mark_guest_otp_delivery(uuid,text,jsonb) to service_role;

revoke all on function public.prepare_guest_dispatch_otp(uuid,text,text,text) from public, anon, authenticated, service_role;
grant execute on function public.prepare_guest_dispatch_otp(uuid,text,text,text) to service_role;

revoke all on function public.create_guest_customer_job(text,text,text,double precision,double precision,text,public.job_urgency,text,boolean,text,text[],text) from public, anon, authenticated, service_role;
grant execute on function public.create_guest_customer_job(text,text,text,double precision,double precision,text,public.job_urgency,text,boolean,text,text[],text) to anon, authenticated, service_role;

select pg_notify('pgrst', 'reload schema');
