-- Operational resilience and platform intelligence:
-- - keep job_events canonical while jobs remains a reconciled snapshot
-- - bind assignment accept/reject actions to the latest assignment event token
-- - improve dispatch scoring with workload, quality, rejection, and cooldown signals
-- - surface snapshot drift and platform health metrics to admins
-- - extend VoltFriq quality scoring without changing customer-facing UX

alter table public.jobs
  add column if not exists current_assignment_event_id uuid references public.job_events(id) on delete set null,
  add column if not exists current_assignment_token text,
  add column if not exists snapshot_reconciled_at timestamptz;

create index if not exists jobs_current_assignment_event_idx
  on public.jobs(current_assignment_event_id)
  where current_assignment_event_id is not null;

create index if not exists jobs_current_assignment_token_idx
  on public.jobs(current_assignment_token)
  where current_assignment_token is not null;

alter table public.electricians
  add column if not exists completion_score numeric(5,2) not null default 100,
  add column if not exists dispute_score numeric(5,2) not null default 100,
  add column if not exists payout_reliability_score numeric(5,2) not null default 100,
  add column if not exists quality_tier text not null default 'Trusted',
  add column if not exists quality_penalty_until timestamptz,
  add column if not exists quality_penalty_reason text;

alter table public.electrician_performance_snapshots
  add column if not exists completion_score numeric(5,2) not null default 100,
  add column if not exists dispute_score numeric(5,2) not null default 100,
  add column if not exists payout_reliability_score numeric(5,2) not null default 100,
  add column if not exists quality_tier text not null default 'Trusted';

alter table public.operational_alerts drop constraint if exists operational_alerts_alert_type_check;
alter table public.operational_alerts
  add constraint operational_alerts_alert_type_check
  check (alert_type in (
    'pending_payment',
    'pending_electrician',
    'stuck_pairing',
    'expired_assignment',
    'open_dispute',
    'payment_delay',
    'customer_confirmation_delay',
    'dispatch_conflict',
    'state_conflict',
    'snapshot_drift',
    'failed_pairing',
    'upload_failure',
    'high_rejection_electrician',
    'electrician_performance'
  ));

create or replace function public.detect_snapshot_drift()
returns table (
  job_id uuid,
  ticket text,
  snapshot_status public.job_status,
  event_status public.job_status,
  latest_event_id uuid,
  latest_event_at timestamptz,
  snapshot_version integer,
  event_version integer
)
language sql
stable
security definer
set search_path = public
as $$
  select
    j.id,
    j.ticket,
    j.status,
    s.event_status,
    s.event_id,
    s.created_at,
    coalesce(j.state_version, 0),
    coalesce(s.state_version, 0)
  from public.jobs j
  join public.job_current_state_from_events s on s.job_id = j.id
  where j.status is distinct from s.event_status
    and j.status <> 'rated'
$$;

create or replace function public.reconcile_job_snapshot_from_events(
  p_job_id uuid,
  p_reason text default 'reconcile'
) returns public.jobs
language plpgsql
security definer
set search_path = public
as $$
declare
  job_row public.jobs;
  state_row record;
  reconciled_row public.jobs;
begin
  select * into job_row
  from public.jobs
  where id = p_job_id
  for update;

  if not found then
    raise exception 'Job not found';
  end if;

  select *
  into state_row
  from public.job_current_state_from_events
  where job_id = p_job_id;

  if not found then
    update public.jobs
    set snapshot_reconciled_at = now()
    where id = p_job_id
    returning * into reconciled_row;
    return reconciled_row;
  end if;

  if job_row.status is distinct from state_row.event_status then
    update public.jobs
    set status = state_row.event_status,
        state_version = greatest(coalesce(state_version, 0), coalesce(state_row.state_version, 0)),
        snapshot_reconciled_at = now()
    where id = p_job_id
    returning * into reconciled_row;

    perform public.upsert_operational_alert(
      'snapshot_drift',
      'warning',
      'Job snapshot was reconciled from canonical events.',
      p_job_id,
      null,
      null,
      null,
      state_row.event_id,
      jsonb_build_object(
        'snapshot_status', job_row.status,
        'event_status', state_row.event_status,
        'reason', coalesce(nullif(btrim(p_reason), ''), 'reconcile')
      )
    );

    return reconciled_row;
  end if;

  update public.jobs
  set snapshot_reconciled_at = now()
  where id = p_job_id
  returning * into reconciled_row;

  return reconciled_row;
