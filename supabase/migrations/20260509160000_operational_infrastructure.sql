-- Operational infrastructure:
-- - event idempotency/integrity
-- - canonical operational queues and alerts
-- - retry-safe dispatch locks
-- - OTP challenge path before guest action-token issuance
-- - electrician performance snapshots

alter table public.job_events
  add column if not exists idempotency_key text,
  add column if not exists severity text not null default 'info',
  add column if not exists visibility text not null default 'public',
  add column if not exists source text not null default 'app';

do $$
begin
  if not exists (
    select 1 from pg_constraint
    where conname = 'job_events_severity_check'
      and conrelid = 'public.job_events'::regclass
  ) then
    alter table public.job_events
      add constraint job_events_severity_check
      check (severity in ('info', 'warning', 'critical'));
  end if;

  if not exists (
    select 1 from pg_constraint
    where conname = 'job_events_visibility_check'
      and conrelid = 'public.job_events'::regclass
  ) then
    alter table public.job_events
      add constraint job_events_visibility_check
      check (visibility in ('public', 'internal'));
  end if;
end
$$;

create unique index if not exists job_events_idempotency_key_uidx
  on public.job_events(idempotency_key)
  where idempotency_key is not null;

create index if not exists job_events_job_type_created_idx
  on public.job_events(job_id, event_type, created_at desc);

create table if not exists public.operational_alerts (
  id uuid primary key default gen_random_uuid(),
  alert_type text not null check (alert_type in (
    'pending_payment',
    'pending_electrician',
    'stuck_pairing',
    'expired_assignment',
    'open_dispute',
    'payment_delay',
    'customer_confirmation_delay',
    'dispatch_conflict',
    'electrician_performance'
  )),
  severity text not null default 'warning' check (severity in ('info', 'warning', 'critical')),
  status text not null default 'open' check (status in ('open', 'resolved')),
  dedupe_key text not null unique,
  job_id uuid references public.jobs(id) on delete cascade,
  electrician_id uuid references public.electricians(id) on delete cascade,
  payment_id uuid references public.job_payments(id) on delete cascade,
  dispute_id uuid references public.disputes(id) on delete cascade,
  event_id uuid references public.job_events(id) on delete set null,
  message text not null,
  metadata jsonb not null default '{}'::jsonb,
  first_seen_at timestamptz not null default now(),
  last_seen_at timestamptz not null default now(),
  resolved_at timestamptz
);

create index if not exists operational_alerts_status_type_idx
  on public.operational_alerts(status, alert_type, last_seen_at desc);
create index if not exists operational_alerts_job_idx
  on public.operational_alerts(job_id) where job_id is not null;

alter table public.operational_alerts enable row level security;

drop policy if exists "operational alerts admin read" on public.operational_alerts;
create policy "operational alerts admin read"
  on public.operational_alerts
  for select
  using (public.is_admin());

drop policy if exists "operational alerts service write" on public.operational_alerts;
create policy "operational alerts service write"
  on public.operational_alerts
  using (auth.role() = 'service_role')
  with check (auth.role() = 'service_role');

create table if not exists public.guest_otps (
  id uuid primary key default gen_random_uuid(),
  job_id uuid not null references public.jobs(id) on delete cascade,
  action_type text not null check (action_type in ('cancel_job', 'payment_proof', 'dispute', 'customer_confirmed')),
  phone_last4 text not null,
  code_hash text not null,
  request_fingerprint text,
  delivery_status text not null default 'pending' check (delivery_status in ('pending', 'sent', 'failed', 'verified')),
  attempts integer not null default 0,
  expires_at timestamptz not null default (now() + interval '10 minutes'),
  verified_at timestamptz,
  consumed_at timestamptz,
  created_at timestamptz not null default now(),
  metadata jsonb not null default '{}'::jsonb
);

create index if not exists guest_otps_job_action_idx
  on public.guest_otps(job_id, action_type, created_at desc);
create index if not exists guest_otps_expiry_idx
  on public.guest_otps(expires_at)
  where verified_at is null and consumed_at is null;

alter table public.guest_otps enable row level security;

drop policy if exists "guest otps service role only" on public.guest_otps;
create policy "guest otps service role only"
  on public.guest_otps
  using (auth.role() = 'service_role')
  with check (auth.role() = 'service_role');

