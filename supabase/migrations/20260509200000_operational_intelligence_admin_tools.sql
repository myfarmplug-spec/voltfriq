-- Operational intelligence tooling:
-- - admin-safe retry/reconcile/alert resolution RPCs
-- - optional guest dispatch OTP gate controlled by admin_settings.trust_settings
-- - richer queue payload for snapshot drift and operational actions

create or replace function public.guest_dispatch_otp_required()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select coalesce((
    select case
      when trust_settings ? 'guest_dispatch_otp_required' then (trust_settings ->> 'guest_dispatch_otp_required')::boolean
      when trust_settings ? 'guestDispatchOtpRequired' then (trust_settings ->> 'guestDispatchOtpRequired')::boolean
      else false
    end
    from public.admin_settings
    order by updated_at desc
    limit 1
  ), false);
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
    dispatch_verification := public.prepare_guest_dispatch_otp(
      created_job.id,
      access_token,
      p_phone,
      p_client_fingerprint
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

create or replace function public.verify_guest_otp(
  p_job_id uuid,
  p_access_token text,
  p_action_type text,
  p_challenge_id uuid,
  p_otp_code text
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  job_row public.jobs;
  otp_row public.guest_otps;
begin
  if p_action_type not in ('cancel_job', 'payment_proof', 'dispute', 'customer_confirmed', 'dispatch_confirm') then
    raise exception 'Unsupported guest action';
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

  select * into otp_row
  from public.guest_otps
  where id = p_challenge_id
    and job_id = p_job_id
    and action_type = p_action_type
  for update;

  if not found then
    raise exception 'OTP challenge not found';
  end if;

  if otp_row.consumed_at is not null or otp_row.expires_at <= now() then
    raise exception 'OTP has expired. Request a new code.';
  end if;

  if otp_row.attempts >= 5 then
    raise exception 'Too many OTP attempts. Request a new code.';
  end if;

  if otp_row.code_hash <> md5('voltfriq-otp:' || regexp_replace(coalesce(p_otp_code, ''), '\D', '', 'g') || ':' || p_job_id::text || ':' || p_action_type) then
    update public.guest_otps
    set attempts = attempts + 1
    where id = p_challenge_id;
    raise exception 'Invalid OTP code.';
  end if;

  update public.guest_otps
  set verified_at = coalesce(verified_at, now()),
      delivery_status = 'verified'
  where id = p_challenge_id;

  if p_action_type = 'dispatch_confirm' then
    update public.jobs
    set guest_dispatch_verified_at = coalesce(guest_dispatch_verified_at, now())
    where id = p_job_id
    returning * into job_row;

    if job_row.status = 'requested' then
      perform public.log_job_event(
        p_job_id,
        'PAIRING_STARTED',
        'guest',
        null,
        'Pairing you with a VoltFriq.',
        'Guest phone OTP verified. Dispatch started.',
        jsonb_build_object(
          'next_status', 'matching',
          'source', 'verify_guest_otp',
          'idempotency_key', 'guest-dispatch-confirmed:' || p_job_id::text || ':' || p_challenge_id::text
        )
      );
      select * into job_row from public.dispatch_job_internal(p_job_id, null);
    end if;
  end if;

  return jsonb_build_object('verified', true, 'challenge_id', p_challenge_id);
end;
$$;

create or replace function public.admin_retry_dispatch_job(p_job_id uuid)
returns public.jobs
language plpgsql
security definer
set search_path = public
as $$
declare
  job_row public.jobs;
begin
  if not (public.is_admin() or auth.role() = 'service_role') then
    raise exception 'Admin access required';
  end if;

  perform public.reconcile_job_snapshot_from_events(p_job_id, 'admin-retry-dispatch');

  select * into job_row
  from public.jobs
  where id = p_job_id
  for update;

  if not found then
    raise exception 'Job not found';
  end if;

  if job_row.status = 'assigned'
     and job_row.assignment_expires_at is not null
     and job_row.assignment_expires_at > now() then
    raise exception 'This job has an active assignment. Wait for expiry, rejection, or manual override.';
  end if;

  if job_row.status = 'assigned' then
    update public.jobs
    set status = 'matching',
        assigned_electrician_id = null,
        assignment_expires_at = null,
        current_assignment_event_id = null,
        current_assignment_token = null,
        state_version = coalesce(state_version, 0) + 1
    where id = p_job_id
    returning * into job_row;

    perform public.log_job_event(
      p_job_id,
      'ASSIGNMENT_EXPIRED',
      'admin',
      auth.uid(),
      'Still finding a verified VoltFriq near you.',
      'Admin retried dispatch after clearing an expired assignment.',
      jsonb_build_object(
        'next_status', 'matching',
        'source', 'admin_retry_dispatch_job',
        'idempotency_key', 'admin-retry-expired:' || p_job_id::text || ':' || job_row.state_version::text
      )
    );
  end if;

  if job_row.status not in ('requested', 'matching') then
    raise exception 'Only requested or matching jobs can be retried safely.';
  end if;

  select * into job_row from public.dispatch_job_internal(p_job_id, null);
  perform public.refresh_operational_alerts();
  return job_row;
end;
$$;

create or replace function public.admin_reconcile_job_state(p_job_id uuid)
returns public.jobs
language plpgsql
security definer
set search_path = public
as $$
declare
  job_row public.jobs;
begin
  if not (public.is_admin() or auth.role() = 'service_role') then
    raise exception 'Admin access required';
  end if;

  select * into job_row from public.reconcile_job_snapshot_from_events(p_job_id, 'admin-reconcile');
  perform public.refresh_operational_alerts();
  return job_row;
end;
$$;

create or replace function public.admin_resolve_operational_alert(
  p_alert_id uuid,
  p_note text default null
) returns public.operational_alerts
language plpgsql
security definer
set search_path = public
as $$
declare
  alert_row public.operational_alerts;
begin
  if not (public.is_admin() or auth.role() = 'service_role') then
    raise exception 'Admin access required';
  end if;

  update public.operational_alerts
  set status = 'resolved',
      resolved_at = coalesce(resolved_at, now()),
      metadata = coalesce(metadata, '{}'::jsonb) || jsonb_strip_nulls(jsonb_build_object(
        'resolved_by', auth.uid(),
        'resolution_note', nullif(btrim(coalesce(p_note, '')), '')
      ))
  where id = p_alert_id
  returning * into alert_row;

  if alert_row.id is null then
    raise exception 'Operational alert not found';
  end if;

  return alert_row;
end;
$$;

create or replace function public.admin_operational_queues()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  payload jsonb;
begin
  if not (public.is_admin() or auth.role() = 'service_role') then
    raise exception 'Admin access required';
  end if;

  perform public.refresh_operational_alerts();

  select jsonb_build_object(
    'pending_payments', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', p.id,
        'job_id', p.job_id,
        'ticket', j.ticket,
        'payment_type', p.payment_type,
        'amount', p.amount,
        'created_at', p.created_at,
        'age_seconds', extract(epoch from (now() - p.created_at))
      ) order by p.created_at asc)
      from public.job_payments p
      join public.jobs j on j.id = p.job_id
      where p.status = 'submitted'
    ), '[]'::jsonb),
    'pending_electricians', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', e.id,
        'profile_id', e.profile_id,
        'display_name', coalesce(nullif(p.full_name, ''), p.email, 'VoltFriq applicant'),
        'created_at', e.created_at,
        'service_areas', e.service_areas,
        'onboarding_completed', e.onboarding_completed
      ) order by e.created_at asc)
      from public.electricians e
      join public.profiles p on p.id = e.profile_id
      where e.status = 'pending'
    ), '[]'::jsonb),
    'stuck_jobs', coalesce((
      select jsonb_agg(jsonb_build_object(
        'job_id', s.job_id,
        'ticket', j.ticket,
        'status', j.status,
        'stuck_type', s.stuck_type,
        'severity', s.severity,
        'reason', s.reason,
        'stuck_since', s.stuck_since,
        'action', 'retry_dispatch'
      ) order by s.stuck_since asc)
      from public.detect_stuck_jobs() s
      join public.jobs j on j.id = s.job_id
    ), '[]'::jsonb),
    'failed_pairing_jobs', coalesce((
      select jsonb_agg(jsonb_build_object(
        'job_id', j.id,
        'ticket', j.ticket,
        'status', j.status,
        'dispatch_attempts', j.dispatch_attempts,
        'last_dispatch_at', j.last_dispatch_at,
        'action', 'retry_dispatch'
      ) order by j.dispatch_attempts desc, j.last_dispatch_at asc)
      from public.jobs j
      where j.status = 'matching'
        and j.dispatch_attempts >= 3
    ), '[]'::jsonb),
    'snapshot_drift_jobs', coalesce((
      select jsonb_agg(jsonb_build_object(
        'job_id', s.job_id,
        'ticket', s.ticket,
        'snapshot_status', s.snapshot_status,
        'event_status', s.event_status,
        'latest_event_id', s.latest_event_id,
        'latest_event_at', s.latest_event_at,
        'action', 'reconcile_state'
      ) order by s.latest_event_at asc)
      from public.detect_snapshot_drift() s
    ), '[]'::jsonb),
    'payment_backlog', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', p.id,
        'job_id', p.job_id,
        'ticket', j.ticket,
        'created_at', p.created_at,
        'age_seconds', extract(epoch from (now() - p.created_at))
      ) order by p.created_at asc)
      from public.job_payments p
      join public.jobs j on j.id = p.job_id
      where p.status = 'submitted'
        and p.created_at < now() - interval '30 minutes'
    ), '[]'::jsonb),
    'open_disputes', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', d.id,
        'job_id', d.job_id,
        'ticket', j.ticket,
        'issue_type', d.issue_type,
        'created_at', d.created_at
      ) order by d.created_at asc)
      from public.disputes d
      left join public.jobs j on j.id = d.job_id
      where d.status = 'open'
    ), '[]'::jsonb),
    'expired_assignments', coalesce((
      select jsonb_agg(jsonb_build_object(
        'job_id', j.id,
        'ticket', j.ticket,
        'assigned_electrician_id', j.assigned_electrician_id,
        'assignment_expires_at', j.assignment_expires_at,
        'action', 'retry_dispatch'
      ) order by j.assignment_expires_at asc)
      from public.jobs j
      where j.status = 'assigned'
        and j.assignment_expires_at is not null
        and j.assignment_expires_at <= now()
    ), '[]'::jsonb),
    'high_rejection_electricians', coalesce((
      select jsonb_agg(jsonb_build_object(
        'electrician_id', e.id,
        'profile_id', e.profile_id,
        'display_name', coalesce(nullif(p.full_name, ''), p.email, 'VoltFriq'),
        'acceptance_score', e.acceptance_score,
        'response_score', e.response_score,
        'completion_score', e.completion_score,
        'dispute_score', e.dispute_score,
        'payout_confidence_score', e.payout_confidence_score,
        'quality_tier', e.quality_tier,
        'quality_penalty_until', e.quality_penalty_until,
        'rejection_rate', latest.rejection_rate
      ) order by latest.rejection_rate desc)
      from public.electricians e
      join public.profiles p on p.id = e.profile_id
      join lateral (
        select s.rejection_rate
        from public.electrician_performance_snapshots s
        where s.electrician_id = e.id
        order by s.snapshot_at desc
        limit 1
      ) latest on true
      where latest.rejection_rate >= 50
         or e.quality_tier in ('Watch', 'Recovery')
         or (e.quality_penalty_until is not null and e.quality_penalty_until > now())
    ), '[]'::jsonb),
    'upload_failures', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', f.id,
        'job_id', f.job_id,
        'failure_stage', f.failure_stage,
        'error_message', f.error_message,
        'created_at', f.created_at
      ) order by f.created_at desc)
      from public.upload_failures f
      where f.created_at > now() - interval '24 hours'
    ), '[]'::jsonb),
    'alerts', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', a.id,
        'alert_type', a.alert_type,
        'severity', a.severity,
        'job_id', a.job_id,
        'electrician_id', a.electrician_id,
        'payment_id', a.payment_id,
        'dispute_id', a.dispute_id,
        'message', a.message,
        'last_seen_at', a.last_seen_at,
        'age_seconds', extract(epoch from (now() - a.last_seen_at)),
        'action', case
          when a.alert_type in ('stuck_pairing', 'failed_pairing', 'expired_assignment') and a.job_id is not null then 'retry_dispatch'
          when a.alert_type = 'snapshot_drift' and a.job_id is not null then 'reconcile_state'
          else 'review'
        end
      ) order by case a.severity when 'critical' then 0 when 'warning' then 1 else 2 end, a.last_seen_at asc)
      from public.operational_alerts a
      where a.status = 'open'
    ), '[]'::jsonb)
  ) into payload;

  return payload;
