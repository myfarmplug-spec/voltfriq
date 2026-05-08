-- VoltFriq v21 event authority and operational reliability pass.
-- Keep jobs.status as the current snapshot, while making job_events the
-- authoritative audit path for every future status transition.

alter table public.job_events
  add column if not exists payload jsonb not null default '{}'::jsonb;

update public.job_events
set payload = coalesce(nullif(payload, '{}'::jsonb), metadata, '{}'::jsonb)
where payload = '{}'::jsonb
  and coalesce(metadata, '{}'::jsonb) <> '{}'::jsonb;

alter table public.electricians
  add column if not exists reliability_score numeric(5,2) not null default 100,
  add column if not exists tier text not null default 'Trusted';

alter table public.electrician_performance_snapshots
  add column if not exists reliability_score numeric(6,2) not null default 100,
  add column if not exists tier text not null default 'Trusted';

update public.electricians
set reliability_score = greatest(0, least(100, round((
      coalesce(response_score, response_rate, 100) * 0.20
    + coalesce(acceptance_score, acceptance_rate, 100) * 0.20
    + coalesce(completion_score, 100) * 0.22
    + coalesce(dispute_score, 100) * 0.22
    + coalesce(payout_confidence_score, payout_reliability_score, 100) * 0.16
  )::numeric, 2))),
  tier = coalesce(nullif(quality_tier, ''), tier, 'Trusted');

update public.electrician_performance_snapshots
set reliability_score = coalesce(nullif(score, 0), reliability_score, 100),
    tier = coalesce(nullif(quality_tier, ''), tier, 'Trusted');

create or replace function public.sync_job_event_payload()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if coalesce(new.metadata, '{}'::jsonb) = '{}'::jsonb
     and coalesce(new.payload, '{}'::jsonb) <> '{}'::jsonb then
    new.metadata := new.payload;
  end if;

  new.payload := coalesce(new.metadata, new.payload, '{}'::jsonb);
  return new;
end;
$$;

drop trigger if exists sync_job_event_payload_trigger on public.job_events;
create trigger sync_job_event_payload_trigger
  before insert or update of metadata, payload on public.job_events
  for each row
  execute function public.sync_job_event_payload();

create or replace function public.sync_electrician_reliability_aliases()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  new.reliability_score := greatest(0, least(100, round((
      coalesce(new.response_score, new.response_rate, 100) * 0.20
    + coalesce(new.acceptance_score, new.acceptance_rate, 100) * 0.20
    + coalesce(new.completion_score, 100) * 0.22
    + coalesce(new.dispute_score, 100) * 0.22
    + coalesce(new.payout_confidence_score, new.payout_reliability_score, 100) * 0.16
  )::numeric, 2)));
  new.tier := coalesce(nullif(new.quality_tier, ''), new.tier, 'Trusted');
  return new;
end;
$$;

drop trigger if exists sync_electrician_reliability_aliases_trigger on public.electricians;
create trigger sync_electrician_reliability_aliases_trigger
  before insert or update of response_score, response_rate, acceptance_score, acceptance_rate,
    completion_score, dispute_score, payout_confidence_score, payout_reliability_score, quality_tier
  on public.electricians
  for each row
  execute function public.sync_electrician_reliability_aliases();

create or replace function public.sync_electrician_snapshot_reliability_aliases()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  new.reliability_score := coalesce(nullif(new.score, 0), new.reliability_score, 100);
  new.tier := coalesce(nullif(new.quality_tier, ''), new.tier, 'Trusted');
  return new;
end;
$$;

drop trigger if exists sync_electrician_snapshot_reliability_aliases_trigger on public.electrician_performance_snapshots;
create trigger sync_electrician_snapshot_reliability_aliases_trigger
  before insert or update of score, quality_tier
  on public.electrician_performance_snapshots
  for each row
  execute function public.sync_electrician_snapshot_reliability_aliases();

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
    coalesce(new.metadata, '{}'::jsonb) ||
      jsonb_build_object(
        'timeline_id', new.id,
        'next_status', new.status,
        'source', coalesce(new.metadata ->> 'source', 'job_timeline'),
        'idempotency_key', 'timeline:' || new.id::text
      )
  );
  return new;
end;
$$;

create or replace function public.enforce_job_status_event()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  required_status public.job_status := new.status;
  required_version integer := coalesce(new.state_version, 0);
  has_event boolean;