create table if not exists public.electrician_performance_snapshots (
  id uuid primary key default gen_random_uuid(),
  electrician_id uuid not null references public.electricians(id) on delete cascade,
  response_rate numeric(5,2) not null default 0,
  acceptance_rate numeric(5,2) not null default 0,
  rejection_rate numeric(5,2) not null default 0,
  average_accept_seconds numeric(12,2) not null default 0,
  completed_jobs integer not null default 0,
  average_rating numeric(3,2) not null default 0,
  negative_rating_count integer not null default 0,
  score numeric(6,2) not null default 0,
  snapshot_at timestamptz not null default now(),
  metadata jsonb not null default '{}'::jsonb
);

create index if not exists electrician_performance_snapshots_electrician_idx
  on public.electrician_performance_snapshots(electrician_id, snapshot_at desc);

alter table public.electrician_performance_snapshots enable row level security;

drop policy if exists "electrician performance admin read" on public.electrician_performance_snapshots;
create policy "electrician performance admin read"
  on public.electrician_performance_snapshots
  for select
  using (public.is_admin());

drop policy if exists "electrician performance service write" on public.electrician_performance_snapshots;
create policy "electrician performance service write"
  on public.electrician_performance_snapshots
  using (auth.role() = 'service_role')
  with check (auth.role() = 'service_role');

create or replace function public.operational_alert_dedupe_key(
  p_alert_type text,
  p_job_id uuid default null,
  p_electrician_id uuid default null,
  p_payment_id uuid default null,
  p_dispute_id uuid default null
) returns text
language sql
stable
as $$
  select p_alert_type || ':' ||
    coalesce(p_job_id::text, p_electrician_id::text, p_payment_id::text, p_dispute_id::text, 'global')
$$;

create or replace function public.upsert_operational_alert(
  p_alert_type text,
  p_severity text,
  p_message text,
  p_job_id uuid default null,
  p_electrician_id uuid default null,
  p_payment_id uuid default null,
  p_dispute_id uuid default null,
  p_event_id uuid default null,
  p_metadata jsonb default '{}'::jsonb
) returns public.operational_alerts
language plpgsql
security definer
set search_path = public
as $$
declare
  alert_row public.operational_alerts;
  dedupe text;
begin
  dedupe := public.operational_alert_dedupe_key(p_alert_type, p_job_id, p_electrician_id, p_payment_id, p_dispute_id);

  insert into public.operational_alerts (
    alert_type,
    severity,
    status,
    dedupe_key,
    job_id,
    electrician_id,
    payment_id,
    dispute_id,
    event_id,
    message,
    metadata,
    first_seen_at,
    last_seen_at,
    resolved_at
  )
  values (
    p_alert_type,
    coalesce(nullif(p_severity, ''), 'warning'),
    'open',
    dedupe,
    p_job_id,
    p_electrician_id,
    p_payment_id,
    p_dispute_id,
    p_event_id,
    p_message,
    coalesce(p_metadata, '{}'::jsonb),
    now(),
    now(),
    null
  )
  on conflict (dedupe_key) do update
  set severity = excluded.severity,
      status = 'open',
      message = excluded.message,
      metadata = public.operational_alerts.metadata || excluded.metadata,
      event_id = coalesce(excluded.event_id, public.operational_alerts.event_id),
      last_seen_at = now(),
      resolved_at = null
  returning * into alert_row;

  return alert_row;
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
      when j.status = 'matching' and coalesce(j.last_dispatch_at, j.updated_at, j.created_at) < now() - interval '5 minutes' then 'stuck_pairing'
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
      when j.status = 'matching' and coalesce(j.last_dispatch_at, j.updated_at, j.created_at) < now() - interval '5 minutes' then 'Pairing has exceeded the operational target.'
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
      or (j.status = 'matching' and coalesce(j.last_dispatch_at, j.updated_at, j.created_at) < now() - interval '5 minutes')
      or (j.status in ('assessment_payment_pending_verification', 'work_payment_pending_verification') and j.updated_at < now() - interval '30 minutes')
      or (j.status = 'electrician_completed' and coalesce(j.electrician_completed_at, j.updated_at) < now() - interval '24 hours')
    )
$$;

create or replace function public.refresh_operational_alerts()
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  item record;
  count_alerts integer := 0;