end;
$$;

create or replace function public.reconcile_active_job_snapshots(p_limit integer default 100)
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  item record;
  reconciled_count integer := 0;
begin
  for item in
    select id
    from public.jobs
    where status not in ('rated', 'cancelled')
    order by coalesce(snapshot_reconciled_at, to_timestamp(0)) asc, updated_at asc
    limit greatest(coalesce(p_limit, 100), 1)
  loop
    perform public.reconcile_job_snapshot_from_events(item.id, 'active-snapshot-scan');
    reconciled_count := reconciled_count + 1;
  end loop;

  return reconciled_count;
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
  assignment_token text;
  assignment_event_id uuid;
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

  perform public.reconcile_job_snapshot_from_events(p_job_id, 'dispatch-preflight');

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
      jsonb_build_object(
        'active_electrician_id', job_row.assigned_electrician_id,
        'assignment_event_id', job_row.current_assignment_event_id,
        'assignment_expires_at', job_row.assignment_expires_at
      )
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
      with scored as (
        select
          m.electrician_id,
          (
            coalesce(m.distance_km, 999) * 3
            + case when coalesce(e.watchlist, false) then 35 else 0 end
            + case when e.quality_penalty_until is not null and e.quality_penalty_until > now() then 25 else 0 end
            + case when e.last_offered_at is not null and e.last_offered_at > now() - interval '10 minutes' then 18 else 0 end
            + coalesce(active_load.active_jobs, 0) * 12
            + coalesce(recent_rejections.rejection_count, 0) * 8
            + greatest(0, 100 - coalesce(e.acceptance_score, e.acceptance_rate, 100)) * 0.25
            + greatest(0, 100 - coalesce(e.response_score, e.response_rate, 100)) * 0.20
            + greatest(0, 100 - coalesce(e.completion_score, 100)) * 0.18
            + greatest(0, 100 - coalesce(e.dispute_score, 100)) * 0.20
            + greatest(0, 100 - coalesce(e.payout_confidence_score, e.payout_reliability_score, 100)) * 0.10
            - coalesce(m.average_rating, e.average_rating, 0) * 4
            - least(coalesce(m.completed_jobs, e.completed_jobs, 0), 100) * 0.08
            - coalesce(m.level_rank, public.electrician_level_rank(e.level_badge), 1) * 1.5
          )::numeric as dispatch_score
        from public.find_matching_electricians(job_row.service_area, job_row.issue_category, job_row.latitude, job_row.longitude, 20) m
        join public.electricians e on e.id = m.electrician_id
        left join lateral (
          select count(*)::numeric as active_jobs
          from public.jobs active
          where active.assigned_electrician_id = e.id
            and active.status in (
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
              'work_in_progress'
            )
        ) active_load on true
        left join lateral (
          select count(*)::numeric as rejection_count
          from public.job_events ev
          where ev.event_type = 'ASSIGNMENT_REJECTED'
            and ev.metadata ->> 'electrician_id' = e.id::text
            and ev.created_at > now() - interval '7 days'
        ) recent_rejections on true
        where m.electrician_id <> all(coalesce(job_row.attempted_electrician_ids, '{}'::uuid[]))
      )
      select array_agg(electrician_id order by dispatch_score asc, electrician_id)
      into candidate_list
      from scored;
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
        current_assignment_event_id = null,
        current_assignment_token = null,
        dispatch_attempts = dispatch_attempts + 1,
        last_dispatch_at = now(),
        assignment_expires_at = null,
        state_version = coalesce(state_version, 0) + 1
    where id = p_job_id
    returning * into job_row;

    select id into admin_profile from public.profiles where role = 'admin' order by created_at asc limit 1;

    perform public.log_job_event(
      p_job_id,
      'PAIRING_STARTED',
      'system',
      actor_profile_id,
      'VoltFriq support is helping route your request.',
      'No approved available VoltFriq was found. Admin follow-up is needed.',
      jsonb_build_object(
        'previous_status', 'matching',
        'next_status', 'matching',
        'state_version', job_row.state_version,
        'dispatch_attempts', job_row.dispatch_attempts,
        'severity', 'warning',
        'source', 'dispatch_job_internal',
        'idempotency_key', 'no-candidate:' || p_job_id::text || ':' || job_row.dispatch_attempts::text
      )
    );

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
      perform public.create_notification(admin_profile, p_job_id, 'job_stuck', 'Manual assignment needed', 'No approved available VoltFriq accepted this job. Admin follow-up is needed.', '{}'::jsonb);
    end if;
    return job_row;
  end if;

  assignment_token := replace(gen_random_uuid()::text, '-', '') || replace(gen_random_uuid()::text, '-', '');

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
      assignment_expires_at = now() + interval '5 minutes',
      current_assignment_event_id = null,
      current_assignment_token = assignment_token,
      state_version = coalesce(state_version, 0) + 1
  where id = p_job_id
    and status in ('requested', 'matching', 'assigned')
  returning * into job_row;

  if job_row.id is null then
    raise exception 'Job could not be assigned because its state changed';
  end if;

  assignment_event_id := public.log_job_event(
    p_job_id,
    'ELECTRICIAN_ASSIGNED',
    case when p_manual_electrician_id is not null then 'admin' else 'system' end,
    actor_profile_id,
    'Electrician assigned.',
    case
      when p_manual_electrician_id is not null then 'Admin manually assigned a VoltFriq to this job.'
      else 'Dispatch assigned a VoltFriq using operational scoring.'
    end,
    jsonb_build_object(
      'electrician_id', target_electrician,
      'assignment_token', assignment_token,
      'assignment_expires_at', job_row.assignment_expires_at,
      'previous_status', 'matching',
      'next_status', 'assigned',
      'state_version', job_row.state_version,
      'source', 'dispatch_job_internal',
      'idempotency_key', 'assignment:' || p_job_id::text || ':' || job_row.state_version::text || ':' || target_electrician::text
    )
  );

  update public.jobs
  set current_assignment_event_id = assignment_event_id
  where id = p_job_id
  returning * into job_row;

  update public.electricians
  set last_offered_at = now()
  where id = target_electrician;

  select e.profile_id into assigned_profile from public.electricians e where e.id = target_electrician;

  perform public.create_notification(customer_profile, p_job_id, 'electrician_assigned', 'VoltFriq assigned', 'A verified VoltFriq has been dispatched to your job.', jsonb_build_object('electrician_id', target_electrician));
  perform public.create_notification(assigned_profile, p_job_id, 'electrician_assigned', 'New booking request', 'A nearby customer needs help in your service area.', jsonb_build_object('job_id', p_job_id, 'assignment_event_id', assignment_event_id));
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
  assignment_event public.job_events;
  customer_profile uuid;
  next_status public.job_status;
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
      jsonb_build_object(
        'electrician_id', electrician_row.id,
        'assignment_event_id', job_row.current_assignment_event_id,
        'severity', 'warning',
        'source', 'electrician_accept_job',
        'idempotency_key', 'late-accept:' || p_job_id::text || ':' || electrician_row.id::text || ':' || coalesce(job_row.current_assignment_event_id::text, 'none')
      )
    );
    perform public.upsert_operational_alert(
      'expired_assignment',
      'warning',
      'Expired assignment acceptance was blocked.',
      p_job_id,
      electrician_row.id,
      null,
      null,
      job_row.current_assignment_event_id,
      jsonb_build_object('assignment_expires_at', job_row.assignment_expires_at)
    );
    raise exception 'This assignment has expired and can no longer be accepted.';
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
    order by created_at desc, id desc
    limit 1;
  end if;

  if assignment_event.id is null
     or assignment_event.metadata ->> 'electrician_id' is distinct from electrician_row.id::text
     or nullif(assignment_event.metadata ->> 'assignment_token', '') is distinct from nullif(job_row.current_assignment_token, '') then
    perform public.upsert_operational_alert(
      'state_conflict',
      'critical',
      'Stale assignment acceptance was blocked.',
      p_job_id,
      electrician_row.id,
      null,
      null,
      coalesce(assignment_event.id, job_row.current_assignment_event_id),
      jsonb_build_object(
        'current_assignment_event_id', job_row.current_assignment_event_id,
        'assignment_event_electrician_id', assignment_event.metadata ->> 'electrician_id'
      )
    );
    raise exception 'This assignment has changed. Refresh your jobs before accepting.';
  end if;

  next_status := case
    when job_row.requires_assessment then 'assessment_fee_pending'::public.job_status
    else 'accepted'::public.job_status
  end;

  job_row := public.transition_job_state(
    p_job_id,
    next_status,
    'electrician',
    auth.uid(),
    'Your VoltFriq has accepted the booking.',
    'VoltFriq accepted the booking.',
    jsonb_build_object(
      'electrician_id', electrician_row.id,
      'assignment_event_id', assignment_event.id,
      'assignment_token', job_row.current_assignment_token,
      'expected_status', 'assigned',
      'source', 'electrician_accept_job'
    ),
    'assigned',
    'assignment-accepted:' || p_job_id::text || ':' || electrician_row.id::text || ':' || assignment_event.id::text
  );

  update public.jobs
  set current_assignment_token = null,
      current_assignment_event_id = null
  where id = p_job_id
  returning * into job_row;

  select c.profile_id into customer_profile from public.customers c where c.id = job_row.customer_id;
  perform public.create_notification(customer_profile, p_job_id, 'electrician_accepted', 'VoltFriq accepted', 'Your assigned VoltFriq accepted the booking.', '{}'::jsonb);
  perform public.refresh_electrician_performance_snapshot(electrician_row.id);
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

  if assignment_event.id is null
     or assignment_event.metadata ->> 'electrician_id' is distinct from electrician_row.id::text
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
      'assignment_token', job_row.current_assignment_token,
      'previous_status', job_row.status,
      'next_status', 'matching',
      'state_version', coalesce(job_row.state_version, 0) + 1,
      'source', 'electrician_reject_job',
      'idempotency_key', 'assignment-rejected:' || p_job_id::text || ':' || electrician_row.id::text || ':' || assignment_event.id::text
    )
  );

  update public.jobs
  set status = 'matching',
      assigned_electrician_id = null,
      assignment_expires_at = null,
      current_assignment_event_id = null,
      current_assignment_token = null,
      state_version = coalesce(state_version, 0) + 1
  where id = p_job_id
    and status = 'assigned'
    and assigned_electrician_id = electrician_row.id
    and current_assignment_event_id = assignment_event.id
  returning * into job_row;

  if job_row.id is null then
    raise exception 'This assignment is no longer available.';
  end if;

  perform public.refresh_electrician_performance_snapshot(electrician_row.id);
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
  perform public.reconcile_active_job_snapshots(100);
  perform public.refresh_operational_alerts();

  for expired_job in
    select id, assigned_electrician_id, current_assignment_event_id, current_assignment_token
    from public.jobs
    where status = 'assigned'
      and assignment_expires_at is not null
      and assignment_expires_at <= now()
    for update skip locked
  loop
    update public.jobs
    set status = 'matching',
        assigned_electrician_id = null,
        assignment_expires_at = null,
        current_assignment_event_id = null,
        current_assignment_token = null,
        state_version = coalesce(state_version, 0) + 1
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
        'assignment_event_id', expired_job.current_assignment_event_id,
        'assignment_token', expired_job.current_assignment_token,
        'next_status', 'matching',
        'idempotency_key', 'assignment-expired:' || expired_job.id::text || ':' || coalesce(expired_job.current_assignment_event_id::text, coalesce(expired_job.assigned_electrician_id::text, 'none')),
        'severity', 'warning',
        'source', 'dispatch_queue'
      )
    );

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
  offer_count numeric := 0;
  accepted_count numeric := 0;
  rejection_count numeric := 0;
  completion_count numeric := 0;
  assigned_count numeric := 0;
  dispute_count numeric := 0;
  payment_total numeric := 0;
  rejected_payment_count numeric := 0;
  response_value numeric := 0;
  acceptance_value numeric := 0;
  rejection_value numeric := 0;
  completion_value numeric := 100;
  dispute_value numeric := 100;
  payout_confidence_value numeric := 100;
  quality_score numeric := 0;
  tier_value text := 'Trusted';