begin
  if tg_op = 'UPDATE' and old.status is not distinct from new.status then
    return new;
  end if;

  select exists (
    select 1
    from public.job_events e
    where e.job_id = new.id
      and public.job_status_for_event(e.event_type, coalesce(e.metadata, e.payload, '{}'::jsonb)) = required_status
      and coalesce(e.event_version, e.transition_to_version, 0) >= required_version
  ) into has_event;

  if not has_event then
    perform public.upsert_operational_alert(
      'state_conflict',
      'critical',
      'Job snapshot status change was rejected because no matching canonical event exists.',
      new.id,
      new.assigned_electrician_id,
      null,
      null,
      null,
      jsonb_build_object(
        'operation', tg_op,
        'required_status', required_status,
        'required_version', required_version,
        'previous_status', case when tg_op = 'UPDATE' then old.status::text else null end,
        'source', 'enforce_job_status_event'
      )
    );
    raise exception 'Job status % requires a matching job_events record', required_status;
  end if;

  return new;
end;
$$;

drop trigger if exists enforce_job_status_event_insert_trigger on public.jobs;
create constraint trigger enforce_job_status_event_insert_trigger
  after insert on public.jobs
  deferrable initially deferred
  for each row
  execute function public.enforce_job_status_event();

drop trigger if exists enforce_job_status_event_update_trigger on public.jobs;
create constraint trigger enforce_job_status_event_update_trigger
  after update of status on public.jobs
  deferrable initially deferred
  for each row
  execute function public.enforce_job_status_event();

create or replace function public.create_customer_job(
  p_service_area text,
  p_location_label text,
  p_latitude double precision,
  p_longitude double precision,
  p_issue_category text,
  p_urgency public.job_urgency,
  p_customer_note text,
  p_requires_assessment boolean,
  p_material_handling text,
  p_photo_paths text[] default '{}'::text[]
) returns public.jobs
language plpgsql
security definer
set search_path = public
as $$
declare
  customer_row public.customers;
  created_job public.jobs;
  actor_profile_id uuid;
begin
  select * into customer_row from public.customers where profile_id = auth.uid();
  if not found then
    raise exception 'Customer profile not found';
  end if;

  actor_profile_id := customer_row.profile_id;

  update public.customers
  set primary_service_area = coalesce(p_location_label, p_service_area, primary_service_area),
      location_label = coalesce(p_location_label, location_label),
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
    'requested'
  )
  returning * into created_job;

  perform public.log_job_event(
    created_job.id,
    'JOB_CREATED',
    'customer',
    actor_profile_id,
    'Booking confirmed.',
    'Customer created a new booking request.',
    jsonb_build_object(
      'next_status', 'requested',
      'source', 'create_customer_job',
      'idempotency_key', 'job-created:' || created_job.id::text
    )
  );

  insert into public.job_photos (job_id, file_path)
  select created_job.id, photo_path
  from unnest(coalesce(p_photo_paths, '{}'::text[])) as photo_path;

  created_job := public.transition_job_state(
    created_job.id,
    'matching',
    'customer',
    actor_profile_id,
    'Pairing you with a VoltFriq.',
    'Automatic dispatch started.',
    jsonb_build_object('source', 'create_customer_job', 'expected_status', 'requested'),
    'requested',
    'pairing-started:' || created_job.id::text
  );

  perform public.create_notification(actor_profile_id, created_job.id, 'new_job_created', 'Booking created', 'We are finding the nearest verified VoltFriq for you.', '{}'::jsonb);

  select * into created_job from public.dispatch_job_internal(created_job.id, null);
  return created_job;
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
    'requested'
  )
  returning * into created_job;

  update public.guest_booking_attempts
  set job_id = created_job.id
  where id = attempt_id;

  perform public.log_job_event(
    created_job.id,
    'JOB_CREATED',
    'guest',
    null,
    'Booking confirmed.',
    'Guest customer created a new booking request.',
    jsonb_build_object(
      'guest_customer_id', guest_row.id,
      'guest_dispatch_otp_required', dispatch_otp_required,
      'next_status', 'requested',
      'source', 'create_guest_customer_job',
      'idempotency_key', 'job-created:' || created_job.id::text
    )
  );

  if dispatch_otp_required then
    dispatch_verification := jsonb_build_object(
      'delivery_status', 'required',
      'masked_phone', '***' || right(normalized_phone, 4)
    );
  else
    created_job := public.transition_job_state(
      created_job.id,
      'matching',
      'guest',
      null,
      'Pairing you with a VoltFriq.',
      'Automatic dispatch started.',
      jsonb_build_object('guest_customer_id', guest_row.id, 'source', 'create_guest_customer_job', 'expected_status', 'requested'),
      'requested',
      'pairing-started:' || created_job.id::text
    );

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