begin
  for item in select * from public.detect_stuck_jobs() loop
    perform public.upsert_operational_alert(
      item.stuck_type,
      item.severity,
      item.reason,
      item.job_id,
      null,
      null,
      null,
      null,
      jsonb_build_object('stuck_since', item.stuck_since)
    );
    count_alerts := count_alerts + 1;
  end loop;

  for item in
    select p.id as payment_id, p.job_id, p.created_at
    from public.job_payments p
    where p.status = 'submitted'
      and p.created_at < now() - interval '30 minutes'
  loop
    perform public.upsert_operational_alert(
      'pending_payment',
      case when item.created_at < now() - interval '2 hours' then 'critical' else 'warning' end,
      'Payment proof is waiting for admin verification.',
      item.job_id,
      null,
      item.payment_id,
      null,
      null,
      jsonb_build_object('submitted_at', item.created_at)
    );
    count_alerts := count_alerts + 1;
  end loop;

  for item in
    select id, created_at
    from public.disputes
    where status = 'open'
  loop
    perform public.upsert_operational_alert(
      'open_dispute',
      'critical',
      'Open dispute needs admin review.',
      null,
      null,
      null,
      item.id,
      null,
      jsonb_build_object('opened_at', item.created_at)
    );
    count_alerts := count_alerts + 1;
  end loop;

  update public.operational_alerts a
  set status = 'resolved',
      resolved_at = now()
  where status = 'open'
    and (
      (alert_type in ('stuck_pairing', 'expired_assignment', 'payment_delay', 'customer_confirmation_delay') and not exists (
        select 1 from public.detect_stuck_jobs() stuck
        where stuck.job_id = a.job_id
          and stuck.stuck_type = a.alert_type
      ))
      or (alert_type = 'pending_payment' and not exists (
        select 1 from public.job_payments p
        where p.id = a.payment_id
          and p.status = 'submitted'
      ))
      or (alert_type = 'open_dispute' and not exists (
        select 1 from public.disputes d
        where d.id = a.dispute_id
          and d.status = 'open'
      ))
    );

  return count_alerts;
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
  metadata_value jsonb := coalesce(p_metadata, '{}'::jsonb);
  idempotency text := nullif(btrim(coalesce(p_metadata->>'idempotency_key', '')), '');
  severity_value text := coalesce(nullif(btrim(coalesce(p_metadata->>'severity', '')), ''), 'info');
  visibility_value text := coalesce(nullif(btrim(coalesce(p_metadata->>'visibility', '')), ''), 'public');
  source_value text := coalesce(nullif(btrim(coalesce(p_metadata->>'source', '')), ''), 'app');
begin
  select status into job_status_value
  from public.jobs
  where id = p_job_id;

  if not found then
    raise exception 'Job not found';
  end if;

  if idempotency is not null then
    select id into event_id from public.job_events where idempotency_key = idempotency;
    if event_id is not null then
      return event_id;
    end if;
  end if;

  event_public_message := coalesce(
    nullif(btrim(p_public_message), ''),
    public.public_message_for_job_event(p_event_type, job_status_value, p_internal_note)
  );
  event_public_message := public.public_message_for_job_event(p_event_type, job_status_value, event_public_message);

  metadata_value := metadata_value - 'idempotency_key' - 'severity' - 'visibility' - 'source';

  insert into public.job_events (
    job_id,
    event_type,
    actor_role,
    actor_id,
    public_message,
    internal_note,
    metadata,
    idempotency_key,
    severity,
    visibility,
    source
  )
  values (
    p_job_id,
    p_event_type,
    coalesce(nullif(p_actor_role, ''), public.actor_role_for_profile(p_actor_id)),
    p_actor_id,
    event_public_message,
    nullif(btrim(p_internal_note), ''),
    metadata_value,
    idempotency,
    case when severity_value in ('info', 'warning', 'critical') then severity_value else 'info' end,
    case when visibility_value in ('public', 'internal') then visibility_value else 'public' end,
    source_value
  )
  returning id into event_id;

  return event_id;