begin
  if not (public.is_admin() or auth.role() = 'service_role' or exists (
    select 1 from public.electricians e where e.id = p_electrician_id and e.profile_id = auth.uid()
  )) then
    raise exception 'Electrician performance access required';
  end if;

  select count(*)::numeric
  into offer_count
  from public.jobs j
  where p_electrician_id = any(coalesce(j.attempted_electrician_ids, '{}'::uuid[]))
    or j.assigned_electrician_id = p_electrician_id;

  select count(*)::numeric
  into assigned_count
  from public.jobs j
  where j.assigned_electrician_id = p_electrician_id;

  select count(*)::numeric
  into accepted_count
  from public.jobs j
  where j.assigned_electrician_id = p_electrician_id
    and (
      j.accepted_at is not null
      or j.status in (
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
        'rated'
      )
    );

  select count(*)::numeric
  into completion_count
  from public.jobs j
  where j.assigned_electrician_id = p_electrician_id
    and j.status in ('electrician_completed', 'customer_confirmed', 'payout_pending', 'payout_complete', 'rated');

  select count(*)::numeric
  into rejection_count
  from public.job_events e
  where e.event_type = 'ASSIGNMENT_REJECTED'
    and e.metadata ->> 'electrician_id' = p_electrician_id::text;

  select count(*)::numeric
  into dispute_count
  from public.disputes d
  join public.jobs j on j.id = d.job_id
  where j.assigned_electrician_id = p_electrician_id;

  select count(*)::numeric,
         count(*) filter (where p.status = 'rejected')::numeric
  into payment_total, rejected_payment_count
  from public.job_payments p
  join public.jobs j on j.id = p.job_id
  where j.assigned_electrician_id = p_electrician_id;

  response_value := case when offer_count = 0 then 100 else round(greatest(0, least(100, (accepted_count / offer_count) * 100))::numeric, 2) end;
  acceptance_value := response_value;
  rejection_value := case when offer_count = 0 then 0 else round(greatest(0, least(100, (rejection_count / offer_count) * 100))::numeric, 2) end;
  completion_value := case when accepted_count = 0 then 100 else round(greatest(0, least(100, (completion_count / accepted_count) * 100))::numeric, 2) end;
  dispute_value := case when assigned_count = 0 then 100 else round(greatest(0, least(100, 100 - ((dispute_count / greatest(assigned_count, 1)) * 100)))::numeric, 2) end;
  payout_confidence_value := case
    when payment_total = 0 then 100
    else round(greatest(0, least(100, 100 - ((rejected_payment_count / payment_total) * 100)))::numeric, 2)
  end;

  select round((
    response_value * 0.18
    + acceptance_value * 0.18
    + completion_value * 0.18
    + dispute_value * 0.16
    + payout_confidence_value * 0.10
    + coalesce(e.average_rating, 0) * 20 * 0.16
    + least(coalesce(e.completed_jobs, 0), 100) * 0.04
    - coalesce(e.negative_rating_count, 0) * 3
  )::numeric, 2)
  into quality_score
  from public.electricians e
  where e.id = p_electrician_id;

  quality_score := greatest(0, least(100, coalesce(quality_score, 0)));

  tier_value := case
    when quality_score >= 92 and completion_value >= 85 and dispute_value >= 90 then 'VoltFriq Elite'
    when quality_score >= 82 then 'VoltFriq Pro'
    when quality_score >= 68 then 'Trusted'
    when quality_score >= 50 then 'Watch'
    else 'Recovery'
  end;

  update public.electricians
  set response_rate = response_value,
      acceptance_rate = acceptance_value,
      response_score = response_value,
      acceptance_score = acceptance_value,
      completion_score = completion_value,
      dispute_score = dispute_value,
      payout_confidence_score = payout_confidence_value,
      payout_reliability_score = payout_confidence_value,
      quality_tier = tier_value,
      quality_penalty_until = case
        when (rejection_value >= 60 and offer_count >= 4) or dispute_value < 70 or quality_score < 45
          then greatest(coalesce(quality_penalty_until, now()), now() + interval '24 hours')
        when quality_penalty_until is not null and quality_penalty_until <= now() then null
        else quality_penalty_until
      end,
      quality_penalty_reason = case
        when rejection_value >= 60 and offer_count >= 4 then 'High recent rejection rate'
        when dispute_value < 70 then 'Dispute rate above target'
        when quality_score < 45 then 'Quality score below target'
        when quality_penalty_until is not null and quality_penalty_until <= now() then null
        else quality_penalty_reason
      end,
      level_badge = case
        when tier_value = 'VoltFriq Elite' then 'Elite Pro'
        when tier_value = 'VoltFriq Pro' then 'Top Rated'
        else public.calculate_electrician_level(
          completed_jobs,
          average_rating,
          total_ratings,
          response_value,
          watchlist
        )
      end
  where id = p_electrician_id;

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
    completion_score,
    dispute_score,
    payout_reliability_score,
    quality_tier,
    metadata
  )
  select
    e.id,
    response_value,
    acceptance_value,
    rejection_value,
    coalesce((
      select round(avg(extract(epoch from (accepted.created_at - assigned.created_at)))::numeric, 2)
      from public.job_events assigned
      join public.job_events accepted on accepted.job_id = assigned.job_id
      where assigned.event_type = 'ELECTRICIAN_ASSIGNED'
        and accepted.event_type = 'ASSIGNMENT_ACCEPTED'
        and assigned.metadata ->> 'electrician_id' = e.id::text
        and accepted.created_at >= assigned.created_at
    ), 0),
    coalesce(e.completed_jobs, 0),
    coalesce(e.average_rating, 0),
    coalesce(e.negative_rating_count, 0),
    quality_score,
    completion_value,
    dispute_value,
    payout_confidence_value,
    tier_value,
    jsonb_build_object(
      'level_badge', e.level_badge,
      'watchlist', e.watchlist,
      'offers', offer_count,
      'accepted', accepted_count,
      'completed', completion_count,
      'rejected', rejection_count,
      'disputes', dispute_count,
      'payout_confidence_score', payout_confidence_value,
      'quality_penalty_until', e.quality_penalty_until
    )
  from public.electricians e
  where e.id = p_electrician_id
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
      jsonb_build_object('score', snapshot_row.score, 'quality_tier', tier_value)
    );
  end if;

  if rejection_value >= 50 and offer_count >= 4 then
    perform public.upsert_operational_alert(
      'high_rejection_electrician',
      'warning',
      'VoltFriq rejection rate is above target.',
      null,
      p_electrician_id,
      null,
      null,
      null,
      jsonb_build_object('rejection_rate', rejection_value, 'offers', offer_count)
    );
  end if;

  return snapshot_row;