end;
$$;

revoke all on function public.guest_dispatch_otp_required() from public, anon, authenticated;
grant execute on function public.guest_dispatch_otp_required() to service_role;

revoke all on function public.create_guest_customer_job(text,text,text,double precision,double precision,text,public.job_urgency,text,boolean,text,text[],text) from public, anon, authenticated, service_role;
grant execute on function public.create_guest_customer_job(text,text,text,double precision,double precision,text,public.job_urgency,text,boolean,text,text[],text) to anon, authenticated, service_role;

revoke all on function public.verify_guest_otp(uuid,text,text,uuid,text) from public, anon, authenticated, service_role;
grant execute on function public.verify_guest_otp(uuid,text,text,uuid,text) to anon, authenticated, service_role;

revoke all on function public.admin_retry_dispatch_job(uuid) from public, anon, authenticated;
grant execute on function public.admin_retry_dispatch_job(uuid) to authenticated, service_role;

revoke all on function public.admin_reconcile_job_state(uuid) from public, anon, authenticated;
grant execute on function public.admin_reconcile_job_state(uuid) to authenticated, service_role;

revoke all on function public.admin_resolve_operational_alert(uuid,text) from public, anon, authenticated;
grant execute on function public.admin_resolve_operational_alert(uuid,text) to authenticated, service_role;

revoke all on function public.admin_operational_queues() from public, anon, authenticated;
grant execute on function public.admin_operational_queues() to authenticated, service_role;

notify pgrst, 'reload schema';