exception
  when unique_violation then
    if idempotency is not null then
      select id into event_id from public.job_events where idempotency_key = idempotency;
      return event_id;
    end if;
    raise;
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
        'stuck_since', s.stuck_since
      ) order by s.stuck_since asc)
      from public.detect_stuck_jobs() s
      join public.jobs j on j.id = s.job_id
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
        'assignment_expires_at', j.assignment_expires_at
      ) order by j.assignment_expires_at asc)
      from public.jobs j
      where j.status = 'assigned'
        and j.assignment_expires_at is not null
        and j.assignment_expires_at <= now()
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
        'last_seen_at', a.last_seen_at
      ) order by case a.severity when 'critical' then 0 when 'warning' then 1 else 2 end, a.last_seen_at asc)
      from public.operational_alerts a
      where a.status = 'open'
    ), '[]'::jsonb)
  ) into payload;

  return payload;
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

  perform public.refresh_operational_alerts();

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
      (select count(*) from public.detect_stuck_jobs()) as stuck_jobs,
      (
        select count(*)
        from public.operational_alerts
        where status = 'open'
          and severity = 'critical'
      ) as critical_alerts
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
      'expired_assignments', coalesce(q.expired_assignments, 0),
      'critical_alerts', coalesce(q.critical_alerts, 0)
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