end;
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

  for item in select * from public.detect_snapshot_drift() loop
    perform public.upsert_operational_alert(
      'snapshot_drift',
      'warning',
      'Job snapshot differs from canonical events.',
      item.job_id,
      null,
      null,
      null,
      item.latest_event_id,
      jsonb_build_object(
        'ticket', item.ticket,
        'snapshot_status', item.snapshot_status,
        'event_status', item.event_status,
        'snapshot_version', item.snapshot_version,
        'event_version', item.event_version
      )
    );
    count_alerts := count_alerts + 1;
  end loop;

  for item in
    select id, ticket, dispatch_attempts, last_dispatch_at
    from public.jobs
    where status = 'matching'
      and dispatch_attempts >= 3
  loop
    perform public.upsert_operational_alert(
      'failed_pairing',
      'critical',
      'Dispatch has retried this job multiple times.',
      item.id,
      null,
      null,
      null,
      null,
      jsonb_build_object(
        'ticket', item.ticket,
        'dispatch_attempts', item.dispatch_attempts,
        'last_dispatch_at', item.last_dispatch_at
      )
    );
    count_alerts := count_alerts + 1;
  end loop;

  for item in
    select id, ticket, assigned_electrician_id, assignment_expires_at
    from public.jobs
    where status = 'assigned'
      and assignment_expires_at is not null
      and assignment_expires_at <= now()
  loop
    perform public.upsert_operational_alert(
      'expired_assignment',
      'warning',
      'An assignment expired before acceptance.',
      item.id,
      item.assigned_electrician_id,
      null,
      null,
      null,
      jsonb_build_object('ticket', item.ticket, 'assignment_expires_at', item.assignment_expires_at)
    );
    count_alerts := count_alerts + 1;
  end loop;

  for item in
    select e.id, e.acceptance_score, e.response_score, e.quality_tier, latest.rejection_rate
    from public.electricians e
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
  loop
    perform public.upsert_operational_alert(
      'high_rejection_electrician',
      'warning',
      'VoltFriq quality signals need review.',
      null,
      item.id,
      null,
      null,
      null,
      jsonb_build_object(
        'rejection_rate', item.rejection_rate,
        'acceptance_score', item.acceptance_score,
        'response_score', item.response_score,
        'quality_tier', item.quality_tier
      )
    );
    count_alerts := count_alerts + 1;
  end loop;

  for item in
    select id, job_id, failure_stage, created_at
    from public.upload_failures
    where created_at > now() - interval '24 hours'
  loop
    perform public.upsert_operational_alert(
      'upload_failure',
      'warning',
      'Recent upload failure needs review.',
      item.job_id,
      null,
      null,
      null,
      null,
      jsonb_build_object('failure_id', item.id, 'failure_stage', item.failure_stage)
    );
    count_alerts := count_alerts + 1;
  end loop;

  update public.operational_alerts a
  set status = 'resolved',
      resolved_at = coalesce(resolved_at, now())
  where status = 'open'
    and alert_type in ('stuck_pairing', 'expired_assignment', 'failed_pairing')
    and job_id is not null
    and exists (
      select 1
      from public.jobs j
      where j.id = a.job_id
        and (
          j.status in ('accepted', 'assessment_fee_pending', 'assessment_confirmed', 'en_route', 'on_site', 'work_in_progress', 'electrician_completed', 'customer_confirmed', 'payout_pending', 'payout_complete', 'rated', 'cancelled')
          or (a.alert_type = 'expired_assignment' and not (j.status = 'assigned' and j.assignment_expires_at <= now()))
        )
    );

  update public.operational_alerts a
  set status = 'resolved',
      resolved_at = coalesce(resolved_at, now())
  where status = 'open'
    and alert_type = 'snapshot_drift'
    and job_id is not null
    and not exists (
      select 1 from public.detect_snapshot_drift() drift where drift.job_id = a.job_id
    );

  return count_alerts;
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
      (select count(*) from public.detect_snapshot_drift()) as snapshot_drift_jobs,
      (
        select count(*)
        from public.jobs
        where status = 'matching'
          and dispatch_attempts >= 3
      ) as failed_pairing_jobs,
      (
        select count(*)
        from public.operational_alerts
        where status = 'open'
          and severity = 'critical'
      ) as critical_alerts,
      (
        select count(*)
        from public.upload_failures
        where created_at > now() - interval '24 hours'
      ) as upload_failures_24h,
      (
        select coalesce(sum(greatest(dispatch_attempts - 1, 0)), 0)
        from public.jobs
        where created_at > now() - interval '7 days'
      ) as dispatch_retries_7d,
      (
        select count(*)
        from public.disputes
        where created_at > now() - interval '30 days'
      ) as disputes_30d,
      (
        select count(*)
        from public.jobs
        where created_at > now() - interval '30 days'
      ) as jobs_30d
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
          when count(*) = 0 then 0
          else (
            select count(*)
            from public.job_events e
            where e.event_type = 'ASSIGNMENT_REJECTED'
          )::numeric / nullif(count(*) filter (where array_length(coalesce(j.attempted_electrician_ids, '{}'::uuid[]), 1) > 0), 0)::numeric * 100
        end
        from public.jobs j
        cross join lateral unnest(coalesce(j.attempted_electrician_ids, '{}'::uuid[])) as attempted(electrician_id)
      ) as rejection_rate,
      (
        select avg(extract(epoch from (v.verified_at - s.submitted_at)))
        from payment_submitted s
        join payment_verified v on v.job_id = s.job_id
        where v.verified_at >= s.submitted_at
      ) as payment_verification_delay_seconds,
      (
        select avg(coalesce(e.response_score, e.response_rate, 100))
        from public.electricians e
        where e.status = 'approved'
      ) as electrician_response_quality
  )
  select jsonb_build_object(
    'queues', jsonb_build_object(
      'pending_payments', coalesce(q.pending_payments, 0),
      'pending_electricians', coalesce(q.pending_electricians, 0),
      'stuck_pairing_jobs', coalesce(q.stuck_jobs, 0),
      'failed_pairing_jobs', coalesce(q.failed_pairing_jobs, 0),
      'open_disputes', coalesce(q.open_disputes, 0),
      'expired_assignments', coalesce(q.expired_assignments, 0),
      'snapshot_drift_jobs', coalesce(q.snapshot_drift_jobs, 0),
      'critical_alerts', coalesce(q.critical_alerts, 0)
    ),
    'metrics', jsonb_build_object(
      'average_time_to_assign_seconds', coalesce(round(m.avg_time_to_assign_seconds::numeric, 1), 0),
      'average_time_to_accept_seconds', coalesce(round(m.avg_time_to_accept_seconds::numeric, 1), 0),
      'rejection_rate', coalesce(round(m.rejection_rate::numeric, 1), 0),
      'payment_verification_delay_seconds', coalesce(round(m.payment_verification_delay_seconds::numeric, 1), 0),
      'stuck_jobs_count', coalesce(q.stuck_jobs, 0),
      'dispatch_retries_7d', coalesce(q.dispatch_retries_7d, 0),
      'upload_failures_24h', coalesce(q.upload_failures_24h, 0),
      'dispute_rate_30d', case when coalesce(q.jobs_30d, 0) = 0 then 0 else round((q.disputes_30d::numeric / q.jobs_30d::numeric) * 100, 1) end,
      'electrician_response_quality', coalesce(round(m.electrician_response_quality::numeric, 1), 100),
      'snapshot_drift_jobs', coalesce(q.snapshot_drift_jobs, 0),
      'system_health_score', greatest(0, least(100,
        100
        - coalesce(q.critical_alerts, 0) * 12
        - coalesce(q.stuck_jobs, 0) * 6
        - coalesce(q.expired_assignments, 0) * 4
        - coalesce(q.failed_pairing_jobs, 0) * 5
        - coalesce(q.upload_failures_24h, 0) * 2
        - coalesce(q.snapshot_drift_jobs, 0) * 8
      ))
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

create or replace function public.platform_health_snapshot()
returns jsonb
language sql
security definer
set search_path = public
as $$
  select public.admin_operational_summary();
$$;

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
  sensitive_action boolean;
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

  sensitive_action := p_action_type in ('cancel_job', 'payment_proof', 'dispute');

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
  token_expires_at := now() + case when sensitive_action then interval '5 minutes' else interval '10 minutes' end;

  insert into public.guest_action_tokens (job_id, action_type, token_hash, expires_at)
  values (p_job_id, p_action_type, md5('voltfriq-action:' || raw_token), token_expires_at);

  return jsonb_build_object(
    'action_token', raw_token,
    'expires_at', token_expires_at,
    'verification_method', case when p_otp_challenge_id is not null then 'otp' else 'phone_last4' end,
    'otp_ready', true
  );
end;
$$;

revoke all on function public.detect_snapshot_drift() from public, anon, authenticated;
grant execute on function public.detect_snapshot_drift() to service_role;

revoke all on function public.reconcile_job_snapshot_from_events(uuid,text) from public, anon, authenticated;
grant execute on function public.reconcile_job_snapshot_from_events(uuid,text) to service_role;

revoke all on function public.reconcile_active_job_snapshots(integer) from public, anon, authenticated;
grant execute on function public.reconcile_active_job_snapshots(integer) to service_role;

revoke all on function public.dispatch_job_internal(uuid,uuid) from public, anon, authenticated;
grant execute on function public.dispatch_job_internal(uuid,uuid) to service_role;

revoke all on function public.electrician_accept_job(uuid) from public, anon, authenticated, service_role;
grant execute on function public.electrician_accept_job(uuid) to authenticated, service_role;

revoke all on function public.electrician_reject_job(uuid) from public, anon, authenticated, service_role;
grant execute on function public.electrician_reject_job(uuid) to authenticated, service_role;

revoke all on function public.process_dispatch_queue() from public, anon, authenticated;
grant execute on function public.process_dispatch_queue() to service_role;

revoke all on function public.refresh_electrician_performance_snapshot(uuid) from public, anon, authenticated;
grant execute on function public.refresh_electrician_performance_snapshot(uuid) to authenticated, service_role;

revoke all on function public.refresh_operational_alerts() from public, anon, authenticated;
grant execute on function public.refresh_operational_alerts() to service_role;

revoke all on function public.admin_operational_summary() from public, anon, authenticated;
grant execute on function public.admin_operational_summary() to authenticated, service_role;

revoke all on function public.platform_health_snapshot() from public, anon, authenticated;
grant execute on function public.platform_health_snapshot() to authenticated, service_role;

revoke all on function public.issue_guest_action_token(uuid,text,text,text,uuid,text) from public, anon, authenticated, service_role;
grant execute on function public.issue_guest_action_token(uuid,text,text,text,uuid,text) to anon, authenticated, service_role;

notify pgrst, 'reload schema';
