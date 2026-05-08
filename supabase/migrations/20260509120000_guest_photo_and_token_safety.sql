-- Guest photo uploads and token safety:
-- - photos attach only through service-role API after access-token validation
-- - guest sensitive actions soft-expire after 30 days
-- - guest payment/cancellation/completion require phone last-4 confirmation

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

  if job_row.created_at < now() - interval '30 days' then
    raise exception 'This guest upload link has expired. Contact VoltFriq support to add photos.';
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
  p_proof_path text,
  p_phone_confirmation text default null
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
  guest_phone text;
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
    raise exception 'This guest payment link has expired. Contact VoltFriq support to continue.';
  end if;

  select phone into guest_phone
  from public.guest_customers
  where id = job_row.guest_customer_id;

  if right(regexp_replace(coalesce(guest_phone, ''), '\D', '', 'g'), 4) <> right(regexp_replace(coalesce(p_phone_confirmation, ''), '\D', '', 'g'), 4) then
    raise exception 'Confirm the phone number used for this booking.';
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

create or replace function public.update_guest_job_status(
  p_job_id uuid,
  p_access_token text,
  p_next_status public.job_status,
  p_note text default null,
  p_metadata jsonb default '{}'::jsonb
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  job_row public.jobs;
  guest_phone text;
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

  if p_next_status in ('cancelled', 'customer_confirmed') then
    select phone into guest_phone
    from public.guest_customers
    where id = job_row.guest_customer_id;

    if right(regexp_replace(coalesce(guest_phone, ''), '\D', '', 'g'), 4) <> right(regexp_replace(coalesce(p_metadata->>'phone_confirmation', ''), '\D', '', 'g'), 4) then
      raise exception 'Confirm the phone number used for this booking.';
    end if;
  end if;

  if not (
    (job_row.status = 'quoted' and p_next_status = 'quote_accepted')
    or (job_row.status = 'electrician_completed' and p_next_status = 'customer_confirmed')
    or (
      p_next_status = 'cancelled'
      and job_row.status in (
        'requested',
        'matching',
        'assigned',
        'accepted',
        'assessment_fee_pending',
        'quoted'
      )
    )
  ) then
    raise exception 'Guest customers cannot move a job from % to %', job_row.status, p_next_status;
  end if;

  update public.jobs
  set status = p_next_status,
      customer_confirmed_at = case when p_next_status = 'customer_confirmed' then coalesce(customer_confirmed_at, now()) else customer_confirmed_at end
  where id = p_job_id;

  insert into public.job_timeline (job_id, status, note, actor_profile_id, metadata)
  values (p_job_id, p_next_status, p_note, null, coalesce(p_metadata, '{}'::jsonb));

  return public.guest_job_payload(p_job_id, p_access_token);
end;
$$;

revoke all on function public.attach_guest_job_photos(uuid,text,text[]) from public, anon, authenticated;
grant execute on function public.attach_guest_job_photos(uuid,text,text[]) to service_role;

revoke all on function public.submit_guest_payment_proof(uuid,text,public.payment_type,numeric,text,text) from public, anon, authenticated, service_role;
grant execute on function public.submit_guest_payment_proof(uuid,text,public.payment_type,numeric,text,text,text) to anon, authenticated, service_role;

notify pgrst, 'reload schema';