create or replace function public.electrician_reject_job(p_job_id uuid)
returns public.jobs
language plpgsql
security definer
set search_path = public
as $$
declare
  electrician_row public.electricians;
  job_row public.jobs;
  assignment_event public.job_events;
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

  select * into assignment_event
  from public.job_events
  where id = job_row.current_assignment_event_id
    and job_id = p_job_id
    and event_type = 'ELECTRICIAN_ASSIGNED';

  if not found then
    select * into assignment_event
    from public.job_events
    where job_id = p_job_id
      and event_type = 'ELECTRICIAN_ASSIGNED'
      and (
        metadata ->> 'electrician_id' = electrician_row.id::text
        or metadata ->> 'electrician_id' is null
      )
    order by created_at desc, id desc
    limit 1;
  end if;

  if assignment_event.id is null then
    perform public.upsert_operational_alert(
      'state_conflict',
      'warning',
      'Assignment rejection could not find a canonical assignment event.',
      p_job_id,
      electrician_row.id,
      null,
      null,
      job_row.current_assignment_event_id,
      jsonb_build_object('current_assignment_event_id', job_row.current_assignment_event_id)
    );
    raise exception 'This assignment has changed. Refresh your jobs before rejecting.';
  end if;

  if assignment_event.metadata ->> 'electrician_id' is null then
    update public.job_events
    set metadata = coalesce(metadata, '{}'::jsonb) || jsonb_build_object('electrician_id', electrician_row.id)
    where id = assignment_event.id
    returning * into assignment_event;
  end if;

  if nullif(job_row.current_assignment_token, '') is null then
    job_row.current_assignment_token := coalesce(nullif(assignment_event.metadata ->> 'assignment_token', ''), replace(gen_random_uuid()::text, '-', '') || replace(gen_random_uuid()::text, '-', ''));
    update public.job_events
    set metadata = coalesce(metadata, '{}'::jsonb) || jsonb_build_object('assignment_token', job_row.current_assignment_token)
    where id = assignment_event.id
    returning * into assignment_event;
    update public.jobs
    set current_assignment_event_id = assignment_event.id,
        current_assignment_token = job_row.current_assignment_token
    where id = p_job_id;
  end if;

  if assignment_event.metadata ->> 'electrician_id' is distinct from electrician_row.id::text
     or nullif(assignment_event.metadata ->> 'assignment_token', '') is distinct from nullif(job_row.current_assignment_token, '') then
    perform public.upsert_operational_alert(
      'state_conflict',
      'warning',
      'Stale assignment rejection was blocked.',
      p_job_id,
      electrician_row.id,
      null,
      null,
      coalesce(assignment_event.id, job_row.current_assignment_event_id),
      jsonb_build_object('current_assignment_event_id', job_row.current_assignment_event_id)
    );
    raise exception 'This assignment has changed. Refresh your jobs before rejecting.';
  end if;

  update public.jobs
  set status = 'matching',
      assigned_electrician_id = null,
      assignment_expires_at = null,
      current_assignment_event_id = null,
      current_assignment_token = null,
      state_version = coalesce(state_version, 0) + 1,
      updated_at = now()
  where id = p_job_id
    and status = 'assigned'
    and assigned_electrician_id = electrician_row.id
    and (
      current_assignment_event_id = assignment_event.id
      or current_assignment_event_id is null
    )
  returning * into job_row;

  if job_row.id is null then
    raise exception 'This assignment is no longer available.';
  end if;

  perform public.log_job_event(
    p_job_id,
    'ASSIGNMENT_REJECTED',
    'electrician',
    auth.uid(),
    'Pairing you with a VoltFriq.',
    'Assigned VoltFriq declined the booking. Re-dispatch started.',
    jsonb_build_object(
      'electrician_id', electrician_row.id,
      'assignment_event_id', assignment_event.id,
      'assignment_token', coalesce(job_row.current_assignment_token, assignment_event.metadata ->> 'assignment_token'),
      'previous_status', 'assigned',
      'next_status', 'matching',
      'state_version', job_row.state_version,
      'source', 'electrician_reject_job',
      'idempotency_key', 'assignment-rejected:' || p_job_id::text || ':' || electrician_row.id::text || ':' || assignment_event.id::text
    )
  );

  perform public.refresh_electrician_performance_snapshot(electrician_row.id);
  select * into job_row from public.dispatch_job_internal(p_job_id, null);
  return job_row;
end;
$$;