create or replace function public.request_guest_otp(
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
  expected_last4 text;
  provided_last4 text;
  raw_code text;
  challenge_id uuid;
  expires timestamptz;
begin
  if p_action_type not in ('cancel_job', 'payment_proof', 'dispute', 'customer_confirmed') then
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

  if job_row.created_at < now() - interval '30 days' then
    raise exception 'This guest action link has expired. Contact VoltFriq support to continue.';
  end if;

  select phone into guest_phone from public.guest_customers where id = job_row.guest_customer_id;
  expected_last4 := right(regexp_replace(coalesce(guest_phone, ''), '\D', '', 'g'), 4);
  provided_last4 := right(regexp_replace(coalesce(p_phone_confirmation, ''), '\D', '', 'g'), 4);

  if expected_last4 = '' or expected_last4 <> provided_last4 then
    raise exception 'Confirm the phone number used for this booking.';
  end if;

  if (
    select count(*)
    from public.guest_otps
    where job_id = p_job_id
      and action_type = p_action_type
      and created_at > now() - interval '10 minutes'
  ) >= 3 then
    raise exception 'Too many OTP requests. Please wait a few minutes before trying again.';
  end if;

  raw_code := lpad((floor(random() * 1000000))::integer::text, 6, '0');
  expires := now() + interval '10 minutes';

  insert into public.guest_otps (
    job_id,
    action_type,
    phone_last4,
    code_hash,
    request_fingerprint,
    delivery_status,
    expires_at,
    metadata
  )
  values (
    p_job_id,
    p_action_type,
    expected_last4,
    md5('voltfriq-otp:' || raw_code || ':' || p_job_id::text || ':' || p_action_type),
    nullif(btrim(coalesce(p_client_fingerprint, '')), ''),
    'pending',
    expires,
    jsonb_build_object('masked_phone', '***' || expected_last4)
  )
  returning id into challenge_id;

  return jsonb_strip_nulls(jsonb_build_object(
    'challenge_id', challenge_id,
    'expires_at', expires,
    'masked_phone', '***' || expected_last4,
    'delivery_status', 'pending',
    'otp_code', case when auth.role() = 'service_role' then raw_code else null end
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
  select * into job_row
  from public.jobs
  where id = p_job_id
    and customer_access_token = p_access_token
    and guest_customer_id is not null;

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

  return jsonb_build_object('verified', true, 'challenge_id', p_challenge_id);
end;
$$;

drop function if exists public.issue_guest_action_token(uuid,text,text,text);

create or replace function public.issue_guest_action_token(
  p_job_id uuid,
  p_access_token text,
  p_action_type text,
  p_phone_confirmation text,
  p_otp_challenge_id uuid default null,
  p_otp_code text default null
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  job_row public.jobs;
  guest_phone text;
  expected_last4 text;
  provided_last4 text;
  raw_token text;
  token_expires_at timestamptz;
begin
  if p_action_type not in ('cancel_job', 'payment_proof', 'dispute', 'customer_confirmed') then
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

  if job_row.created_at < now() - interval '30 days' then
    raise exception 'This guest action link has expired. Contact VoltFriq support to continue.';
  end if;

  if p_otp_challenge_id is not null or nullif(btrim(coalesce(p_otp_code, '')), '') is not null then
    perform public.verify_guest_otp(p_job_id, p_access_token, p_action_type, p_otp_challenge_id, p_otp_code);
    update public.guest_otps
    set consumed_at = now()
    where id = p_otp_challenge_id
      and job_id = p_job_id
      and action_type = p_action_type;
  else
    select phone into guest_phone
    from public.guest_customers
    where id = job_row.guest_customer_id;

    expected_last4 := right(regexp_replace(coalesce(guest_phone, ''), '\D', '', 'g'), 4);
    provided_last4 := right(regexp_replace(coalesce(p_phone_confirmation, ''), '\D', '', 'g'), 4);

    if expected_last4 = '' or expected_last4 <> provided_last4 then
      raise exception 'Confirm the phone number used for this booking.';
    end if;
  end if;

  raw_token := replace(gen_random_uuid()::text, '-', '') || replace(gen_random_uuid()::text, '-', '');
  token_expires_at := now() + interval '10 minutes';

  insert into public.guest_action_tokens (job_id, action_type, token_hash, expires_at)
  values (p_job_id, p_action_type, md5('voltfriq-action:' || raw_token), token_expires_at);

  return jsonb_build_object(
    'action_token', raw_token,
    'expires_at', token_expires_at
  );
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
  lock_acquired boolean;
begin
  lock_acquired := pg_try_advisory_xact_lock(hashtext(p_job_id::text));
  if not lock_acquired then
    select * into job_row from public.jobs where id = p_job_id;
    if found then
      perform public.upsert_operational_alert(
        'dispatch_conflict',
        'warning',
        'Dispatch already running for this job.',
        p_job_id,
        null,
        null,
        null,
        null,
        jsonb_build_object('manual_electrician_id', p_manual_electrician_id)
      );
      return job_row;
    end if;
    raise exception 'Job not found';
  end if;

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
    perform public.upsert_operational_alert(
      'dispatch_conflict',
      'critical',
      'Admin reassignment conflicted with an active assignment.',
      p_job_id,
      p_manual_electrician_id,
      null,
      null,
      null,
      jsonb_build_object('active_electrician_id', job_row.assigned_electrician_id, 'assignment_expires_at', job_row.assignment_expires_at)
    );
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
    perform public.upsert_operational_alert(
      'stuck_pairing',
      'critical',
      'No approved available VoltFriq accepted this job. Admin follow-up is needed.',
      p_job_id,
      null,
      null,
      null,
      null,
      jsonb_build_object('dispatch_attempts', job_row.dispatch_attempts)
    );
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
  perform public.refresh_operational_alerts();

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
      jsonb_build_object(
        'electrician_id', expired_job.assigned_electrician_id,
        'idempotency_key', 'assignment-expired:' || expired_job.id::text || ':' || coalesce(expired_job.assigned_electrician_id::text, 'none'),
        'severity', 'warning',
        'source', 'dispatch_queue'
      )
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
      and (
        coalesce(array_length(candidate_queue, 1), 0) > 0
        or coalesce(last_dispatch_at, updated_at, created_at) < now() - interval '5 minutes'
      )
    for update skip locked
  loop
    perform public.dispatch_job_internal(matching_job.id, null);
    processed_count := processed_count + 1;
  end loop;

  perform public.refresh_operational_alerts();
  return processed_count;
end;
$$;

create or replace function public.refresh_electrician_performance_snapshot(p_electrician_id uuid)
returns public.electrician_performance_snapshots
language plpgsql
security definer
set search_path = public
as $$
declare
  snapshot_row public.electrician_performance_snapshots;
begin
  if not (public.is_admin() or auth.role() = 'service_role') then
    raise exception 'Admin access required';
  end if;

  insert into public.electrician_performance_snapshots (
    electrician_id,
    response_rate,
    acceptance_rate,
    rejection_rate,
    average_accept_seconds,
    completed_jobs,
    average_rating,
    negative_rating_count,
    score,
    metadata
  )
  select
    e.id,
    coalesce(e.response_rate, 0),
    case when count(ev_assign.id) = 0 then 0 else round((count(ev_accept.id)::numeric / count(ev_assign.id)::numeric) * 100, 2) end,
    case when count(ev_assign.id) = 0 then 0 else round((count(ev_reject.id)::numeric / count(ev_assign.id)::numeric) * 100, 2) end,
    coalesce(round(avg(extract(epoch from (ev_accept.created_at - ev_assign.created_at)))::numeric, 2), 0),
    coalesce(e.completed_jobs, 0),
    coalesce(e.average_rating, 0),
    coalesce(e.negative_rating_count, 0),
    round((
      coalesce(e.response_rate, 0) * 0.35
      + coalesce(e.average_rating, 0) * 20 * 0.35
      + least(coalesce(e.completed_jobs, 0), 100) * 0.2
      - coalesce(e.negative_rating_count, 0) * 5
    )::numeric, 2),
    jsonb_build_object('level_badge', e.level_badge, 'watchlist', e.watchlist)
  from public.electricians e
  left join public.jobs j on j.assigned_electrician_id = e.id
  left join public.job_events ev_assign on ev_assign.job_id = j.id and ev_assign.event_type = 'ELECTRICIAN_ASSIGNED'
  left join public.job_events ev_accept on ev_accept.job_id = j.id and ev_accept.event_type = 'ASSIGNMENT_ACCEPTED'
  left join public.job_events ev_reject on ev_reject.job_id = j.id and ev_reject.event_type = 'ASSIGNMENT_REJECTED'
  where e.id = p_electrician_id
  group by e.id
  returning * into snapshot_row;

  if snapshot_row.score < 45 then
    perform public.upsert_operational_alert(
      'electrician_performance',
      'warning',
      'VoltFriq performance score needs review.',
      null,
      p_electrician_id,
      null,
      null,
      null,
      jsonb_build_object('score', snapshot_row.score)
    );
  end if;

  return snapshot_row;
end;
$$;

revoke all on table public.operational_alerts from public, anon, authenticated;
grant select on table public.operational_alerts to authenticated;
grant all on table public.operational_alerts to service_role;

revoke all on table public.guest_otps from public, anon, authenticated;
grant all on table public.guest_otps to service_role;

revoke all on table public.electrician_performance_snapshots from public, anon, authenticated;
grant select on table public.electrician_performance_snapshots to authenticated;
grant all on table public.electrician_performance_snapshots to service_role;

revoke all on function public.operational_alert_dedupe_key(text,uuid,uuid,uuid,uuid) from public, anon, authenticated;
grant execute on function public.operational_alert_dedupe_key(text,uuid,uuid,uuid,uuid) to service_role;

revoke all on function public.upsert_operational_alert(text,text,text,uuid,uuid,uuid,uuid,uuid,jsonb) from public, anon, authenticated;
grant execute on function public.upsert_operational_alert(text,text,text,uuid,uuid,uuid,uuid,uuid,jsonb) to service_role;

revoke all on function public.detect_stuck_jobs() from public, anon, authenticated;
grant execute on function public.detect_stuck_jobs() to service_role;

revoke all on function public.refresh_operational_alerts() from public, anon, authenticated;
grant execute on function public.refresh_operational_alerts() to service_role;

revoke all on function public.admin_operational_queues() from public, anon, authenticated;
grant execute on function public.admin_operational_queues() to authenticated, service_role;

revoke all on function public.request_guest_otp(uuid,text,text,text,text) from public, anon, authenticated, service_role;
grant execute on function public.request_guest_otp(uuid,text,text,text,text) to anon, authenticated, service_role;

revoke all on function public.verify_guest_otp(uuid,text,text,uuid,text) from public, anon, authenticated, service_role;
grant execute on function public.verify_guest_otp(uuid,text,text,uuid,text) to anon, authenticated, service_role;

revoke all on function public.issue_guest_action_token(uuid,text,text,text,uuid,text) from public, anon, authenticated, service_role;
grant execute on function public.issue_guest_action_token(uuid,text,text,text,uuid,text) to anon, authenticated, service_role;

revoke all on function public.refresh_electrician_performance_snapshot(uuid) from public, anon, authenticated;
grant execute on function public.refresh_electrician_performance_snapshot(uuid) to authenticated, service_role;

revoke all on function public.dispatch_job_internal(uuid,uuid) from public, anon, authenticated;
grant execute on function public.dispatch_job_internal(uuid,uuid) to service_role;

revoke all on function public.process_dispatch_queue() from public, anon, authenticated;
grant execute on function public.process_dispatch_queue() to service_role;

notify pgrst, 'reload schema';