create or replace function public.detect_stuck_jobs()
returns table(
  job_id uuid,
  stuck_type text,
  severity text,
  reason text,
  stuck_since timestamptz
)
language sql
security definer
set search_path = public
as $$
  select
    j.id,
    case
      when j.status = 'assigned' and j.assignment_expires_at is not null and j.assignment_expires_at <= now() then 'expired_assignment'
      when j.status = 'matching' and coalesce(j.last_dispatch_at, j.updated_at, j.created_at) < now() - interval '8 minutes' then 'stuck_pairing'
      when j.status in ('assessment_payment_pending_verification', 'work_payment_pending_verification') and j.updated_at < now() - interval '30 minutes' then 'payment_delay'
      when j.status = 'electrician_completed' and coalesce(j.electrician_completed_at, j.updated_at) < now() - interval '24 hours' then 'customer_confirmation_delay'
      else null
    end as stuck_type,
    case
      when j.status = 'assigned' and j.assignment_expires_at is not null and j.assignment_expires_at <= now() then 'critical'
      when j.status in ('assessment_payment_pending_verification', 'work_payment_pending_verification') and j.updated_at < now() - interval '2 hours' then 'critical'
      else 'warning'
    end as severity,
    case
      when j.status = 'assigned' and j.assignment_expires_at is not null and j.assignment_expires_at <= now() then 'Assignment expired before VoltFriq acceptance.'
      when j.status = 'matching' and coalesce(j.last_dispatch_at, j.updated_at, j.created_at) < now() - interval '8 minutes' then 'Pairing has exceeded the operational target.'
      when j.status in ('assessment_payment_pending_verification', 'work_payment_pending_verification') and j.updated_at < now() - interval '30 minutes' then 'Payment proof is waiting for verification beyond target.'
      when j.status = 'electrician_completed' and coalesce(j.electrician_completed_at, j.updated_at) < now() - interval '24 hours' then 'Customer completion confirmation is overdue.'
      else null
    end as reason,
    case
      when j.status = 'assigned' then j.assignment_expires_at
      when j.status = 'matching' then coalesce(j.last_dispatch_at, j.updated_at, j.created_at)
      when j.status in ('assessment_payment_pending_verification', 'work_payment_pending_verification') then j.updated_at
      when j.status = 'electrician_completed' then coalesce(j.electrician_completed_at, j.updated_at)
      else j.updated_at
    end as stuck_since
  from public.jobs j
  where j.status <> 'cancelled'
    and (
      (j.status = 'assigned' and j.assignment_expires_at is not null and j.assignment_expires_at <= now())
      or (j.status = 'matching' and coalesce(j.last_dispatch_at, j.updated_at, j.created_at) < now() - interval '8 minutes')
      or (j.status in ('assessment_payment_pending_verification', 'work_payment_pending_verification') and j.updated_at < now() - interval '30 minutes')
      or (j.status = 'electrician_completed' and coalesce(j.electrician_completed_at, j.updated_at) < now() - interval '24 hours')
    )
$$;

create or replace function public.rebuild_all_job_projections(
  p_limit integer default 500,
  p_request_id text default null
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
begin
  if auth.role() <> 'service_role' then
    raise exception 'Service role required';
  end if;
  return public.rebuild_all_projections(p_limit, p_request_id);
end;
$$;

revoke insert, update, delete, truncate on table public.jobs from anon, authenticated;
grant select on table public.jobs to anon, authenticated;
grant all on table public.jobs to service_role;

revoke all on function public.sync_job_event_payload() from public, anon, authenticated;
grant execute on function public.sync_job_event_payload() to service_role;

revoke all on function public.enforce_job_status_event() from public, anon, authenticated;
grant execute on function public.enforce_job_status_event() to service_role;

revoke all on function public.sync_electrician_reliability_aliases() from public, anon, authenticated;
grant execute on function public.sync_electrician_reliability_aliases() to service_role;

revoke all on function public.sync_electrician_snapshot_reliability_aliases() from public, anon, authenticated;
grant execute on function public.sync_electrician_snapshot_reliability_aliases() to service_role;

revoke all on function public.rebuild_all_job_projections(integer,text) from public, anon, authenticated;
grant execute on function public.rebuild_all_job_projections(integer,text) to service_role;

revoke all on function public.detect_stuck_jobs() from public, anon, authenticated;
grant execute on function public.detect_stuck_jobs() to service_role;

revoke all on function public.electrician_reject_job(uuid) from public, anon, authenticated;
grant execute on function public.electrician_reject_job(uuid) to authenticated, service_role;

select pg_notify('pgrst', 'reload schema');
