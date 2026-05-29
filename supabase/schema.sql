-- Canonical schema snapshot for VoltFriq.
-- Rebuild with ./scripts/rebuild-schema.sh

--
-- PostgreSQL database dump
--

\restrict axraMLCcBVkKhyrZKMQWFDUZX45QRDe8xJNLhYQ7sA2hl8jJ5b2g6eNtduj9a0Z

-- Dumped from database version 17.6
-- Dumped by pg_dump version 18.3

SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET transaction_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;

--
-- Name: public; Type: SCHEMA; Schema: -; Owner: pg_database_owner
--

CREATE SCHEMA "public";


ALTER SCHEMA "public" OWNER TO "pg_database_owner";

--
-- Name: SCHEMA "public"; Type: COMMENT; Schema: -; Owner: pg_database_owner
--

COMMENT ON SCHEMA "public" IS 'standard public schema';


--
-- Name: storage; Type: SCHEMA; Schema: -; Owner: supabase_admin
--

CREATE SCHEMA "storage";


ALTER SCHEMA "storage" OWNER TO "supabase_admin";

--
-- Name: electrician_status; Type: TYPE; Schema: public; Owner: postgres
--

CREATE TYPE "public"."electrician_status" AS ENUM (
    'pending',
    'approved',
    'rejected',
    'suspended'
);


ALTER TYPE "public"."electrician_status" OWNER TO "postgres";

--
-- Name: job_status; Type: TYPE; Schema: public; Owner: postgres
--

CREATE TYPE "public"."job_status" AS ENUM (
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


ALTER TYPE "public"."job_status" OWNER TO "postgres";

--
-- Name: job_urgency; Type: TYPE; Schema: public; Owner: postgres
--

CREATE TYPE "public"."job_urgency" AS ENUM (
    'emergency',
    'today',
    'this_week'
);


ALTER TYPE "public"."job_urgency" OWNER TO "postgres";

--
-- Name: notification_event; Type: TYPE; Schema: public; Owner: postgres
--

CREATE TYPE "public"."notification_event" AS ENUM (
    'new_job_created',
    'electrician_assigned',
    'electrician_accepted',
    'payment_proof_submitted',
    'payment_verified',
    'payment_rejected',
    'quote_submitted',
    'work_completed',
    'payout_released',
    'payment_pending_verification',
    'dispute_raised',
    'payout_ready',
    'job_stuck',
    'reward_issued',
    'electrician_suspended',
    'appeal_submitted',
    'appeal_resolved',
    'review_submitted'
);


ALTER TYPE "public"."notification_event" OWNER TO "postgres";

--
-- Name: payment_status; Type: TYPE; Schema: public; Owner: postgres
--

CREATE TYPE "public"."payment_status" AS ENUM (
    'submitted',
    'verified',
    'rejected'
);


ALTER TYPE "public"."payment_status" OWNER TO "postgres";

--
-- Name: payment_type; Type: TYPE; Schema: public; Owner: postgres
--

CREATE TYPE "public"."payment_type" AS ENUM (
    'assessment_fee',
    'quote_payment',
    'material_payment',
    'payout'
);


ALTER TYPE "public"."payment_type" OWNER TO "postgres";

--
-- Name: user_role; Type: TYPE; Schema: public; Owner: postgres
--

CREATE TYPE "public"."user_role" AS ENUM (
    'customer',
    'electrician',
    'admin'
);


ALTER TYPE "public"."user_role" OWNER TO "postgres";

--
-- Name: buckettype; Type: TYPE; Schema: storage; Owner: supabase_storage_admin
--

CREATE TYPE "storage"."buckettype" AS ENUM (
    'STANDARD',
    'ANALYTICS',
    'VECTOR'
);


ALTER TYPE "storage"."buckettype" OWNER TO "supabase_storage_admin";

--
-- Name: actor_role_for_profile("uuid"); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."actor_role_for_profile"("p_profile_id" "uuid") RETURNS "text"
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  select coalesce(
    (select role::text from public.profiles where id = p_profile_id limit 1),
    case when p_profile_id is null then 'system' else 'unknown' end
  );
$$;


ALTER FUNCTION "public"."actor_role_for_profile"("p_profile_id" "uuid") OWNER TO "postgres";

--
-- Name: admin_assign_electrician_to_job("uuid", "uuid", boolean); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."admin_assign_electrician_to_job"("p_job_id" "uuid", "p_electrician_id" "uuid", "p_force" boolean DEFAULT true) RETURNS "public"."jobs"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  job_row public.jobs;
  target_electrician uuid;
  customer_profile uuid;
  assigned_profile uuid;
  actor_profile_id uuid;
  previous_status public.job_status;
  previous_electrician uuid;
  active_assignment boolean := false;
  lock_acquired boolean;
  assignment_token text;
  assignment_event_id uuid;
  internal_note text;
begin
  if not (public.is_admin() or auth.role() = 'service_role') then
    raise exception 'Admin access required';
  end if;

  if p_job_id is null or p_electrician_id is null then
    raise exception 'Job and electrician are required';
  end if;

  lock_acquired := pg_try_advisory_xact_lock(hashtext(p_job_id::text));
  if not lock_acquired then
    raise exception 'Dispatch is already updating this job. Refresh and try again.';
  end if;

  perform public.reconcile_job_snapshot_from_events(p_job_id, 'admin-manual-assignment');

  select * into job_row
  from public.jobs
  where id = p_job_id
  for update;

  if not found then
    raise exception 'Job not found';
  end if;

  previous_status := job_row.status;
  previous_electrician := job_row.assigned_electrician_id;

  if job_row.status = 'cancelled' then
    raise exception 'This client order was cancelled and cannot be assigned.';
  end if;

  if job_row.status in ('payout_complete', 'rated') then
    raise exception 'This client order is completed and cannot be reassigned.';
  end if;

  if job_row.status not in ('requested', 'matching', 'assigned') then
    raise exception 'Only unaccepted client orders can be assigned. Current status: %', job_row.status;
  end if;

  select id into target_electrician
  from public.electricians
  where id = p_electrician_id
    and status = 'approved';

  if target_electrician is null then
    raise exception 'Only approved VoltFriqs can be assigned to client orders.';
  end if;

  active_assignment := job_row.status = 'assigned'
    and job_row.assignment_expires_at is not null
    and job_row.assignment_expires_at > now();

  if active_assignment and job_row.assigned_electrician_id = target_electrician then
    return job_row;
  end if;

  if active_assignment and not coalesce(p_force, false) then
    raise exception 'This client order already has an active assignment. Use force deploy before the electrician accepts.';
  end if;

  select c.profile_id into customer_profile
  from public.customers c
  where c.id = job_row.customer_id;

  actor_profile_id := coalesce(auth.uid(), customer_profile);
  assignment_token := replace(gen_random_uuid()::text, '-', '') || replace(gen_random_uuid()::text, '-', '');
  internal_note := case
    when active_assignment and previous_electrician is not null and previous_electrician <> target_electrician
      then 'Admin force assigned a VoltFriq to this job before acceptance.'
    else 'Admin manually assigned a VoltFriq to this job.'
  end;

  update public.jobs
  set status = 'assigned',
      assigned_electrician_id = target_electrician,
      candidate_queue = '{}'::uuid[],
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
    raise exception 'Job could not be assigned because its state changed. Refresh and try again.';
  end if;

  assignment_event_id := public.log_job_event(
    p_job_id,
    'ELECTRICIAN_ASSIGNED',
    'admin',
    actor_profile_id,
    'Electrician assigned.',
    internal_note,
    jsonb_build_object(
      'electrician_id', target_electrician,
      'previous_electrician_id', previous_electrician,
      'assignment_token', assignment_token,
      'assignment_expires_at', job_row.assignment_expires_at,
      'previous_status', previous_status,
      'next_status', 'assigned',
      'state_version', job_row.state_version,
      'force', coalesce(p_force, false),
      'source', 'admin_assign_electrician_to_job',
      'idempotency_key', 'admin-assignment:' || p_job_id::text || ':' || job_row.state_version::text || ':' || target_electrician::text
    )
  );

  update public.jobs
  set current_assignment_event_id = assignment_event_id
  where id = p_job_id
  returning * into job_row;

  update public.electricians
  set last_offered_at = now()
  where id = target_electrician;

  select e.profile_id into assigned_profile
  from public.electricians e
  where e.id = target_electrician;

  perform public.create_notification(
    customer_profile,
    p_job_id,
    'electrician_assigned',
    'VoltFriq assigned',
    'A verified VoltFriq has been dispatched to your job.',
    jsonb_build_object('electrician_id', target_electrician)
  );

  perform public.create_notification(
    assigned_profile,
    p_job_id,
    'electrician_assigned',
    'New booking request',
    'A nearby customer needs help in your service area.',
    jsonb_build_object('job_id', p_job_id, 'assignment_event_id', assignment_event_id)
  );

  return job_row;
end;
$$;


ALTER FUNCTION "public"."admin_assign_electrician_to_job"("p_job_id" "uuid", "p_electrician_id" "uuid", "p_force" boolean) OWNER TO "postgres";

--
-- Name: admin_job_payload("uuid"); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."admin_job_payload"("p_job_id" "uuid" DEFAULT NULL::"uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  job_row public.jobs;
begin
  if not public.is_admin() then
    raise exception 'Admin access required';
  end if;

  if p_job_id is not null then
    select * into job_row
    from public.jobs
    where id = p_job_id;

    if not found then
      raise exception 'Job not found';
    end if;

    return public.job_payload_for_role(job_row, 'admin');
  end if;

  return coalesce((
    select jsonb_agg(public.job_payload_for_role(j, 'admin') order by j.created_at desc)
    from public.jobs j
  ), '[]'::jsonb);
end;
$$;


ALTER FUNCTION "public"."admin_job_payload"("p_job_id" "uuid") OWNER TO "postgres";

--
-- Name: admin_operational_queues(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."admin_operational_queues"() RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
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
    'predictive_alerts', coalesce((
      select jsonb_agg(jsonb_build_object(
        'alert_type', risk.alert_type,
        'severity', risk.severity,
        'reason', risk.reason,
        'job_id', risk.job_id,
        'electrician_id', risk.electrician_id,
        'payment_id', risk.payment_id,
        'metadata', risk.metadata,
        'action', case
          when risk.alert_type in ('predictive_pairing_risk', 'projection_replay_due') and risk.job_id is not null then 'review_dispatch'
          when risk.alert_type = 'predictive_payment_backlog' then 'review_payment'
          else 'review'
        end
      ) order by case risk.severity when 'critical' then 0 when 'warning' then 1 else 2 end)
      from public.detect_predictive_operational_risks() risk
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
    'event_replay_runs', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', r.id,
        'request_id', r.request_id,
        'replay_scope', r.replay_scope,
        'job_id', r.job_id,
        'status', r.status,
        'processed_count', r.processed_count,
        'stale_rejected_count', r.stale_rejected_count,
        'started_at', r.started_at,
        'finished_at', r.finished_at
      ) order by r.started_at desc)
      from public.event_replay_runs r
      where r.started_at > now() - interval '24 hours'
      limit 20
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
          when a.alert_type in ('stuck_pairing', 'failed_pairing', 'expired_assignment', 'predictive_pairing_risk') and a.job_id is not null then 'retry_dispatch'
          when a.alert_type in ('snapshot_drift', 'projection_replay_due') and a.job_id is not null then 'reconcile_state'
          when a.alert_type = 'predictive_payment_backlog' then 'review_payment'
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


ALTER FUNCTION "public"."admin_operational_queues"() OWNER TO "postgres";

--
-- Name: admin_operational_summary(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."admin_operational_summary"() RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
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
      (select count(*) from public.detect_predictive_operational_risks()) as predictive_alerts,
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
      ) as jobs_30d,
      (
        select count(*)
        from public.operational_automation_runs
        where status = 'failed'
          and started_at > now() - interval '24 hours'
      ) as automation_failures_24h,
      (
        select extract(epoch from (now() - max(finished_at)))
        from public.operational_automation_runs
        where status = 'completed'
      ) as automation_last_run_age_seconds,
      (
        select extract(epoch from (now() - max(finished_at)))
        from public.event_replay_runs
        where status = 'completed'
      ) as event_replay_last_run_age_seconds,
      (
        select count(*)
        from public.event_replay_runs
        where status = 'failed'
          and started_at > now() - interval '24 hours'
      ) as event_replay_failures_24h
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
  rejected_events as (
    select count(*)::numeric as rejected_count
    from public.job_events
    where event_type = 'ASSIGNMENT_REJECTED'
      and created_at > now() - interval '30 days'
  ),
  assignment_events as (
    select count(*)::numeric as assigned_count
    from public.job_events
    where event_type = 'ELECTRICIAN_ASSIGNED'
      and created_at > now() - interval '30 days'
  ),
  payment_delays as (
    select avg(extract(epoch from (verified_at - created_at))) as avg_delay
    from public.job_payments
    where status = 'verified'
      and verified_at is not null
      and created_at > now() - interval '30 days'
  ),
  response_quality as (
    select avg(coalesce(response_score, response_rate, 100)) as average_response_score
    from public.electricians
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
      'predictive_alerts', coalesce(q.predictive_alerts, 0),
      'critical_alerts', coalesce(q.critical_alerts, 0)
    ),
    'metrics', jsonb_build_object(
      'average_time_to_assign_seconds', coalesce(round(avg(extract(epoch from (a.assigned_at - c.created_at)))::numeric, 2), 0),
      'average_time_to_accept_seconds', coalesce(round(avg(extract(epoch from (ac.accepted_at - a.assigned_at)))::numeric, 2), 0),
      'rejection_rate', case when assign.assigned_count > 0 then round((rejects.rejected_count / assign.assigned_count) * 100, 2) else 0 end,
      'payment_verification_delay_seconds', coalesce(round(pay.avg_delay::numeric, 2), 0),
      'stuck_jobs_count', coalesce(q.stuck_jobs, 0),
      'dispatch_retries_7d', coalesce(q.dispatch_retries_7d, 0),
      'upload_failures_24h', coalesce(q.upload_failures_24h, 0),
      'dispute_rate_30d', case when q.jobs_30d > 0 then round((q.disputes_30d::numeric / q.jobs_30d::numeric) * 100, 2) else 0 end,
      'electrician_response_quality', coalesce(round(resp.average_response_score::numeric, 2), 100),
      'snapshot_drift_jobs', coalesce(q.snapshot_drift_jobs, 0),
      'predictive_alerts', coalesce(q.predictive_alerts, 0),
      'automation_failures_24h', coalesce(q.automation_failures_24h, 0),
      'automation_last_run_age_seconds', coalesce(round(q.automation_last_run_age_seconds::numeric, 2), 0),
      'event_replay_last_run_age_seconds', coalesce(round(q.event_replay_last_run_age_seconds::numeric, 2), 0),
      'event_replay_failures_24h', coalesce(q.event_replay_failures_24h, 0),
      'system_health_score', greatest(
        0,
        100
        - least(coalesce(q.critical_alerts, 0) * 10, 40)
        - least(coalesce(q.stuck_jobs, 0) * 6, 30)
        - least(coalesce(q.failed_pairing_jobs, 0) * 8, 24)
        - least(coalesce(q.predictive_alerts, 0) * 3, 18)
        - least(coalesce(q.upload_failures_24h, 0) * 2, 12)
        - least(coalesce(q.automation_failures_24h, 0) * 8, 24)
        - least(coalesce(q.event_replay_failures_24h, 0) * 8, 24)
      )
    )
  )
  into result
  from queue_counts q
  left join created_events c on true
  left join assigned_events a on a.job_id = c.job_id
  left join accepted_events ac on ac.job_id = c.job_id
  cross join rejected_events rejects
  cross join assignment_events assign
  cross join payment_delays pay
  cross join response_quality resp
  group by q.pending_payments, q.pending_electricians, q.open_disputes, q.expired_assignments, q.stuck_jobs,
    q.snapshot_drift_jobs, q.predictive_alerts, q.failed_pairing_jobs, q.critical_alerts, q.upload_failures_24h,
    q.dispatch_retries_7d, q.disputes_30d, q.jobs_30d, q.automation_failures_24h, q.automation_last_run_age_seconds,
    q.event_replay_last_run_age_seconds, q.event_replay_failures_24h,
    rejects.rejected_count, assign.assigned_count, pay.avg_delay, resp.average_response_score;

  return coalesce(result, jsonb_build_object('queues', '{}'::jsonb, 'metrics', '{}'::jsonb));
end;
$$;


ALTER FUNCTION "public"."admin_operational_summary"() OWNER TO "postgres";

SET default_tablespace = '';

SET default_table_access_method = "heap";

--
-- Name: jobs; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE "public"."jobs" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "ticket" "text" DEFAULT ('VFQ-'::"text" || "upper"("substr"("replace"(("gen_random_uuid"())::"text", '-'::"text", ''::"text"), 1, 8))) NOT NULL,
    "customer_id" "uuid",
    "assigned_electrician_id" "uuid",
    "service_area" "text" NOT NULL,
    "location_label" "text",
    "latitude" double precision,
    "longitude" double precision,
    "issue_category" "text" NOT NULL,
    "urgency" "public"."job_urgency" DEFAULT 'today'::"public"."job_urgency" NOT NULL,
    "customer_note" "text",
    "requires_assessment" boolean DEFAULT true NOT NULL,
    "material_handling" "text" DEFAULT 'voltfriq_supplied'::"text" NOT NULL,
    "status" "public"."job_status" DEFAULT 'requested'::"public"."job_status" NOT NULL,
    "current_quote_id" "uuid",
    "candidate_queue" "uuid"[] DEFAULT '{}'::"uuid"[] NOT NULL,
    "dispatch_attempts" integer DEFAULT 0 NOT NULL,
    "last_dispatch_at" timestamp with time zone,
    "assignment_expires_at" timestamp with time zone,
    "accepted_at" timestamp with time zone,
    "customer_confirmed_at" timestamp with time zone,
    "electrician_completed_at" timestamp with time zone,
    "payout_released_at" timestamp with time zone,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "attempted_electrician_ids" "uuid"[] DEFAULT '{}'::"uuid"[] NOT NULL,
    "guest_customer_id" "uuid",
    "customer_access_token" "text",
    "state_version" integer DEFAULT 0 NOT NULL,
    "guest_dispatch_verified_at" timestamp with time zone,
    "current_assignment_event_id" "uuid",
    "current_assignment_token" "text",
    "snapshot_reconciled_at" timestamp with time zone,
    "dispatch_priority_score" numeric(12,2) DEFAULT 0 NOT NULL,
    "dispatch_priority_reason" "text",
    "dispatch_priority_updated_at" timestamp with time zone
);


ALTER TABLE "public"."jobs" OWNER TO "postgres";

--
-- Name: admin_rebuild_job_projection("uuid"); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."admin_rebuild_job_projection"("p_job_id" "uuid") RETURNS "public"."jobs"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
begin
  if not public.is_admin() then
    raise exception 'Admin access required';
  end if;
  return public.rebuild_job_state_projection(p_job_id, 'admin-rebuild');
end;
$$;


ALTER FUNCTION "public"."admin_rebuild_job_projection"("p_job_id" "uuid") OWNER TO "postgres";

--
-- Name: admin_reconcile_job_state("uuid"); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."admin_reconcile_job_state"("p_job_id" "uuid") RETURNS "public"."jobs"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
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


ALTER FUNCTION "public"."admin_reconcile_job_state"("p_job_id" "uuid") OWNER TO "postgres";

--
-- Name: admin_replay_job_events("uuid"); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."admin_replay_job_events"("p_job_id" "uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  run_id uuid;
  replay_payload jsonb;
begin
  if not public.is_admin() then
    raise exception 'Admin access required';
  end if;

  insert into public.event_replay_runs (replay_scope, job_id, status, metadata)
  values ('admin-single', p_job_id, 'running', jsonb_build_object('admin_id', auth.uid()))
  returning id into run_id;

  replay_payload := public.replay_job_events_internal(p_job_id, run_id, 'admin-replay');

  update public.event_replay_runs
  set status = 'completed',
      finished_at = now(),
      processed_count = coalesce((replay_payload ->> 'processed_count')::integer, 0),
      conflict_count = coalesce((replay_payload ->> 'conflict_count')::integer, 0),
      stale_rejected_count = coalesce((replay_payload ->> 'stale_rejected_count')::integer, 0),
      metadata = metadata || replay_payload
  where id = run_id;

  return replay_payload || jsonb_build_object('run_id', run_id);
exception
  when others then
    if run_id is not null then
      update public.event_replay_runs
      set status = 'failed',
          finished_at = now(),
          error_message = sqlerrm,
          metadata = metadata || jsonb_build_object('sqlstate', sqlstate)
      where id = run_id;
    end if;
    raise;
end;
$$;


ALTER FUNCTION "public"."admin_replay_job_events"("p_job_id" "uuid") OWNER TO "postgres";

--
-- Name: operational_alerts; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE "public"."operational_alerts" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "alert_type" "text" NOT NULL,
    "severity" "text" DEFAULT 'warning'::"text" NOT NULL,
    "status" "text" DEFAULT 'open'::"text" NOT NULL,
    "dedupe_key" "text" NOT NULL,
    "job_id" "uuid",
    "electrician_id" "uuid",
    "payment_id" "uuid",
    "dispute_id" "uuid",
    "event_id" "uuid",
    "message" "text" NOT NULL,
    "metadata" "jsonb" DEFAULT '{}'::"jsonb" NOT NULL,
    "first_seen_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "last_seen_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "resolved_at" timestamp with time zone,
    "escalation_level" integer DEFAULT 0 NOT NULL,
    "escalated_at" timestamp with time zone,
    "next_review_at" timestamp with time zone,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "operational_alerts_alert_type_check" CHECK (("alert_type" = ANY (ARRAY['pending_payment'::"text", 'pending_electrician'::"text", 'stuck_pairing'::"text", 'expired_assignment'::"text", 'open_dispute'::"text", 'payment_delay'::"text", 'customer_confirmation_delay'::"text", 'dispatch_conflict'::"text", 'state_conflict'::"text", 'snapshot_drift'::"text", 'failed_pairing'::"text", 'upload_failure'::"text", 'high_rejection_electrician'::"text", 'electrician_performance'::"text", 'predictive_pairing_risk'::"text", 'predictive_payment_backlog'::"text", 'automation_lag'::"text", 'projection_replay_due'::"text", 'projection_replay_failure'::"text"]))),
    CONSTRAINT "operational_alerts_severity_check" CHECK (("severity" = ANY (ARRAY['info'::"text", 'warning'::"text", 'critical'::"text"]))),
    CONSTRAINT "operational_alerts_status_check" CHECK (("status" = ANY (ARRAY['open'::"text", 'resolved'::"text"])))
);


ALTER TABLE "public"."operational_alerts" OWNER TO "postgres";

--
-- Name: admin_resolve_operational_alert("uuid", "text"); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."admin_resolve_operational_alert"("p_alert_id" "uuid", "p_note" "text" DEFAULT NULL::"text") RETURNS "public"."operational_alerts"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
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


ALTER FUNCTION "public"."admin_resolve_operational_alert"("p_alert_id" "uuid", "p_note" "text") OWNER TO "postgres";

--
-- Name: admin_retry_dispatch_job("uuid"); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."admin_retry_dispatch_job"("p_job_id" "uuid") RETURNS "public"."jobs"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
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


ALTER FUNCTION "public"."admin_retry_dispatch_job"("p_job_id" "uuid") OWNER TO "postgres";

--
-- Name: electricians; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE "public"."electricians" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "profile_id" "uuid" NOT NULL,
    "status" "public"."electrician_status" DEFAULT 'pending'::"public"."electrician_status" NOT NULL,
    "years_experience" integer DEFAULT 0 NOT NULL,
    "service_areas" "text"[] DEFAULT '{}'::"text"[] NOT NULL,
    "location_label" "text",
    "latitude" double precision,
    "longitude" double precision,
    "bank_name" "text",
    "bank_account_number" "text",
    "bank_account_name" "text",
    "average_rating" numeric(3,2) DEFAULT 0 NOT NULL,
    "total_ratings" integer DEFAULT 0 NOT NULL,
    "completed_jobs" integer DEFAULT 0 NOT NULL,
    "availability_status" "text" DEFAULT 'available'::"text" NOT NULL,
    "last_offered_at" timestamp with time zone,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "response_rate" numeric(5,2) DEFAULT 0 NOT NULL,
    "level_badge" "text" DEFAULT 'Verified Pro'::"text" NOT NULL,
    "negative_rating_count" integer DEFAULT 0 NOT NULL,
    "last_suspended_negative_count" integer DEFAULT 0 NOT NULL,
    "watchlist" boolean DEFAULT false NOT NULL,
    "watchlist_reason" "text",
    "suspended_reason" "text",
    "suspended_at" timestamp with time zone,
    "onboarding_score" numeric(5,2) DEFAULT 0 NOT NULL,
    "onboarding_review_status" "text" DEFAULT 'pending'::"text" NOT NULL,
    "onboarding_feedback" "text",
    "onboarding_answers" "jsonb" DEFAULT '[]'::"jsonb" NOT NULL,
    "onboarding_completed" boolean DEFAULT false NOT NULL,
    "acceptance_rate" numeric(5,2) DEFAULT 0 NOT NULL,
    "response_score" numeric(5,2) DEFAULT 0 NOT NULL,
    "acceptance_score" numeric(5,2) DEFAULT 0 NOT NULL,
    "payout_confidence_score" numeric(5,2) DEFAULT 100 NOT NULL,
    "completion_score" numeric(5,2) DEFAULT 100 NOT NULL,
    "dispute_score" numeric(5,2) DEFAULT 100 NOT NULL,
    "payout_reliability_score" numeric(5,2) DEFAULT 100 NOT NULL,
    "quality_tier" "text" DEFAULT 'Trusted'::"text" NOT NULL,
    "quality_penalty_until" timestamp with time zone,
    "quality_penalty_reason" "text",
    "reliability_score" numeric(5,2) DEFAULT 100 NOT NULL,
    "tier" "text" DEFAULT 'Trusted'::"text" NOT NULL,
    "service_radius_km" integer DEFAULT 25 NOT NULL
);


ALTER TABLE "public"."electricians" OWNER TO "postgres";

--
-- Name: admin_set_electrician_status("uuid", "public"."electrician_status", "text"); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."admin_set_electrician_status"("p_electrician_id" "uuid", "p_status" "public"."electrician_status", "p_reason" "text" DEFAULT NULL::"text") RETURNS "public"."electricians"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
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


ALTER FUNCTION "public"."admin_set_electrician_status"("p_electrician_id" "uuid", "p_status" "public"."electrician_status", "p_reason" "text") OWNER TO "postgres";

--
-- Name: admin_set_electrician_watchlist("uuid", boolean, "text"); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."admin_set_electrician_watchlist"("p_electrician_id" "uuid", "p_watchlist" boolean, "p_reason" "text" DEFAULT NULL::"text") RETURNS "public"."electricians"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
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


ALTER FUNCTION "public"."admin_set_electrician_watchlist"("p_electrician_id" "uuid", "p_watchlist" boolean, "p_reason" "text") OWNER TO "postgres";

--
-- Name: append_job_timeline("uuid", "public"."job_status", "text", "uuid"); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."append_job_timeline"("p_job_id" "uuid", "p_status" "public"."job_status", "p_note" "text" DEFAULT NULL::"text", "p_actor_profile_id" "uuid" DEFAULT "auth"."uid"()) RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  event_type_value text;
  safe_note text;
begin
  event_type_value := public.job_event_type_for_status(p_status);
  safe_note := public.public_message_for_job_event(event_type_value, p_status, p_note);

  perform public.log_job_event(
    p_job_id,
    event_type_value,
    public.actor_role_for_profile(p_actor_profile_id),
    p_actor_profile_id,
    safe_note,
    p_note,
    jsonb_build_object('next_status', p_status::text, 'source', 'append_job_timeline')
  );
end;
$$;


ALTER FUNCTION "public"."append_job_timeline"("p_job_id" "uuid", "p_status" "public"."job_status", "p_note" "text", "p_actor_profile_id" "uuid") OWNER TO "postgres";

--
-- Name: apply_electrician_reliability_cooldowns(integer); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."apply_electrician_reliability_cooldowns"("p_limit" integer DEFAULT 200) RETURNS integer
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  item record;
  snapshot_row public.electrician_performance_snapshots;
  updated_count integer := 0;
begin
  if auth.role() <> 'service_role' then
    raise exception 'Service role required';
  end if;

  for item in
    select e.id
    from public.electricians e
    where e.status = 'approved'
    order by coalesce(e.last_offered_at, to_timestamp(0)) asc, e.updated_at asc nulls last
    limit greatest(coalesce(p_limit, 200), 1)
  loop
    snapshot_row := public.refresh_electrician_performance_snapshot(item.id);

    if snapshot_row.quality_tier in ('Watch', 'Recovery')
       or snapshot_row.rejection_rate >= 50
       or snapshot_row.completion_score < 70
       or snapshot_row.dispute_score < 75 then
      update public.electricians
      set quality_penalty_until = greatest(coalesce(quality_penalty_until, now()), now() + interval '12 hours'),
          quality_penalty_reason = case
            when snapshot_row.rejection_rate >= 50 then 'Automatic cooldown: rejection rate above target'
            when snapshot_row.completion_score < 70 then 'Automatic cooldown: completion reliability below target'
            when snapshot_row.dispute_score < 75 then 'Automatic cooldown: dispute score below target'
            else 'Automatic cooldown: reliability review'
          end
      where id = item.id;
      updated_count := updated_count + 1;
    elsif exists (
      select 1 from public.electricians e
      where e.id = item.id
        and e.quality_penalty_until is not null
        and e.quality_penalty_until <= now()
    ) then
      update public.electricians
      set quality_penalty_until = null,
          quality_penalty_reason = null
      where id = item.id;
      updated_count := updated_count + 1;
    end if;
  end loop;

  return updated_count;
end;
$$;


ALTER FUNCTION "public"."apply_electrician_reliability_cooldowns"("p_limit" integer) OWNER TO "postgres";

--
-- Name: apply_operational_escalations(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."apply_operational_escalations"() RETURNS integer
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  updated_count integer := 0;
begin
  if auth.role() <> 'service_role' then
    raise exception 'Service role required';
  end if;

  update public.operational_alerts
  set escalation_level = case
        when severity = 'critical' and last_seen_at < now() - interval '30 minutes' then greatest(escalation_level, 3)
        when severity = 'critical' then greatest(escalation_level, 2)
        when last_seen_at < now() - interval '15 minutes' then greatest(escalation_level, 1)
        else escalation_level
      end,
      escalated_at = case
        when escalation_level = 0
          and (
            severity = 'critical'
            or last_seen_at < now() - interval '15 minutes'
          ) then now()
        else escalated_at
      end,
      next_review_at = case
        when severity = 'critical' then now() + interval '5 minutes'
        when last_seen_at < now() - interval '15 minutes' then now() + interval '10 minutes'
        else now() + interval '30 minutes'
      end,
      metadata = metadata || jsonb_build_object('last_escalation_scan_at', now())
  where status = 'open';

  get diagnostics updated_count = row_count;
  return updated_count;
end;
$$;


ALTER FUNCTION "public"."apply_operational_escalations"() OWNER TO "postgres";

--
-- Name: attach_guest_job_photos("uuid", "text", "text"[]); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."attach_guest_job_photos"("p_job_id" "uuid", "p_access_token" "text", "p_photo_paths" "text"[]) RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
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


ALTER FUNCTION "public"."attach_guest_job_photos"("p_job_id" "uuid", "p_access_token" "text", "p_photo_paths" "text"[]) OWNER TO "postgres";

--
-- Name: audit_direct_job_status_write(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."audit_direct_job_status_write"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
begin
  if old.status is distinct from new.status and pg_trigger_depth() <= 1 then
    perform public.upsert_operational_alert(
      'state_conflict',
      'warning',
      'Legacy projection write observed outside canonical event projection.',
      new.id,
      new.assigned_electrician_id,
      null,
      null,
      null,
      jsonb_build_object(
        'previous_status', old.status,
        'next_status', new.status,
        'previous_state_version', old.state_version,
        'next_state_version', new.state_version,
        'source', 'jobs_status_update_trigger'
      )
    );
  end if;
  return new;
end;
$$;


ALTER FUNCTION "public"."audit_direct_job_status_write"() OWNER TO "postgres";

--
-- Name: calculate_electrician_level(integer, numeric, integer, numeric, boolean); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."calculate_electrician_level"("p_completed_jobs" integer, "p_average_rating" numeric, "p_total_ratings" integer, "p_response_rate" numeric, "p_watchlist" boolean) RETURNS "text"
    LANGUAGE "sql" STABLE
    AS $$
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


ALTER FUNCTION "public"."calculate_electrician_level"("p_completed_jobs" integer, "p_average_rating" numeric, "p_total_ratings" integer, "p_response_rate" numeric, "p_watchlist" boolean) OWNER TO "postgres";

--
-- Name: system_health_snapshots; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE "public"."system_health_snapshots" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "health_score" numeric(5,2) DEFAULT 100 NOT NULL,
    "queues" "jsonb" DEFAULT '{}'::"jsonb" NOT NULL,
    "metrics" "jsonb" DEFAULT '{}'::"jsonb" NOT NULL,
    "predictive_alert_count" integer DEFAULT 0 NOT NULL,
    "critical_alert_count" integer DEFAULT 0 NOT NULL,
    "recovery_action_count" integer DEFAULT 0 NOT NULL,
    "source" "text" DEFAULT 'automation'::"text" NOT NULL,
    "captured_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."system_health_snapshots" OWNER TO "postgres";

--
-- Name: capture_system_health_snapshot("text"); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."capture_system_health_snapshot"("p_source" "text" DEFAULT 'automation'::"text") RETURNS "public"."system_health_snapshots"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $_$
declare
  summary jsonb;
  metric record;
  snapshot_row public.system_health_snapshots;
  metric_value numeric;
begin
  if not (public.is_admin() or auth.role() = 'service_role') then
    raise exception 'Admin or service role required';
  end if;

  summary := public.admin_operational_summary();

  insert into public.system_health_snapshots (
    health_score,
    queues,
    metrics,
    predictive_alert_count,
    critical_alert_count,
    recovery_action_count,
    source
  )
  values (
    coalesce((summary #>> '{metrics,system_health_score}')::numeric, 100),
    coalesce(summary -> 'queues', '{}'::jsonb),
    coalesce(summary -> 'metrics', '{}'::jsonb),
    coalesce((summary #>> '{metrics,predictive_alerts}')::integer, 0),
    coalesce((summary #>> '{queues,critical_alerts}')::integer, 0),
    coalesce((summary #>> '{metrics,dispatch_retries_7d}')::integer, 0),
    coalesce(nullif(btrim(p_source), ''), 'automation')
  )
  returning * into snapshot_row;

  for metric in
    select key, value
    from jsonb_each_text(coalesce(summary -> 'metrics', '{}'::jsonb))
  loop
    if metric.value ~ '^-?[0-9]+(\\.[0-9]+)?$' then
      metric_value := metric.value::numeric;
      insert into public.operational_metrics (metric_name, metric_value, metric_unit, dimensions, source, captured_at)
      values (
        metric.key,
        metric_value,
        case
          when metric.key like '%seconds%' then 'seconds'
          when metric.key like '%rate%' or metric.key like '%score%' or metric.key like '%quality%' then 'percent'
          else 'count'
        end,
        jsonb_build_object('snapshot_id', snapshot_row.id),
        coalesce(nullif(btrim(p_source), ''), 'automation'),
        snapshot_row.captured_at
      );
    end if;
  end loop;

  return snapshot_row;
end;
$_$;


ALTER FUNCTION "public"."capture_system_health_snapshot"("p_source" "text") OWNER TO "postgres";

--
-- Name: claim_operation_request("text", "text", "text"); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."claim_operation_request"("p_request_id" "text", "p_operation_name" "text", "p_request_hash" "text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  clean_request_id text := public.sanitize_request_id(p_request_id);
  request_row public.operation_requests;
begin
  if auth.role() <> 'service_role' then
    raise exception 'Service role required';
  end if;

  if clean_request_id is null then
    clean_request_id := 'auto:' || replace(gen_random_uuid()::text, '-', '');
  end if;

  select * into request_row
  from public.operation_requests
  where request_id = clean_request_id
  for update;

  if found then
    if request_row.operation_name <> p_operation_name or request_row.request_hash <> p_request_hash then
      raise exception 'Request id % was already used for a different operation', clean_request_id;
    end if;

    return jsonb_build_object(
      'request_id', clean_request_id,
      'claimed', false,
      'status', request_row.status,
      'response_payload', request_row.response_payload
    );
  end if;

  insert into public.operation_requests (request_id, operation_name, request_hash)
  values (clean_request_id, p_operation_name, p_request_hash)
  returning * into request_row;

  return jsonb_build_object(
    'request_id', clean_request_id,
    'claimed', true,
    'status', request_row.status
  );
end;
$$;


ALTER FUNCTION "public"."claim_operation_request"("p_request_id" "text", "p_operation_name" "text", "p_request_hash" "text") OWNER TO "postgres";

--
-- Name: complete_operation_request("text", "text", "jsonb", "text"); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."complete_operation_request"("p_request_id" "text", "p_status" "text", "p_response_payload" "jsonb" DEFAULT NULL::"jsonb", "p_error_message" "text" DEFAULT NULL::"text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  clean_request_id text := public.sanitize_request_id(p_request_id);
  request_row public.operation_requests;
begin
  if auth.role() <> 'service_role' then
    raise exception 'Service role required';
  end if;

  if p_status not in ('completed', 'failed') then
    raise exception 'Unsupported operation request status';
  end if;

  update public.operation_requests
  set status = p_status,
      response_payload = p_response_payload,
      error_message = p_error_message,
      updated_at = now(),
      completed_at = case when p_status = 'completed' then now() else completed_at end
  where request_id = clean_request_id
  returning * into request_row;

  if not found then
    return jsonb_build_object(
      'request_id', clean_request_id,
      'status', p_status,
      'missing', true,
      'response_payload', p_response_payload,
      'error_message', p_error_message
    );
  end if;

  return jsonb_build_object(
    'request_id', request_row.request_id,
    'status', request_row.status,
    'response_payload', request_row.response_payload
  );
end;
$$;


ALTER FUNCTION "public"."complete_operation_request"("p_request_id" "text", "p_status" "text", "p_response_payload" "jsonb", "p_error_message" "text") OWNER TO "postgres";

--
-- Name: consume_guest_action_token("uuid", "text", "text"); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."consume_guest_action_token"("p_job_id" "uuid", "p_action_type" "text", "p_action_token" "text") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  affected_count integer;
begin
  if nullif(btrim(coalesce(p_action_token, '')), '') is null then
    raise exception 'Confirm this action before continuing.';
  end if;

  update public.guest_action_tokens
  set consumed_at = now()
  where job_id = p_job_id
    and action_type = p_action_type
    and token_hash = md5('voltfriq-action:' || p_action_token)
    and consumed_at is null
    and expires_at > now();

  get diagnostics affected_count = row_count;
  if affected_count <> 1 then
    raise exception 'Confirm this action before continuing.';
  end if;
end;
$$;


ALTER FUNCTION "public"."consume_guest_action_token"("p_job_id" "uuid", "p_action_type" "text", "p_action_token" "text") OWNER TO "postgres";

--
-- Name: create_customer_job("text", "text", double precision, double precision, "text", "public"."job_urgency", "text", boolean, "text", "text"[]); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."create_customer_job"("p_service_area" "text", "p_location_label" "text", "p_latitude" double precision, "p_longitude" double precision, "p_issue_category" "text", "p_urgency" "public"."job_urgency", "p_customer_note" "text", "p_requires_assessment" boolean, "p_material_handling" "text", "p_photo_paths" "text"[] DEFAULT '{}'::"text"[]) RETURNS "public"."jobs"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
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


ALTER FUNCTION "public"."create_customer_job"("p_service_area" "text", "p_location_label" "text", "p_latitude" double precision, "p_longitude" double precision, "p_issue_category" "text", "p_urgency" "public"."job_urgency", "p_customer_note" "text", "p_requires_assessment" boolean, "p_material_handling" "text", "p_photo_paths" "text"[]) OWNER TO "postgres";

--
-- Name: disputes; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE "public"."disputes" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "job_id" "uuid" NOT NULL,
    "customer_id" "uuid",
    "electrician_id" "uuid",
    "issue_type" "text" NOT NULL,
    "details" "text",
    "status" "text" DEFAULT 'open'::"text" NOT NULL,
    "resolution_action" "text",
    "resolution_note" "text",
    "resolved_by" "uuid",
    "resolved_at" timestamp with time zone,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "guest_customer_id" "uuid"
);


ALTER TABLE "public"."disputes" OWNER TO "postgres";

--
-- Name: create_dispute("uuid", "text", "text"); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."create_dispute"("p_job_id" "uuid", "p_issue_type" "text", "p_details" "text" DEFAULT NULL::"text") RETURNS "public"."disputes"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
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
    and customer_id = customer_row.id
  for update;

  if not found then
    raise exception 'Job not found';
  end if;

  insert into public.disputes (job_id, customer_id, electrician_id, issue_type, details)
  values (p_job_id, customer_row.id, job_row.assigned_electrician_id, p_issue_type, p_details)
  returning * into dispute_row;

  perform public.log_job_event(
    p_job_id,
    'DISPUTE_OPENED',
    'customer',
    auth.uid(),
    'VoltFriq support is reviewing your issue.',
    'Customer reported an issue: ' || coalesce(p_issue_type, 'general dispute') || '.',
    jsonb_build_object('dispute_id', dispute_row.id, 'issue_type', p_issue_type)
  );
  perform public.append_job_timeline(p_job_id, job_row.status, 'Customer reported an issue: ' || coalesce(p_issue_type, 'general dispute') || '.', auth.uid());
  select id into admin_profile from public.profiles where role = 'admin' order by created_at asc limit 1;
  if admin_profile is not null then
    perform public.create_notification(admin_profile, p_job_id, 'dispute_raised', 'Dispute raised', 'A customer reported an issue and admin review is needed.', jsonb_build_object('dispute_id', dispute_row.id, 'issue_type', p_issue_type));
  end if;

  return dispute_row;
end;
$$;


ALTER FUNCTION "public"."create_dispute"("p_job_id" "uuid", "p_issue_type" "text", "p_details" "text") OWNER TO "postgres";

--
-- Name: create_guest_customer_job("text", "text", "text", double precision, double precision, "text", "public"."job_urgency", "text", boolean, "text", "text"[], "text"); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."create_guest_customer_job"("p_phone" "text", "p_service_area" "text", "p_location_label" "text", "p_latitude" double precision, "p_longitude" double precision, "p_issue_category" "text", "p_urgency" "public"."job_urgency", "p_customer_note" "text", "p_requires_assessment" boolean, "p_material_handling" "text", "p_photo_paths" "text"[] DEFAULT '{}'::"text"[], "p_client_fingerprint" "text" DEFAULT NULL::"text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
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


ALTER FUNCTION "public"."create_guest_customer_job"("p_phone" "text", "p_service_area" "text", "p_location_label" "text", "p_latitude" double precision, "p_longitude" double precision, "p_issue_category" "text", "p_urgency" "public"."job_urgency", "p_customer_note" "text", "p_requires_assessment" boolean, "p_material_handling" "text", "p_photo_paths" "text"[], "p_client_fingerprint" "text") OWNER TO "postgres";

--
-- Name: create_guest_dispute("uuid", "text", "text", "text", "text", "text"); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."create_guest_dispute"("p_job_id" "uuid", "p_access_token" "text", "p_issue_type" "text", "p_details" "text" DEFAULT NULL::"text", "p_phone_confirmation" "text" DEFAULT NULL::"text", "p_action_token" "text" DEFAULT NULL::"text") RETURNS "public"."disputes"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  job_row public.jobs;
  dispute_row public.disputes;
  admin_profile uuid;
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

  perform public.consume_guest_action_token(p_job_id, 'dispute', p_action_token);

  insert into public.disputes (job_id, customer_id, guest_customer_id, electrician_id, issue_type, details)
  values (p_job_id, null, job_row.guest_customer_id, job_row.assigned_electrician_id, p_issue_type, p_details)
  returning * into dispute_row;

  perform public.log_job_event(
    p_job_id,
    'DISPUTE_OPENED',
    'guest',
    null,
    'VoltFriq support is reviewing your issue.',
    'Guest customer reported an issue: ' || coalesce(p_issue_type, 'general dispute') || '.',
    jsonb_build_object('dispute_id', dispute_row.id, 'issue_type', p_issue_type)
  );

  select id into admin_profile from public.profiles where role = 'admin' order by created_at asc limit 1;
  if admin_profile is not null then
    perform public.create_notification(admin_profile, p_job_id, 'dispute_raised', 'Guest dispute raised', 'A guest customer reported an issue and admin review is needed.', jsonb_build_object('dispute_id', dispute_row.id, 'issue_type', p_issue_type));
  end if;

  return dispute_row;
end;
$$;


ALTER FUNCTION "public"."create_guest_dispute"("p_job_id" "uuid", "p_access_token" "text", "p_issue_type" "text", "p_details" "text", "p_phone_confirmation" "text", "p_action_token" "text") OWNER TO "postgres";

--
-- Name: create_guest_otp_delivery("uuid", "text", "text", "text", "text"); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."create_guest_otp_delivery"("p_job_id" "uuid", "p_access_token" "text", "p_action_type" "text", "p_phone_confirmation" "text", "p_client_fingerprint" "text" DEFAULT NULL::"text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
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


ALTER FUNCTION "public"."create_guest_otp_delivery"("p_job_id" "uuid", "p_access_token" "text", "p_action_type" "text", "p_phone_confirmation" "text", "p_client_fingerprint" "text") OWNER TO "postgres";

--
-- Name: create_notification("uuid", "uuid", "public"."notification_event", "text", "text", "jsonb"); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."create_notification"("p_profile_id" "uuid", "p_job_id" "uuid", "p_event" "public"."notification_event", "p_title" "text", "p_body" "text", "p_metadata" "jsonb" DEFAULT '{}'::"jsonb") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
begin
  if p_profile_id is null then
    return;
  end if;

  insert into public.notifications (profile_id, job_id, event, title, body, metadata)
  values (p_profile_id, p_job_id, p_event, p_title, p_body, coalesce(p_metadata, '{}'::jsonb));
end;
$$;


ALTER FUNCTION "public"."create_notification"("p_profile_id" "uuid", "p_job_id" "uuid", "p_event" "public"."notification_event", "p_title" "text", "p_body" "text", "p_metadata" "jsonb") OWNER TO "postgres";

--
-- Name: current_customer_id(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."current_customer_id"() RETURNS "uuid"
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  select id from public.customers where profile_id = auth.uid() limit 1;
$$;


ALTER FUNCTION "public"."current_customer_id"() OWNER TO "postgres";

--
-- Name: current_electrician_id(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."current_electrician_id"() RETURNS "uuid"
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  select id from public.electricians where profile_id = auth.uid() limit 1;
$$;


ALTER FUNCTION "public"."current_electrician_id"() OWNER TO "postgres";

--
-- Name: customer_job_payload("uuid"); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."customer_job_payload"("p_job_id" "uuid" DEFAULT NULL::"uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  customer_row public.customers;
  job_row public.jobs;
begin
  select * into customer_row
  from public.customers
  where profile_id = auth.uid();

  if not found then
    raise exception 'Customer profile not found';
  end if;

  if p_job_id is not null then
    select * into job_row
    from public.jobs
    where id = p_job_id
      and customer_id = customer_row.id;

    if not found then
      raise exception 'Job not found';
    end if;

    return public.job_payload_for_role(job_row, 'customer');
  end if;

  return coalesce((
    select jsonb_agg(public.job_payload_for_role(j, 'customer') order by j.created_at desc)
    from public.jobs j
    where j.customer_id = customer_row.id
  ), '[]'::jsonb);
end;
$$;


ALTER FUNCTION "public"."customer_job_payload"("p_job_id" "uuid") OWNER TO "postgres";

--
-- Name: detect_predictive_operational_risks(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."detect_predictive_operational_risks"() RETURNS TABLE("alert_type" "text", "severity" "text", "reason" "text", "job_id" "uuid", "electrician_id" "uuid", "payment_id" "uuid", "metadata" "jsonb")
    LANGUAGE "sql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  select
    'predictive_pairing_risk'::text,
    case
      when coalesce(j.dispatch_attempts, 0) >= 2 or coalesce(j.last_dispatch_at, j.updated_at, j.created_at) < now() - interval '4 minutes' then 'critical'
      else 'warning'
    end,
    'Pairing is likely to breach target soon.',
    j.id,
    null::uuid,
    null::uuid,
    jsonb_build_object(
      'ticket', j.ticket,
      'status', j.status,
      'dispatch_attempts', coalesce(j.dispatch_attempts, 0),
      'age_seconds', extract(epoch from (now() - coalesce(j.last_dispatch_at, j.updated_at, j.created_at))),
      'prediction_window', 'pairing_5_min_target'
    )
  from public.jobs j
  where j.status in ('requested', 'matching')
    and coalesce(j.last_dispatch_at, j.updated_at, j.created_at) < now() - interval '3 minutes'
    and not exists (
      select 1 from public.detect_stuck_jobs() stuck
      where stuck.job_id = j.id
    )

  union all

  select
    'predictive_payment_backlog'::text,
    case when p.created_at < now() - interval '25 minutes' then 'critical' else 'warning' end,
    'Payment proof is approaching verification target.',
    p.job_id,
    null::uuid,
    p.id,
    jsonb_build_object(
      'ticket', j.ticket,
      'payment_type', p.payment_type,
      'age_seconds', extract(epoch from (now() - p.created_at)),
      'prediction_window', 'payment_30_min_target'
    )
  from public.job_payments p
  join public.jobs j on j.id = p.job_id
  where p.status = 'submitted'
    and p.created_at < now() - interval '20 minutes'

  union all

  select
    'automation_lag'::text,
    case
      when latest.completed_at is null or latest.completed_at < now() - interval '20 minutes' then 'critical'
      else 'warning'
    end,
    'Operational automation heartbeat is behind target.',
    null::uuid,
    null::uuid,
    null::uuid,
    jsonb_build_object(
      'last_completed_at', latest.completed_at,
      'age_seconds', case when latest.completed_at is null then null else extract(epoch from (now() - latest.completed_at)) end,
      'prediction_window', 'heartbeat_10_min_target'
    )
  from (
    select max(finished_at) as completed_at
    from public.operational_automation_runs
    where status = 'completed'
  ) latest
  where (
      latest.completed_at is null
      and exists (
        select 1
        from public.jobs j
        where j.status not in ('rated', 'cancelled')
        limit 1
      )
    )
     or latest.completed_at < now() - interval '10 minutes'

  union all

  select
    'projection_replay_due'::text,
    'warning'::text,
    'Job projection has not been replayed recently.',
    j.id,
    null::uuid,
    null::uuid,
    jsonb_build_object(
      'ticket', j.ticket,
      'status', j.status,
      'snapshot_reconciled_at', j.snapshot_reconciled_at,
      'state_version', j.state_version
    )
  from public.jobs j
  where j.status not in ('rated', 'cancelled')
    and exists (select 1 from public.job_events e where e.job_id = j.id and e.projected_status is not null)
    and coalesce(j.snapshot_reconciled_at, to_timestamp(0)) < now() - interval '30 minutes'
$$;


ALTER FUNCTION "public"."detect_predictive_operational_risks"() OWNER TO "postgres";

--
-- Name: detect_snapshot_drift(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."detect_snapshot_drift"() RETURNS TABLE("job_id" "uuid", "ticket" "text", "snapshot_status" "public"."job_status", "event_status" "public"."job_status", "latest_event_id" "uuid", "latest_event_at" timestamp with time zone, "snapshot_version" integer, "event_version" integer)
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  select
    j.id,
    j.ticket,
    j.status,
    p.projected_status,
    p.event_id,
    coalesce(e.created_at, p.projected_at),
    coalesce(j.state_version, 0),
    coalesce(p.state_version, 0)
  from public.jobs j
  join public.job_state_projections p on p.job_id = j.id
  left join public.job_events e on e.id = p.event_id
  where (
      j.status is distinct from p.projected_status
      or coalesce(j.state_version, 0) < coalesce(p.state_version, 0)
    )
    and j.status <> 'rated'
$$;


ALTER FUNCTION "public"."detect_snapshot_drift"() OWNER TO "postgres";

--
-- Name: detect_stuck_jobs(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."detect_stuck_jobs"() RETURNS TABLE("job_id" "uuid", "stuck_type" "text", "severity" "text", "reason" "text", "stuck_since" timestamp with time zone)
    LANGUAGE "sql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
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


ALTER FUNCTION "public"."detect_stuck_jobs"() OWNER TO "postgres";

--
-- Name: dispatch_job("uuid", "uuid"); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."dispatch_job"("p_job_id" "uuid", "p_manual_electrician_id" "uuid" DEFAULT NULL::"uuid") RETURNS "public"."jobs"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
begin
  if not (public.is_admin() or auth.role() = 'service_role') then
    raise exception 'Admin or service role required';
  end if;

  return public.dispatch_job_internal(p_job_id, p_manual_electrician_id);
end;
$$;


ALTER FUNCTION "public"."dispatch_job"("p_job_id" "uuid", "p_manual_electrician_id" "uuid") OWNER TO "postgres";

--
-- Name: dispatch_job_internal("uuid", "uuid"); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."dispatch_job_internal"("p_job_id" "uuid", "p_manual_electrician_id" "uuid" DEFAULT NULL::"uuid") RETURNS "public"."jobs"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
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


ALTER FUNCTION "public"."dispatch_job_internal"("p_job_id" "uuid", "p_manual_electrician_id" "uuid") OWNER TO "postgres";

--
-- Name: electrician_accept_job("uuid"); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."electrician_accept_job"("p_job_id" "uuid") RETURNS "public"."jobs"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
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


ALTER FUNCTION "public"."electrician_accept_job"("p_job_id" "uuid") OWNER TO "postgres";

--
-- Name: electrician_job_payload("uuid"); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."electrician_job_payload"("p_job_id" "uuid" DEFAULT NULL::"uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  electrician_row public.electricians;
  job_row public.jobs;
begin
  select * into electrician_row
  from public.electricians
  where profile_id = auth.uid();

  if not found then
    raise exception 'Electrician profile not found';
  end if;

  if p_job_id is not null then
    select * into job_row
    from public.jobs
    where id = p_job_id
      and assigned_electrician_id = electrician_row.id;

    if not found then
      raise exception 'Job not found';
    end if;

    return public.job_payload_for_role(job_row, 'electrician');
  end if;

  return coalesce((
    select jsonb_agg(public.job_payload_for_role(j, 'electrician') order by j.created_at desc)
    from public.jobs j
    where j.assigned_electrician_id = electrician_row.id
  ), '[]'::jsonb);
end;
$$;


ALTER FUNCTION "public"."electrician_job_payload"("p_job_id" "uuid") OWNER TO "postgres";

--
-- Name: electrician_level_rank("text"); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."electrician_level_rank"("p_level" "text") RETURNS integer
    LANGUAGE "sql" STABLE
    AS $$
  select case p_level
    when 'Elite Pro' then 5
    when 'Top Rated' then 4
    when 'Trusted Pro' then 3
    when 'Rising Pro' then 2
    else 1
  end;
$$;


ALTER FUNCTION "public"."electrician_level_rank"("p_level" "text") OWNER TO "postgres";

--
-- Name: electrician_reject_job("uuid"); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."electrician_reject_job"("p_job_id" "uuid") RETURNS "public"."jobs"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
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


ALTER FUNCTION "public"."electrician_reject_job"("p_job_id" "uuid") OWNER TO "postgres";

--
-- Name: enforce_job_status_event(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."enforce_job_status_event"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
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


ALTER FUNCTION "public"."enforce_job_status_event"() OWNER TO "postgres";

--
-- Name: profiles; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE "public"."profiles" (
    "id" "uuid" NOT NULL,
    "role" "public"."user_role" DEFAULT 'customer'::"public"."user_role" NOT NULL,
    "full_name" "text" DEFAULT ''::"text" NOT NULL,
    "phone" "text",
    "avatar_url" "text",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "referral_code" "text",
    "email" "text"
);


ALTER TABLE "public"."profiles" OWNER TO "postgres";

--
-- Name: ensure_app_account_for_current_user(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."ensure_app_account_for_current_user"() RETURNS "public"."profiles"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
begin
  if auth.uid() is null then
    raise exception 'No authenticated user';
  end if;

  return public.sync_app_account_for_auth_user(auth.uid());
end;
$$;


ALTER FUNCTION "public"."ensure_app_account_for_current_user"() OWNER TO "postgres";

--
-- Name: ensure_profile_for_current_user(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."ensure_profile_for_current_user"() RETURNS "public"."profiles"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
begin
  return public.ensure_app_account_for_current_user();
end;
$$;


ALTER FUNCTION "public"."ensure_profile_for_current_user"() OWNER TO "postgres";

--
-- Name: wallets; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE "public"."wallets" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "profile_id" "uuid" NOT NULL,
    "balance" numeric(12,2) DEFAULT 0 NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."wallets" OWNER TO "postgres";

--
-- Name: ensure_wallet_for_profile("uuid"); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."ensure_wallet_for_profile"("p_profile_id" "uuid") RETURNS "public"."wallets"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
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


ALTER FUNCTION "public"."ensure_wallet_for_profile"("p_profile_id" "uuid") OWNER TO "postgres";

--
-- Name: find_matching_electricians("text", "text", double precision, double precision, integer); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."find_matching_electricians"("p_service_area" "text", "p_issue_category" "text", "p_latitude" double precision DEFAULT NULL::double precision, "p_longitude" double precision DEFAULT NULL::double precision, "p_limit" integer DEFAULT 5) RETURNS TABLE("electrician_id" "uuid", "profile_id" "uuid", "full_name" "text", "phone" "text", "avatar_url" "text", "service_areas" "text"[], "years_experience" integer, "average_rating" numeric, "completed_jobs" integer, "availability_status" "text", "distance_km" numeric, "average_response_seconds" numeric, "last_assigned_at" timestamp with time zone, "level_badge" "text", "watchlist" boolean, "negative_rating_count" integer, "level_rank" integer)
    LANGUAGE "sql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  with latest_settings as (
    select
      coalesce((ranking_weights ->> 'max_distance_km')::numeric, 25) as max_distance_km,
      coalesce((trust_settings ->> 'watchlist_rank_penalty_km')::numeric, 8) as watchlist_rank_penalty_km
    from public.admin_settings
    order by updated_at desc
    limit 1
  ),
  settings as (
    select * from latest_settings
    union all
    select 25::numeric, 8::numeric
    where not exists (select 1 from latest_settings)
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
        select 1
        from public.electrician_skills s
        where s.electrician_id = e.id
          and lower(trim(s.category)) = lower(trim(p_issue_category))
      )
      and (
        p_service_area is null
        or exists (
          select 1
          from unnest(e.service_areas) as area
          where lower(regexp_replace(trim(area), '\s+', ' ', 'g')) = lower(regexp_replace(trim(p_service_area), '\s+', ' ', 'g'))
             or lower(regexp_replace(trim(p_service_area), '\s+', ' ', 'g')) like '%' || lower(regexp_replace(trim(area), '\s+', ' ', 'g')) || '%'
             or lower(regexp_replace(trim(area), '\s+', ' ', 'g')) like '%' || lower(regexp_replace(trim(p_service_area), '\s+', ' ', 'g')) || '%'
        )
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
          ) <= coalesce(nullif(e.service_radius_km, 0), settings.max_distance_km)
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
    round(distance_km::numeric, 2) as distance_km,
    average_response_seconds,
    last_assigned_at,
    level_badge,
    watchlist,
    negative_rating_count,
    level_rank
  from ranked
  order by
    distance_km asc,
    watchlist asc,
    negative_rating_count asc,
    level_rank desc,
    average_rating desc,
    completed_jobs desc
  limit p_limit;
$$;


ALTER FUNCTION "public"."find_matching_electricians"("p_service_area" "text", "p_issue_category" "text", "p_latitude" double precision, "p_longitude" double precision, "p_limit" integer) OWNER TO "postgres";

--
-- Name: generate_referral_code(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."generate_referral_code"() RETURNS "text"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
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


ALTER FUNCTION "public"."generate_referral_code"() OWNER TO "postgres";

--
-- Name: get_admin_job_events("uuid"); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."get_admin_job_events"("p_job_id" "uuid" DEFAULT NULL::"uuid") RETURNS TABLE("id" "uuid", "job_id" "uuid", "event_type" "text", "actor_role" "text", "actor_id" "uuid", "public_message" "text", "internal_note" "text", "metadata" "jsonb", "created_at" timestamp with time zone)
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
begin
  if not (public.is_admin() or auth.role() = 'service_role') then
    raise exception 'Admin access required';
  end if;

  return query
  select e.id, e.job_id, e.event_type, e.actor_role, e.actor_id, e.public_message, e.internal_note, e.metadata, e.created_at
  from public.job_events e
  where p_job_id is null or e.job_id = p_job_id
  order by e.created_at asc, e.id asc;
end;
$$;


ALTER FUNCTION "public"."get_admin_job_events"("p_job_id" "uuid") OWNER TO "postgres";

--
-- Name: get_guest_job("uuid", "text"); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."get_guest_job"("p_job_id" "uuid", "p_access_token" "text") RETURNS "jsonb"
    LANGUAGE "sql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  select public.guest_job_payload(p_job_id, p_access_token);
$$;


ALTER FUNCTION "public"."get_guest_job"("p_job_id" "uuid", "p_access_token" "text") OWNER TO "postgres";

--
-- Name: get_public_job_events("uuid", "text"); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."get_public_job_events"("p_job_id" "uuid", "p_access_token" "text" DEFAULT NULL::"text") RETURNS TABLE("id" "uuid", "job_id" "uuid", "event_type" "text", "public_message" "text", "created_at" timestamp with time zone)
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  can_read boolean;
begin
  select exists (
    select 1
    from public.jobs j
    where j.id = p_job_id
      and (
        public.is_admin()
        or j.customer_id = public.current_customer_id()
        or j.assigned_electrician_id = public.current_electrician_id()
        or (
          p_access_token is not null
          and j.customer_access_token = p_access_token
          and j.guest_customer_id is not null
        )
      )
  ) into can_read;

  if not can_read then
    raise exception 'Job not found';
  end if;

  return query
  select e.id, e.job_id, e.event_type, e.public_message, e.created_at
  from public.job_events e
  where e.job_id = p_job_id
    and nullif(btrim(e.public_message), '') is not null
  order by e.created_at asc, e.id asc;
end;
$$;


ALTER FUNCTION "public"."get_public_job_events"("p_job_id" "uuid", "p_access_token" "text") OWNER TO "postgres";

--
-- Name: guest_dispatch_otp_required(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."guest_dispatch_otp_required"() RETURNS boolean
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
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


ALTER FUNCTION "public"."guest_dispatch_otp_required"() OWNER TO "postgres";

--
-- Name: guest_job_payload("uuid", "text"); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."guest_job_payload"("p_job_id" "uuid", "p_access_token" "text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  payload jsonb;
begin
  select jsonb_strip_nulls(jsonb_build_object(
    'id', j.id,
    'ticket', j.ticket,
    'status', j.status,
    'issue_category', j.issue_category,
    'urgency', j.urgency,
    'location_label', j.location_label,
    'created_at', j.created_at,
    'assigned_electrician', case when e.id is null then null else jsonb_build_object(
      'display_name', coalesce(nullif(p.full_name, ''), 'VoltFriq'),
      'avatar_url', p.avatar_url,
      'rating', e.average_rating
    ) end,
    'progress_timeline', coalesce((
      select jsonb_agg(jsonb_build_object(
        'event_type', event.event_type,
        'note', event.public_message,
        'created_at', event.created_at
      ) order by event.created_at, event.id)
      from public.job_events event
      where event.job_id = j.id
        and nullif(btrim(event.public_message), '') is not null
    ), '[]'::jsonb),
    'quote_summary', (
      select jsonb_build_object(
        'total', q.grand_total,
        'created_at', q.created_at
      )
      from public.job_quotes q
      where q.job_id = j.id
      order by q.created_at desc
      limit 1
    ),
    'payment_status', (
      select payment.status
      from public.job_payments payment
      where payment.job_id = j.id
      order by payment.created_at desc
      limit 1
    )
  ))
  into payload
  from public.jobs j
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


ALTER FUNCTION "public"."guest_job_payload"("p_job_id" "uuid", "p_access_token" "text") OWNER TO "postgres";

--
-- Name: guest_public_timeline_note("public"."job_status"); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."guest_public_timeline_note"("p_status" "public"."job_status") RETURNS "text"
    LANGUAGE "sql" STABLE
    SET "search_path" TO 'public'
    AS $$
  select case p_status::text
    when 'requested' then 'Booking confirmed.'
    when 'matching' then 'Pairing you with a VoltFriq.'
    when 'assigned' then 'A verified VoltFriq has been assigned.'
    when 'accepted' then 'Your VoltFriq has accepted the booking.'
    when 'assessment_fee_pending' then 'Assessment payment is ready.'
    when 'assessment_payment_pending_verification' then 'Payment proof received for review.'
    when 'assessment_confirmed' then 'Assessment payment confirmed.'
    when 'en_route' then 'Your VoltFriq is on the way.'
    when 'on_site' then 'Your VoltFriq is on site.'
    when 'quoted' then 'Your quote is ready.'
    when 'quote_accepted' then 'Quote accepted.'
    when 'work_payment_pending_verification' then 'Work payment proof received for review.'
    when 'payment_confirmed' then 'Payment confirmed.'
    when 'work_in_progress' then 'Work is in progress.'
    when 'electrician_completed' then 'Work marked complete.'
    when 'customer_confirmed' then 'Completion confirmed.'
    when 'payout_pending' then 'Final processing is underway.'
    when 'payout_complete' then 'Job complete.'
    when 'rated' then 'Job complete.'
    when 'cancelled' then 'Booking cancelled.'
    else 'Status updated.'
  end;
$$;


ALTER FUNCTION "public"."guest_public_timeline_note"("p_status" "public"."job_status") OWNER TO "postgres";

--
-- Name: handle_job_status_notifications(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."handle_job_status_notifications"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
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


ALTER FUNCTION "public"."handle_job_status_notifications"() OWNER TO "postgres";

--
-- Name: handle_new_user(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."handle_new_user"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
begin
  perform public.sync_app_account_for_auth_user(new.id);
  return new;
end;
$$;


ALTER FUNCTION "public"."handle_new_user"() OWNER TO "postgres";

--
-- Name: handle_profile_rewards_setup(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."handle_profile_rewards_setup"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
begin
  if new.referral_code is null then
    new.referral_code := public.generate_referral_code();
  end if;
  return new;
end;
$$;


ALTER FUNCTION "public"."handle_profile_rewards_setup"() OWNER TO "postgres";

--
-- Name: handle_profile_wallet_setup(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."handle_profile_wallet_setup"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
begin
  perform public.ensure_wallet_for_profile(new.id);
  return new;
end;
$$;


ALTER FUNCTION "public"."handle_profile_wallet_setup"() OWNER TO "postgres";

--
-- Name: handle_wallets_touch_updated_at(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."handle_wallets_touch_updated_at"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
begin
  new.updated_at = now();
  return new;
end;
$$;


ALTER FUNCTION "public"."handle_wallets_touch_updated_at"() OWNER TO "postgres";

--
-- Name: is_admin(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."is_admin"() RETURNS boolean
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  select exists (
    select 1
    from public.profiles
    where id = auth.uid() and role = 'admin'
  );
$$;


ALTER FUNCTION "public"."is_admin"() OWNER TO "postgres";

--
-- Name: is_valid_job_transition("public"."job_status", "public"."job_status", "text", boolean, "jsonb"); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."is_valid_job_transition"("p_current_status" "public"."job_status", "p_next_status" "public"."job_status", "p_actor_role" "text", "p_is_admin" boolean DEFAULT false, "p_metadata" "jsonb" DEFAULT '{}'::"jsonb") RETURNS boolean
    LANGUAGE "plpgsql" STABLE
    SET "search_path" TO 'public'
    AS $$
declare
  actor_role_value text := lower(coalesce(p_actor_role, 'system'));
  admin_override boolean := lower(coalesce(p_metadata ->> 'admin_override', 'false')) in ('true', '1', 'yes');
  source_value text := coalesce(nullif(btrim(coalesce(p_metadata ->> 'source', '')), ''), 'app');
begin
  if p_current_status is null or p_next_status is null then
    return false;
  end if;

  if p_current_status = p_next_status then
    return true;
  end if;

  if p_current_status in ('payout_complete', 'rated', 'cancelled') then
    return false;
  end if;

  if p_is_admin and admin_override then
    return p_next_status not in ('requested', 'matching', 'assigned')
      or p_current_status in ('requested', 'matching', 'assigned');
  end if;

  if actor_role_value in ('customer', 'guest') then
    return (
        p_current_status = 'requested'
        and p_next_status = 'matching'
        and source_value in ('create_customer_job', 'create_guest_customer_job')
      )
      or (p_current_status = 'quoted' and p_next_status = 'quote_accepted')
      or (p_current_status = 'electrician_completed' and p_next_status = 'customer_confirmed')
      or (
        p_next_status = 'cancelled'
        and p_current_status in ('requested', 'matching', 'assigned', 'accepted', 'assessment_fee_pending', 'quoted')
      );
  end if;

  if actor_role_value = 'electrician' then
    return (p_current_status = 'assigned' and p_next_status in ('accepted', 'assessment_fee_pending'))
      or (p_current_status = 'assessment_confirmed' and p_next_status = 'en_route')
      or (p_current_status = 'en_route' and p_next_status = 'on_site')
      or (p_current_status = 'payment_confirmed' and p_next_status = 'work_in_progress')
      or (p_current_status = 'work_in_progress' and p_next_status = 'electrician_completed');
  end if;

  if actor_role_value in ('admin', 'system') then
    return (p_current_status = 'requested' and p_next_status in ('matching', 'assigned', 'cancelled'))
      or (p_current_status = 'matching' and p_next_status in ('assigned', 'cancelled'))
      or (p_current_status = 'assigned' and p_next_status in ('matching', 'accepted', 'assessment_fee_pending', 'cancelled'))
      or (p_current_status = 'accepted' and p_next_status in ('assessment_fee_pending', 'quoted', 'cancelled'))
      or (p_current_status = 'assessment_fee_pending' and p_next_status in ('assessment_payment_pending_verification', 'cancelled'))
      or (p_current_status = 'assessment_payment_pending_verification' and p_next_status in ('assessment_confirmed', 'assessment_fee_pending', 'cancelled'))
      or (p_current_status = 'assessment_confirmed' and p_next_status in ('en_route', 'on_site', 'quoted', 'cancelled'))
      or (p_current_status = 'en_route' and p_next_status in ('on_site', 'cancelled'))
      or (p_current_status = 'on_site' and p_next_status in ('quoted', 'cancelled'))
      or (p_current_status = 'quoted' and p_next_status in ('quote_accepted', 'cancelled'))
      or (p_current_status = 'quote_accepted' and p_next_status in ('work_payment_pending_verification', 'cancelled'))
      or (p_current_status = 'work_payment_pending_verification' and p_next_status in ('payment_confirmed', 'quote_accepted', 'cancelled'))
      or (p_current_status = 'payment_confirmed' and p_next_status in ('work_in_progress', 'cancelled'))
      or (p_current_status = 'work_in_progress' and p_next_status in ('electrician_completed', 'cancelled'))
      or (p_current_status = 'electrician_completed' and p_next_status in ('customer_confirmed', 'cancelled'))
      or (p_current_status = 'customer_confirmed' and p_next_status in ('payout_pending', 'payout_complete'))
      or (p_current_status = 'payout_pending' and p_next_status = 'payout_complete')
      or (p_current_status = 'payout_complete' and p_next_status = 'rated');
  end if;

  return false;
end;
$$;


ALTER FUNCTION "public"."is_valid_job_transition"("p_current_status" "public"."job_status", "p_next_status" "public"."job_status", "p_actor_role" "text", "p_is_admin" boolean, "p_metadata" "jsonb") OWNER TO "postgres";

--
-- Name: issue_guest_action_token("uuid", "text", "text", "text", "uuid", "text"); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."issue_guest_action_token"("p_job_id" "uuid", "p_access_token" "text", "p_action_type" "text", "p_phone_confirmation" "text", "p_otp_challenge_id" "uuid" DEFAULT NULL::"uuid", "p_otp_code" "text" DEFAULT NULL::"text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
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


ALTER FUNCTION "public"."issue_guest_action_token"("p_job_id" "uuid", "p_access_token" "text", "p_action_type" "text", "p_phone_confirmation" "text", "p_otp_challenge_id" "uuid", "p_otp_code" "text") OWNER TO "postgres";

--
-- Name: job_event_to_timeline(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."job_event_to_timeline"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  status_value public.job_status;
  actor_profile uuid;
begin
  if coalesce(new.metadata, '{}'::jsonb) ? 'skip_timeline'
     or coalesce(new.metadata, '{}'::jsonb) ? 'timeline_id' then
    return new;
  end if;

  if nullif(btrim(coalesce(new.public_message, '')), '') is null then
    return new;
  end if;

  status_value := public.job_status_for_event(new.event_type, new.metadata);
  if status_value is null then
    select status into status_value from public.jobs where id = new.job_id;
  end if;

  if status_value is null then
    return new;
  end if;

  select id into actor_profile
  from public.profiles
  where id = new.actor_id;

  insert into public.job_timeline (job_id, status, note, actor_profile_id, metadata)
  values (
    new.job_id,
    status_value,
    new.public_message,
    actor_profile,
    jsonb_build_object(
      'skip_job_event_log', true,
      'derived_from', 'job_events',
      'event_id', new.id
    )
  )
  on conflict do nothing;

  return new;
end;
$$;


ALTER FUNCTION "public"."job_event_to_timeline"() OWNER TO "postgres";

--
-- Name: job_event_type_for_status("public"."job_status"); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."job_event_type_for_status"("p_status" "public"."job_status") RETURNS "text"
    LANGUAGE "sql" IMMUTABLE
    SET "search_path" TO 'public'
    AS $$
  select case p_status::text
    when 'requested' then 'JOB_CREATED'
    when 'matching' then 'PAIRING_STARTED'
    when 'assigned' then 'ELECTRICIAN_ASSIGNED'
    when 'accepted' then 'ASSIGNMENT_ACCEPTED'
    when 'assessment_fee_pending' then 'ASSIGNMENT_ACCEPTED'
    when 'assessment_payment_pending_verification' then 'PAYMENT_SUBMITTED'
    when 'assessment_confirmed' then 'PAYMENT_VERIFIED'
    when 'en_route' then 'JOB_UPDATED'
    when 'on_site' then 'JOB_UPDATED'
    when 'quoted' then 'QUOTE_SUBMITTED'
    when 'quote_accepted' then 'QUOTE_SUBMITTED'
    when 'work_payment_pending_verification' then 'PAYMENT_SUBMITTED'
    when 'payment_confirmed' then 'PAYMENT_VERIFIED'
    when 'work_in_progress' then 'WORK_STARTED'
    when 'electrician_completed' then 'WORK_COMPLETED'
    when 'customer_confirmed' then 'CUSTOMER_CONFIRMED'
    when 'payout_pending' then 'CUSTOMER_CONFIRMED'
    when 'payout_complete' then 'PAYOUT_RELEASED'
    when 'rated' then 'RATING_SUBMITTED'
    when 'cancelled' then 'JOB_CANCELLED'
    else 'JOB_UPDATED'
  end;
$$;


ALTER FUNCTION "public"."job_event_type_for_status"("p_status" "public"."job_status") OWNER TO "postgres";

--
-- Name: job_payload_for_role("public"."jobs", "text"); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."job_payload_for_role"("p_job" "public"."jobs", "p_role" "text") RETURNS "jsonb"
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  select jsonb_strip_nulls(jsonb_build_object(
    'id', p_job.id,
    'ticket', p_job.ticket,
    'customer_id', p_job.customer_id,
    'guest_customer_id', case when lower(coalesce(p_role, '')) in ('admin', 'electrician') then p_job.guest_customer_id end,
    'assigned_electrician_id', p_job.assigned_electrician_id,
    'service_area', p_job.service_area,
    'location_label', p_job.location_label,
    'latitude', p_job.latitude,
    'longitude', p_job.longitude,
    'issue_category', p_job.issue_category,
    'urgency', p_job.urgency,
    'customer_note', p_job.customer_note,
    'requires_assessment', p_job.requires_assessment,
    'material_handling', p_job.material_handling,
    'status', p_job.status,
    'state_version', p_job.state_version,
    'candidate_queue', case when lower(coalesce(p_role, '')) = 'admin' then p_job.candidate_queue end,
    'attempted_electrician_ids', case when lower(coalesce(p_role, '')) = 'admin' then p_job.attempted_electrician_ids end,
    'dispatch_attempts', case when lower(coalesce(p_role, '')) = 'admin' then p_job.dispatch_attempts end,
    'last_dispatch_at', case when lower(coalesce(p_role, '')) = 'admin' then p_job.last_dispatch_at end,
    'dispatch_priority_score', case when lower(coalesce(p_role, '')) = 'admin' then p_job.dispatch_priority_score end,
    'dispatch_priority_reason', case when lower(coalesce(p_role, '')) = 'admin' then p_job.dispatch_priority_reason end,
    'assignment_expires_at', p_job.assignment_expires_at,
    'accepted_at', p_job.accepted_at,
    'customer_confirmed_at', p_job.customer_confirmed_at,
    'electrician_completed_at', p_job.electrician_completed_at,
    'payout_released_at', case when lower(coalesce(p_role, '')) in ('admin', 'electrician') then p_job.payout_released_at end,
    'created_at', p_job.created_at,
    'updated_at', p_job.updated_at,
    'guest_dispatch_verified_at', case when lower(coalesce(p_role, '')) = 'admin' then p_job.guest_dispatch_verified_at end,
    'customer', case when p_job.customer_id is not null then (
      select jsonb_strip_nulls(jsonb_build_object(
        'id', c.id,
        'profile_id', c.profile_id,
        'primary_service_area', c.primary_service_area,
        'location_label', c.location_label,
        'phone', case when lower(coalesce(p_role, '')) in ('admin', 'electrician', 'customer') then coalesce(c.phone, p.phone) end,
        'average_behavior_rating', case when lower(coalesce(p_role, '')) in ('admin', 'electrician') then c.average_behavior_rating end,
        'total_behavior_ratings', case when lower(coalesce(p_role, '')) in ('admin', 'electrician') then c.total_behavior_ratings end,
        'completed_requests', case when lower(coalesce(p_role, '')) in ('admin', 'electrician') then c.completed_requests end,
        'cancellation_count', case when lower(coalesce(p_role, '')) in ('admin', 'electrician') then c.cancellation_count end,
        'no_show_reports', case when lower(coalesce(p_role, '')) in ('admin', 'electrician') then c.no_show_reports end,
        'dispute_count', case when lower(coalesce(p_role, '')) in ('admin', 'electrician') then c.dispute_count end,
        'payment_issue_count', case when lower(coalesce(p_role, '')) in ('admin', 'electrician') then c.payment_issue_count end,
        'trust_status', case when lower(coalesce(p_role, '')) in ('admin', 'electrician') then c.trust_status end,
        'trust_notes', case when lower(coalesce(p_role, '')) = 'admin' then c.trust_notes end,
        'profile', jsonb_strip_nulls(jsonb_build_object(
          'full_name', p.full_name,
          'phone', case when lower(coalesce(p_role, '')) in ('admin', 'electrician', 'customer') then coalesce(p.phone, c.phone) end
        ))
      ))
      from public.customers c
      left join public.profiles p on p.id = c.profile_id
      where c.id = p_job.customer_id
    ) end,
    'guest_customer', case when p_job.guest_customer_id is not null and lower(coalesce(p_role, '')) in ('admin', 'electrician') then (
      select jsonb_build_object(
        'id', g.id,
        'phone', g.phone,
        'location_label', g.location_label,
        'created_at', g.created_at
      )
      from public.guest_customers g
      where g.id = p_job.guest_customer_id
    ) end,
    'assigned_electrician', case when p_job.assigned_electrician_id is not null then (
      select jsonb_strip_nulls(jsonb_build_object(
        'id', e.id,
        'profile_id', e.profile_id,
        'display_name', coalesce(p.full_name, 'VoltFriq'),
        'name', coalesce(p.full_name, 'VoltFriq'),
        'avatar_url', p.avatar_url,
        'status', case when lower(coalesce(p_role, '')) = 'admin' then e.status end,
        'years_experience', e.years_experience,
        'service_areas', e.service_areas,
        'location_label', case when lower(coalesce(p_role, '')) in ('admin', 'electrician') then e.location_label end,
        'latitude', case when lower(coalesce(p_role, '')) = 'admin' then e.latitude end,
        'longitude', case when lower(coalesce(p_role, '')) = 'admin' then e.longitude end,
        'average_rating', e.average_rating,
        'total_ratings', e.total_ratings,
        'completed_jobs', e.completed_jobs,
        'availability_status', case when lower(coalesce(p_role, '')) in ('admin', 'electrician') then e.availability_status end,
        'response_rate', e.response_rate,
        'level_badge', e.level_badge,
        'watchlist', case when lower(coalesce(p_role, '')) = 'admin' then e.watchlist end,
        'watchlist_reason', case when lower(coalesce(p_role, '')) = 'admin' then e.watchlist_reason end,
        'negative_rating_count', case when lower(coalesce(p_role, '')) = 'admin' then e.negative_rating_count end,
        'suspended_reason', case when lower(coalesce(p_role, '')) = 'admin' then e.suspended_reason end,
        'acceptance_score', e.acceptance_score,
        'response_score', e.response_score,
        'completion_score', e.completion_score,
        'dispute_score', e.dispute_score,
        'reliability_score', e.reliability_score,
        'tier', e.tier,
        'profile', jsonb_strip_nulls(jsonb_build_object(
          'full_name', p.full_name,
          'phone', case when lower(coalesce(p_role, '')) in ('admin', 'electrician') then p.phone end,
          'avatar_url', p.avatar_url
        )),
        'electrician_skills', coalesce((
          select jsonb_agg(jsonb_build_object('category', s.category) order by s.category)
          from public.electrician_skills s
          where s.electrician_id = e.id
        ), '[]'::jsonb)
      ))
      from public.electricians e
      left join public.profiles p on p.id = e.profile_id
      where e.id = p_job.assigned_electrician_id
    ) end,
    'job_photos', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', ph.id,
        'job_id', ph.job_id,
        'file_path', ph.file_path,
        'created_at', ph.created_at
      ) order by ph.created_at)
      from public.job_photos ph
      where ph.job_id = p_job.id
    ), '[]'::jsonb),
    'job_quotes', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', q.id,
        'job_id', q.job_id,
        'electrician_id', q.electrician_id,
        'findings', q.findings,
        'measurements', q.measurements,
        'labor_total', q.labor_total,
        'material_total', q.material_total,
        'grand_total', q.grand_total,
        'created_at', q.created_at,
        'quote_items', coalesce((
          select jsonb_agg(jsonb_build_object(
            'id', qi.id,
            'quote_id', qi.quote_id,
            'item_type', qi.item_type,
            'description', qi.description,
            'quantity', qi.quantity,
            'unit_price', qi.unit_price,
            'line_total', qi.line_total,
            'created_at', qi.created_at
          ) order by qi.created_at)
          from public.quote_items qi
          where qi.quote_id = q.id
        ), '[]'::jsonb)
      ) order by q.created_at)
      from public.job_quotes q
      where q.job_id = p_job.id
    ), '[]'::jsonb),
    'job_payments', coalesce((
      select jsonb_agg(
        case when lower(coalesce(p_role, '')) = 'admin' then
          jsonb_build_object(
            'id', pay.id,
            'job_id', pay.job_id,
            'submitted_by', pay.submitted_by,
            'payment_type', pay.payment_type,
            'amount', pay.amount,
            'proof_path', pay.proof_path,
            'reference', pay.reference,
            'status', pay.status,
            'admin_note', pay.admin_note,
            'verified_by', pay.verified_by,
            'verified_at', pay.verified_at,
            'created_at', pay.created_at,
            'guest_customer_id', pay.guest_customer_id
          )
        else
          jsonb_strip_nulls(jsonb_build_object(
            'id', pay.id,
            'job_id', pay.job_id,
            'payment_type', pay.payment_type,
            'amount', pay.amount,
            'reference', pay.reference,
            'status', pay.status,
            'verified_at', pay.verified_at,
            'created_at', pay.created_at
          ))
        end
        order by pay.created_at desc
      )
      from public.job_payments pay
      where pay.job_id = p_job.id
    ), '[]'::jsonb),
    'progress_timeline', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', e.id,
        'job_id', e.job_id,
        'event_type', e.event_type,
        'public_message', public.public_message_for_job_event(e.event_type, coalesce(e.projected_status, p_job.status), e.public_message),
        'metadata', case when lower(coalesce(p_role, '')) = 'admin' then e.metadata else '{}'::jsonb end,
        'created_at', e.created_at
      ) order by e.created_at)
      from public.job_events e
      where e.job_id = p_job.id
        and nullif(btrim(coalesce(e.public_message, '')), '') is not null
        and (lower(coalesce(p_role, '')) = 'admin' or e.visibility = 'public')
    ), '[]'::jsonb),
    'job_events', case when lower(coalesce(p_role, '')) = 'admin' then coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', e.id,
        'job_id', e.job_id,
        'event_type', e.event_type,
        'actor_role', e.actor_role,
        'actor_id', e.actor_id,
        'request_id', e.request_id,
        'event_version', e.event_version,
        'transition_id', e.transition_id,
        'public_message', public.public_message_for_job_event(e.event_type, coalesce(e.projected_status, p_job.status), e.public_message),
        'internal_note', e.internal_note,
        'metadata', e.metadata,
        'payload', e.payload,
        'created_at', e.created_at
      ) order by e.created_at)
      from public.job_events e
      where e.job_id = p_job.id
    ), '[]'::jsonb) end,
    'ratings', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', r.id,
        'job_id', r.job_id,
        'customer_id', r.customer_id,
        'electrician_id', r.electrician_id,
        'score', r.score,
        'comment', r.comment,
        'review_direction', r.review_direction,
        'behavior_tags', r.behavior_tags,
        'created_at', r.created_at
      ) order by r.created_at)
      from public.ratings r
      where r.job_id = p_job.id
    ), '[]'::jsonb)
  ));
$$;


ALTER FUNCTION "public"."job_payload_for_role"("p_job" "public"."jobs", "p_role" "text") OWNER TO "postgres";

--
-- Name: job_status_for_event("text", "jsonb"); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."job_status_for_event"("p_event_type" "text", "p_metadata" "jsonb" DEFAULT '{}'::"jsonb") RETURNS "public"."job_status"
    LANGUAGE "sql" STABLE
    SET "search_path" TO 'public'
    AS $$
  select case
    when coalesce(p_metadata, '{}'::jsonb) ->> 'next_status' in (
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
    ) then (p_metadata ->> 'next_status')::public.job_status
    when p_event_type = 'JOB_CREATED' then 'requested'::public.job_status
    when p_event_type = 'PAIRING_STARTED' then 'matching'::public.job_status
    when p_event_type = 'ELECTRICIAN_ASSIGNED' then 'assigned'::public.job_status
    when p_event_type = 'ASSIGNMENT_ACCEPTED' then 'accepted'::public.job_status
    when p_event_type = 'ASSIGNMENT_REJECTED' then 'matching'::public.job_status
    when p_event_type = 'ASSIGNMENT_EXPIRED' then 'matching'::public.job_status
    when p_event_type = 'PAYMENT_SUBMITTED' then null::public.job_status
    when p_event_type = 'PAYMENT_VERIFIED' then null::public.job_status
    when p_event_type = 'WORK_STARTED' then 'work_in_progress'::public.job_status
    when p_event_type = 'WORK_COMPLETED' then 'electrician_completed'::public.job_status
    when p_event_type = 'CUSTOMER_CONFIRMED' then 'customer_confirmed'::public.job_status
    when p_event_type = 'DISPUTE_OPENED' then null::public.job_status
    when p_event_type = 'JOB_CANCELLED' then 'cancelled'::public.job_status
    when p_event_type = 'QUOTE_SUBMITTED' then 'quoted'::public.job_status
    when p_event_type = 'PAYOUT_RELEASED' then 'payout_complete'::public.job_status
    when p_event_type = 'RATING_SUBMITTED' then 'rated'::public.job_status
    else null::public.job_status
  end;
$$;


ALTER FUNCTION "public"."job_status_for_event"("p_event_type" "text", "p_metadata" "jsonb") OWNER TO "postgres";

--
-- Name: job_timeline_to_event(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."job_timeline_to_event"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
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


ALTER FUNCTION "public"."job_timeline_to_event"() OWNER TO "postgres";

--
-- Name: referrals; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE "public"."referrals" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "referrer_profile_id" "uuid" NOT NULL,
    "referred_profile_id" "uuid" NOT NULL,
    "referral_code" "text" NOT NULL,
    "status" "text" DEFAULT 'pending'::"text" NOT NULL,
    "reward_amount" numeric(12,2) DEFAULT 0 NOT NULL,
    "completed_at" timestamp with time zone,
    "rewarded_at" timestamp with time zone,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."referrals" OWNER TO "postgres";

--
-- Name: link_referral_code("text"); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."link_referral_code"("p_referral_code" "text") RETURNS "public"."referrals"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
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


ALTER FUNCTION "public"."link_referral_code"("p_referral_code" "text") OWNER TO "postgres";

--
-- Name: log_job_event("uuid", "text", "text", "uuid", "text", "text", "jsonb"); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."log_job_event"("p_job_id" "uuid", "p_event_type" "text", "p_actor_role" "text" DEFAULT NULL::"text", "p_actor_id" "uuid" DEFAULT "auth"."uid"(), "p_public_message" "text" DEFAULT NULL::"text", "p_internal_note" "text" DEFAULT NULL::"text", "p_metadata" "jsonb" DEFAULT '{}'::"jsonb") RETURNS "uuid"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $_$
declare
  event_id uuid;
  existing_event public.job_events;
  job_row public.jobs;
  job_status_value public.job_status;
  event_public_message text;
  metadata_value jsonb := coalesce(p_metadata, '{}'::jsonb);
  idempotency text := nullif(btrim(coalesce(p_metadata->>'idempotency_key', '')), '');
  request_id_value text := public.sanitize_request_id(coalesce(p_metadata ->> 'request_id', p_metadata ->> 'requestId', p_metadata ->> 'operation_request_id'));
  request_hash_value text;
  severity_value text := coalesce(nullif(btrim(coalesce(p_metadata->>'severity', '')), ''), 'info');
  visibility_value text := coalesce(nullif(btrim(coalesce(p_metadata->>'visibility', '')), ''), 'public');
  source_value text := coalesce(nullif(btrim(coalesce(p_metadata->>'source', '')), ''), 'app');
  expected_state_version integer;
begin
  metadata_value := metadata_value - 'request_id' - 'requestId' - 'operation_request_id';
  request_hash_value := md5(jsonb_build_object(
    'job_id', p_job_id,
    'event_type', p_event_type,
    'metadata', metadata_value - 'idempotency_key' - 'severity' - 'visibility' - 'source'
  )::text);

  if request_id_value is not null then
    select * into existing_event from public.job_events where request_id = request_id_value;
    if existing_event.id is not null then
      if existing_event.request_hash is distinct from request_hash_value then
        raise exception 'Request id % was already used for a different event', request_id_value;
      end if;
      return existing_event.id;
    end if;
  end if;

  if idempotency is not null then
    select * into existing_event from public.job_events where idempotency_key = idempotency;
    if existing_event.id is not null then
      return existing_event.id;
    end if;
  end if;

  select * into job_row
  from public.jobs
  where id = p_job_id
  for update;

  if not found then
    raise exception 'Job not found';
  end if;

  job_status_value := job_row.status;

  if metadata_value ->> 'expected_state_version' ~ '^[0-9]+$' then
    expected_state_version := (metadata_value ->> 'expected_state_version')::integer;
    if expected_state_version <> coalesce(job_row.state_version, 0) then
      perform public.upsert_operational_alert(
        'state_conflict',
        'warning',
        'Stale job event write blocked.',
        p_job_id,
        null,
        null,
        null,
        null,
        jsonb_build_object(
          'expected_state_version', expected_state_version,
          'actual_state_version', coalesce(job_row.state_version, 0),
          'event_type', p_event_type,
          'source', source_value,
          'request_id', request_id_value
        )
      );
      raise exception 'This job changed from version % to %. Refresh and try again.',
        expected_state_version,
        coalesce(job_row.state_version, 0);
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
    request_id,
    request_hash,
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
    request_id_value,
    request_hash_value,
    case when severity_value in ('info', 'warning', 'critical') then severity_value else 'info' end,
    case when visibility_value in ('public', 'internal') then visibility_value else 'public' end,
    source_value
  )
  returning id into event_id;

  return event_id;
exception
  when unique_violation then
    if request_id_value is not null then
      select * into existing_event from public.job_events where request_id = request_id_value;
      if existing_event.id is not null then
        if existing_event.request_hash is distinct from request_hash_value then
          raise exception 'Request id % was already used for a different event', request_id_value;
        end if;
        return existing_event.id;
      end if;
    end if;
    if idempotency is not null then
      select id into event_id from public.job_events where idempotency_key = idempotency;
      return event_id;
    end if;
    raise;
end;
$_$;


ALTER FUNCTION "public"."log_job_event"("p_job_id" "uuid", "p_event_type" "text", "p_actor_role" "text", "p_actor_id" "uuid", "p_public_message" "text", "p_internal_note" "text", "p_metadata" "jsonb") OWNER TO "postgres";

--
-- Name: mark_guest_otp_delivery("uuid", "text", "jsonb"); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."mark_guest_otp_delivery"("p_challenge_id" "uuid", "p_delivery_status" "text", "p_metadata" "jsonb" DEFAULT '{}'::"jsonb") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
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


ALTER FUNCTION "public"."mark_guest_otp_delivery"("p_challenge_id" "uuid", "p_delivery_status" "text", "p_metadata" "jsonb") OWNER TO "postgres";

--
-- Name: operational_alert_dedupe_key("text", "uuid", "uuid", "uuid", "uuid"); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."operational_alert_dedupe_key"("p_alert_type" "text", "p_job_id" "uuid" DEFAULT NULL::"uuid", "p_electrician_id" "uuid" DEFAULT NULL::"uuid", "p_payment_id" "uuid" DEFAULT NULL::"uuid", "p_dispute_id" "uuid" DEFAULT NULL::"uuid") RETURNS "text"
    LANGUAGE "sql" STABLE
    AS $$
  select p_alert_type || ':' ||
    coalesce(p_job_id::text, p_electrician_id::text, p_payment_id::text, p_dispute_id::text, 'global')
$$;


ALTER FUNCTION "public"."operational_alert_dedupe_key"("p_alert_type" "text", "p_job_id" "uuid", "p_electrician_id" "uuid", "p_payment_id" "uuid", "p_dispute_id" "uuid") OWNER TO "postgres";

--
-- Name: platform_health_snapshot(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."platform_health_snapshot"() RETURNS "jsonb"
    LANGUAGE "sql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  select public.admin_operational_summary();
$$;


ALTER FUNCTION "public"."platform_health_snapshot"() OWNER TO "postgres";

--
-- Name: prepare_guest_dispatch_otp("uuid", "text", "text", "text"); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."prepare_guest_dispatch_otp"("p_job_id" "uuid", "p_access_token" "text", "p_phone_confirmation" "text", "p_client_fingerprint" "text" DEFAULT NULL::"text") RETURNS "jsonb"
    LANGUAGE "sql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  select public.request_guest_otp(
    p_job_id,
    p_access_token,
    'dispatch_confirm',
    p_phone_confirmation,
    p_client_fingerprint
  );
$$;


ALTER FUNCTION "public"."prepare_guest_dispatch_otp"("p_job_id" "uuid", "p_access_token" "text", "p_phone_confirmation" "text", "p_client_fingerprint" "text") OWNER TO "postgres";

--
-- Name: prepare_job_event_version(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."prepare_job_event_version"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $_$
declare
  job_row public.jobs;
  latest_version integer := 0;
  latest_projected_status public.job_status;
  metadata_state_version integer;
  metadata_previous_version integer;
  expected_state_version integer;
  projected public.job_status;
  metadata_transition_id uuid;
begin
  if new.event_sequence is null then
    new.event_sequence := nextval('public.job_events_event_sequence_seq'::regclass);
  end if;

  if new.transition_id is null
     and coalesce(new.metadata, '{}'::jsonb) ->> 'transition_id' ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then
    metadata_transition_id := (new.metadata ->> 'transition_id')::uuid;
    new.transition_id := metadata_transition_id;
  end if;

  if new.transition_id is null then
    new.transition_id := gen_random_uuid();
  end if;

  if new.request_id is null then
    new.request_id := public.sanitize_request_id(coalesce(new.metadata ->> 'request_id', new.metadata ->> 'requestId'));
  else
    new.request_id := public.sanitize_request_id(new.request_id);
  end if;

  if new.request_hash is null and new.request_id is not null then
    new.request_hash := md5(jsonb_build_object(
      'job_id', new.job_id,
      'event_type', new.event_type,
      'transition_id', new.transition_id,
      'metadata', coalesce(new.metadata, '{}'::jsonb) - 'request_id' - 'requestId' - 'transition_id'
    )::text);
  end if;

  new.metadata := coalesce(new.metadata, '{}'::jsonb) - 'request_id' - 'requestId' - 'transition_id';

  select * into job_row
  from public.jobs
  where id = new.job_id
  for update;

  if not found then
    raise exception 'Job not found';
  end if;

  select coalesce(max(coalesce(event_version, transition_to_version)), 0)
  into latest_version
  from public.job_events
  where job_id = new.job_id;

  select projected_status
  into latest_projected_status
  from public.job_events
  where job_id = new.job_id
    and projected_status is not null
  order by coalesce(event_version, transition_to_version) desc, event_sequence desc
  limit 1;

  if coalesce(new.metadata, '{}'::jsonb) ->> 'state_version' ~ '^[0-9]+$' then
    metadata_state_version := (new.metadata ->> 'state_version')::integer;
  end if;

  if coalesce(new.metadata, '{}'::jsonb) ->> 'previous_state_version' ~ '^[0-9]+$' then
    metadata_previous_version := (new.metadata ->> 'previous_state_version')::integer;
  end if;

  if coalesce(new.metadata, '{}'::jsonb) ->> 'expected_state_version' ~ '^[0-9]+$' then
    expected_state_version := (new.metadata ->> 'expected_state_version')::integer;
    if expected_state_version <> coalesce(job_row.state_version, 0) then
      perform public.upsert_operational_alert(
        'state_conflict',
        'warning',
        'Stale event write blocked by state version guard.',
        new.job_id,
        null,
        null,
        null,
        null,
        jsonb_build_object(
          'expected_state_version', expected_state_version,
          'actual_state_version', coalesce(job_row.state_version, 0),
          'event_type', new.event_type,
          'transition_id', new.transition_id,
          'source', coalesce(new.source, new.metadata ->> 'source', 'event_insert')
        )
      );
      raise exception 'Stale job event for %. Expected version %, actual version %',
        new.job_id,
        expected_state_version,
        coalesce(job_row.state_version, 0);
    end if;
  end if;

  projected := public.job_status_for_event(new.event_type, new.metadata);
  new.projected_status := projected;

  if new.transition_to_version is null then
    if metadata_state_version is not null then
      new.transition_to_version := metadata_state_version;
    elsif projected is null then
      new.transition_to_version := greatest(coalesce(job_row.state_version, 0), latest_version, 0);
    elsif projected = job_row.status then
      new.transition_to_version := greatest(coalesce(job_row.state_version, 0), latest_version, 1);
    else
      new.transition_to_version := greatest(coalesce(job_row.state_version, 0), latest_version) + 1;
    end if;
  end if;

  new.event_version := coalesce(new.event_version, new.transition_to_version, latest_version);

  if projected is not null
     and latest_version > 0
     and coalesce(new.event_version, new.transition_to_version, 0) <= latest_version
     and projected is distinct from latest_projected_status then
    perform public.upsert_operational_alert(
      'state_conflict',
      'warning',
      'Stale projected event write blocked before snapshot mutation.',
      new.job_id,
      null,
      null,
      null,
      null,
      jsonb_build_object(
        'event_type', new.event_type,
        'incoming_version', coalesce(new.event_version, new.transition_to_version, 0),
        'latest_version', latest_version,
        'incoming_status', projected,
        'latest_projected_status', latest_projected_status,
        'transition_id', new.transition_id,
        'source', coalesce(new.source, new.metadata ->> 'source', 'event_insert')
      )
    );
    raise exception 'Stale job event %. Incoming version %, latest version %',
      new.event_type,
      coalesce(new.event_version, new.transition_to_version, 0),
      latest_version;
  end if;

  new.transition_from_version := coalesce(
    new.transition_from_version,
    metadata_previous_version,
    greatest(coalesce(new.transition_to_version, 0) - 1, 0)
  );

  new.metadata := coalesce(new.metadata, '{}'::jsonb)
    || jsonb_build_object(
      'event_version', new.event_version,
      'transition_id', new.transition_id,
      'state_version', new.transition_to_version,
      'transition_from_version', new.transition_from_version
    );

  return new;
end;
$_$;


ALTER FUNCTION "public"."prepare_job_event_version"() OWNER TO "postgres";

--
-- Name: prioritize_dispatch_queue(integer); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."prioritize_dispatch_queue"("p_limit" integer DEFAULT 200) RETURNS integer
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  updated_count integer := 0;
begin
  if auth.role() <> 'service_role' then
    raise exception 'Service role required';
  end if;

  with ranked as (
    select
      j.id,
      (
        case j.urgency
          when 'emergency' then 120
          when 'today' then 70
          else 35
        end
        + least(extract(epoch from (now() - j.created_at)) / 60, 240)
        + coalesce(j.dispatch_attempts, 0) * 18
        + case when j.status = 'assigned' and j.assignment_expires_at <= now() then 80 else 0 end
        + case when exists (
          select 1 from public.disputes d where d.job_id = j.id and d.status = 'open'
        ) then 35 else 0 end
      )::numeric(12,2) as score,
      case
        when j.status = 'assigned' and j.assignment_expires_at <= now() then 'expired_assignment'
        when coalesce(j.dispatch_attempts, 0) >= 3 then 'dispatch_retry'
        when j.urgency = 'emergency' then 'emergency'
        else 'standard'
      end as reason
    from public.jobs j
    where j.status in ('requested', 'matching', 'assigned')
    order by j.created_at asc
    limit greatest(coalesce(p_limit, 200), 1)
  )
  update public.jobs j
  set dispatch_priority_score = ranked.score,
      dispatch_priority_reason = ranked.reason,
      dispatch_priority_updated_at = now()
  from ranked
  where j.id = ranked.id;

  get diagnostics updated_count = row_count;
  return updated_count;
end;
$$;


ALTER FUNCTION "public"."prioritize_dispatch_queue"("p_limit" integer) OWNER TO "postgres";

--
-- Name: process_dispatch_queue(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."process_dispatch_queue"() RETURNS integer
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  expired_job record;
  matching_job record;
  processed_count integer := 0;
begin
  perform public.sync_all_job_state_projections(100);
  perform public.prioritize_dispatch_queue(200);
  perform public.refresh_operational_alerts();

  for expired_job in
    select id, assigned_electrician_id, current_assignment_event_id, current_assignment_token
    from public.jobs
    where status = 'assigned'
      and assignment_expires_at is not null
      and assignment_expires_at <= now()
    order by dispatch_priority_score desc, assignment_expires_at asc
    for update skip locked
  loop
    update public.jobs
    set status = 'matching',
        assigned_electrician_id = null,
        assignment_expires_at = null,
        current_assignment_event_id = null,
        current_assignment_token = null,
        state_version = coalesce(state_version, 0) + 1,
        updated_at = now()
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
        'source', 'dispatch_queue',
        'severity', 'warning',
        'idempotency_key', 'assignment-expired:' || expired_job.id::text || ':' || coalesce(expired_job.current_assignment_event_id::text, coalesce(expired_job.assigned_electrician_id::text, 'none'))
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
    order by dispatch_priority_score desc, created_at asc
    for update skip locked
  loop
    perform public.dispatch_job_internal(matching_job.id, null);
    processed_count := processed_count + 1;
  end loop;

  perform public.refresh_operational_alerts();
  return processed_count;
end;
$$;


ALTER FUNCTION "public"."process_dispatch_queue"() OWNER TO "postgres";

--
-- Name: project_job_event_state(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."project_job_event_state"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
begin
  if new.projected_status is null then
    return new;
  end if;

  insert into public.job_state_projections (
    job_id,
    projected_status,
    event_id,
    event_sequence,
    state_version,
    projected_at,
    metadata
  )
  values (
    new.job_id,
    new.projected_status,
    new.id,
    new.event_sequence,
    coalesce(new.event_version, new.transition_to_version, 0),
    now(),
    jsonb_build_object('event_type', new.event_type, 'source', new.source, 'request_id', new.request_id, 'transition_id', new.transition_id)
  )
  on conflict (job_id) do update
  set projected_status = excluded.projected_status,
      event_id = excluded.event_id,
      event_sequence = excluded.event_sequence,
      state_version = excluded.state_version,
      projected_at = now(),
      metadata = public.job_state_projections.metadata || excluded.metadata
  where excluded.state_version > public.job_state_projections.state_version
     or (
       excluded.state_version = public.job_state_projections.state_version
       and excluded.projected_status = public.job_state_projections.projected_status
       and excluded.event_sequence >= public.job_state_projections.event_sequence
     );

  update public.jobs
  set status = new.projected_status,
      state_version = greatest(coalesce(state_version, 0), coalesce(new.event_version, new.transition_to_version, 0)),
      snapshot_reconciled_at = now(),
      updated_at = now()
  where id = new.job_id
    and coalesce(new.event_version, new.transition_to_version, 0) > coalesce(state_version, 0);

  update public.job_events
  set projected_at = coalesce(projected_at, now())
  where id = new.id;

  return new;
end;
$$;


ALTER FUNCTION "public"."project_job_event_state"() OWNER TO "postgres";

--
-- Name: public_message_for_job_event("text", "public"."job_status", "text"); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."public_message_for_job_event"("p_event_type" "text", "p_status" "public"."job_status" DEFAULT NULL::"public"."job_status", "p_note" "text" DEFAULT NULL::"text") RETURNS "text"
    LANGUAGE "sql" STABLE
    SET "search_path" TO 'public'
    AS $$
  select case
    when lower(coalesce(p_note, '')) like any (array[
      '%manual assignment required%',
      '%admin assignment%',
      '%admin manually assigned%',
      '%no electrician available%',
      '%dispatch failed%'
    ]) then 'VoltFriq support is helping route your request.'
    when p_event_type = 'JOB_CREATED' then 'Booking confirmed.'
    when p_event_type = 'PAIRING_STARTED' then 'Pairing you with a VoltFriq.'
    when p_event_type = 'ELECTRICIAN_ASSIGNED' then 'Electrician assigned.'
    when p_event_type = 'ASSIGNMENT_ACCEPTED' then 'Your VoltFriq has accepted the booking.'
    when p_event_type = 'ASSIGNMENT_REJECTED' then 'Pairing you with a VoltFriq.'
    when p_event_type = 'ASSIGNMENT_EXPIRED' then 'Still finding a verified VoltFriq near you.'
    when p_event_type = 'PAYMENT_SUBMITTED' then 'Payment proof received for review.'
    when p_event_type = 'PAYMENT_VERIFIED' then 'Payment confirmed.'
    when p_event_type = 'WORK_STARTED' then 'Work is in progress.'
    when p_event_type = 'WORK_COMPLETED' then 'Completed.'
    when p_event_type = 'CUSTOMER_CONFIRMED' then 'Completion confirmed.'
    when p_event_type = 'DISPUTE_OPENED' then 'VoltFriq support is reviewing your issue.'
    when p_event_type = 'JOB_CANCELLED' then 'Booking cancelled.'
    when p_event_type = 'QUOTE_SUBMITTED' then 'Your quote is ready.'
    when p_event_type = 'PAYOUT_RELEASED' then 'Job complete.'
    when p_event_type = 'RATING_SUBMITTED' then 'Thanks for rating your VoltFriq.'
    when p_status = 'en_route' then 'On the way.'
    when p_status = 'on_site' then 'Your VoltFriq is on site.'
    else public.guest_public_timeline_note(coalesce(p_status, 'matching'::public.job_status))
  end;
$$;


ALTER FUNCTION "public"."public_message_for_job_event"("p_event_type" "text", "p_status" "public"."job_status", "p_note" "text") OWNER TO "postgres";

--
-- Name: rebuild_all_job_projections(integer, "text"); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."rebuild_all_job_projections"("p_limit" integer DEFAULT 500, "p_request_id" "text" DEFAULT NULL::"text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
begin
  if auth.role() <> 'service_role' then
    raise exception 'Service role required';
  end if;
  return public.rebuild_all_projections(p_limit, p_request_id);
end;
$$;


ALTER FUNCTION "public"."rebuild_all_job_projections"("p_limit" integer, "p_request_id" "text") OWNER TO "postgres";

--
-- Name: rebuild_all_job_state_projections(integer); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."rebuild_all_job_state_projections"("p_limit" integer DEFAULT 500) RETURNS integer
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  item record;
  rebuilt_count integer := 0;
begin
  if not (public.is_admin() or auth.role() = 'service_role') then
    raise exception 'Admin or service role required';
  end if;

  for item in
    select j.id
    from public.jobs j
    left join public.job_state_projections p on p.job_id = j.id
    where exists (
      select 1 from public.job_events e
      where e.job_id = j.id
        and e.projected_status is not null
    )
    order by coalesce(p.snapshot_synced_at, to_timestamp(0)) asc, j.updated_at asc
    limit greatest(coalesce(p_limit, 500), 1)
  loop
    perform public.rebuild_job_state_projection(item.id, 'bulk-projection-rebuild');
    rebuilt_count := rebuilt_count + 1;
  end loop;

  return rebuilt_count;
end;
$$;


ALTER FUNCTION "public"."rebuild_all_job_state_projections"("p_limit" integer) OWNER TO "postgres";

--
-- Name: rebuild_all_projections(integer, "text"); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."rebuild_all_projections"("p_limit" integer DEFAULT 500, "p_request_id" "text" DEFAULT NULL::"text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
begin
  if auth.role() <> 'service_role' then
    raise exception 'Service role required';
  end if;
  return public.replay_all_job_events(p_limit, p_request_id);
end;
$$;


ALTER FUNCTION "public"."rebuild_all_projections"("p_limit" integer, "p_request_id" "text") OWNER TO "postgres";

--
-- Name: rebuild_job_projection("uuid", "text"); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."rebuild_job_projection"("p_job_id" "uuid", "p_request_id" "text" DEFAULT NULL::"text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
begin
  if auth.role() = 'service_role' then
    return public.replay_job_events(p_job_id, p_request_id);
  end if;
  if public.is_admin() then
    return public.admin_replay_job_events(p_job_id);
  end if;
  raise exception 'Admin or service role required';
end;
$$;


ALTER FUNCTION "public"."rebuild_job_projection"("p_job_id" "uuid", "p_request_id" "text") OWNER TO "postgres";

--
-- Name: rebuild_job_state_projection("uuid", "text"); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."rebuild_job_state_projection"("p_job_id" "uuid", "p_reason" "text" DEFAULT 'projection-rebuild'::"text") RETURNS "public"."jobs"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  event_row public.job_events;
  job_row public.jobs;
begin
  if not (public.is_admin() or auth.role() = 'service_role') then
    raise exception 'Admin or service role required';
  end if;

  select * into job_row
  from public.jobs
  where id = p_job_id
  for update;

  if not found then
    raise exception 'Job not found';
  end if;

  delete from public.job_state_projections
  where job_id = p_job_id;

  select * into event_row
  from public.job_events
  where job_id = p_job_id
    and projected_status is not null
  order by transition_to_version desc, event_sequence desc
  limit 1;

  if not found then
    update public.jobs
    set snapshot_reconciled_at = now()
    where id = p_job_id
    returning * into job_row;
    return job_row;
  end if;

  insert into public.job_state_projections (
    job_id,
    projected_status,
    event_id,
    event_sequence,
    state_version,
    projected_at,
    metadata
  )
  values (
    p_job_id,
    event_row.projected_status,
    event_row.id,
    event_row.event_sequence,
    coalesce(event_row.transition_to_version, 0),
    now(),
    jsonb_build_object('rebuilt', true, 'reason', coalesce(nullif(btrim(p_reason), ''), 'projection-rebuild'))
  )
  on conflict (job_id) do update
  set projected_status = excluded.projected_status,
      event_id = excluded.event_id,
      event_sequence = excluded.event_sequence,
      state_version = excluded.state_version,
      projected_at = excluded.projected_at,
      metadata = public.job_state_projections.metadata || excluded.metadata;

  return public.sync_job_state_projection(p_job_id, p_reason);
end;
$$;


ALTER FUNCTION "public"."rebuild_job_state_projection"("p_job_id" "uuid", "p_reason" "text") OWNER TO "postgres";

--
-- Name: reconcile_active_job_snapshots(integer); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."reconcile_active_job_snapshots"("p_limit" integer DEFAULT 100) RETURNS integer
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
begin
  return public.sync_all_job_state_projections(p_limit);
end;
$$;


ALTER FUNCTION "public"."reconcile_active_job_snapshots"("p_limit" integer) OWNER TO "postgres";

--
-- Name: reconcile_job_snapshot_from_events("uuid", "text"); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."reconcile_job_snapshot_from_events"("p_job_id" "uuid", "p_reason" "text" DEFAULT 'reconcile'::"text") RETURNS "public"."jobs"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
begin
  return public.sync_job_state_projection(p_job_id, p_reason);
end;
$$;


ALTER FUNCTION "public"."reconcile_job_snapshot_from_events"("p_job_id" "uuid", "p_reason" "text") OWNER TO "postgres";

--
-- Name: upload_failures; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE "public"."upload_failures" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "job_id" "uuid",
    "uploader_role" "text" DEFAULT 'guest'::"text" NOT NULL,
    "bucket" "text",
    "file_name" "text",
    "content_type" "text",
    "file_size" integer,
    "failure_stage" "text" NOT NULL,
    "error_message" "text" NOT NULL,
    "metadata" "jsonb" DEFAULT '{}'::"jsonb" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "upload_failures_uploader_role_check" CHECK (("uploader_role" = ANY (ARRAY['guest'::"text", 'customer'::"text", 'electrician'::"text", 'admin'::"text", 'system'::"text"])))
);


ALTER TABLE "public"."upload_failures" OWNER TO "postgres";

--
-- Name: record_upload_failure("uuid", "text", "text", "text", "text", integer, "text", "text", "jsonb"); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."record_upload_failure"("p_job_id" "uuid" DEFAULT NULL::"uuid", "p_uploader_role" "text" DEFAULT 'guest'::"text", "p_bucket" "text" DEFAULT NULL::"text", "p_file_name" "text" DEFAULT NULL::"text", "p_content_type" "text" DEFAULT NULL::"text", "p_file_size" integer DEFAULT NULL::integer, "p_failure_stage" "text" DEFAULT 'upload'::"text", "p_error_message" "text" DEFAULT 'Upload failed'::"text", "p_metadata" "jsonb" DEFAULT '{}'::"jsonb") RETURNS "public"."upload_failures"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  failure_row public.upload_failures;
begin
  if auth.role() <> 'service_role' then
    raise exception 'Service role required';
  end if;

  insert into public.upload_failures (
    job_id,
    uploader_role,
    bucket,
    file_name,
    content_type,
    file_size,
    failure_stage,
    error_message,
    metadata
  )
  values (
    p_job_id,
    case when p_uploader_role in ('guest', 'customer', 'electrician', 'admin', 'system') then p_uploader_role else 'system' end,
    nullif(btrim(coalesce(p_bucket, '')), ''),
    nullif(btrim(coalesce(p_file_name, '')), ''),
    nullif(btrim(coalesce(p_content_type, '')), ''),
    p_file_size,
    coalesce(nullif(btrim(p_failure_stage), ''), 'upload'),
    left(coalesce(nullif(btrim(p_error_message), ''), 'Upload failed'), 500),
    coalesce(p_metadata, '{}'::jsonb)
  )
  returning * into failure_row;

  perform public.upsert_operational_alert(
    'upload_failure',
    'warning',
    'Recent upload failure needs review.',
    p_job_id,
    null,
    null,
    null,
    null,
    jsonb_build_object('failure_id', failure_row.id, 'failure_stage', failure_row.failure_stage)
  );

  return failure_row;
end;
$$;


ALTER FUNCTION "public"."record_upload_failure"("p_job_id" "uuid", "p_uploader_role" "text", "p_bucket" "text", "p_file_name" "text", "p_content_type" "text", "p_file_size" integer, "p_failure_stage" "text", "p_error_message" "text", "p_metadata" "jsonb") OWNER TO "postgres";

--
-- Name: customers; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE "public"."customers" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "profile_id" "uuid" NOT NULL,
    "primary_service_area" "text",
    "latitude" double precision,
    "longitude" double precision,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "average_behavior_rating" numeric(3,2) DEFAULT 0 NOT NULL,
    "total_behavior_ratings" integer DEFAULT 0 NOT NULL,
    "completed_requests" integer DEFAULT 0 NOT NULL,
    "cancellation_count" integer DEFAULT 0 NOT NULL,
    "no_show_reports" integer DEFAULT 0 NOT NULL,
    "dispute_count" integer DEFAULT 0 NOT NULL,
    "payment_issue_count" integer DEFAULT 0 NOT NULL,
    "trust_status" "text" DEFAULT 'clear'::"text" NOT NULL,
    "trust_notes" "text",
    "phone" "text",
    "location_label" "text"
);


ALTER TABLE "public"."customers" OWNER TO "postgres";

--
-- Name: refresh_customer_trust_metrics("uuid"); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."refresh_customer_trust_metrics"("p_customer_id" "uuid") RETURNS "public"."customers"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
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


ALTER FUNCTION "public"."refresh_customer_trust_metrics"("p_customer_id" "uuid") OWNER TO "postgres";

--
-- Name: electrician_performance_snapshots; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE "public"."electrician_performance_snapshots" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "electrician_id" "uuid" NOT NULL,
    "response_rate" numeric(5,2) DEFAULT 0 NOT NULL,
    "acceptance_rate" numeric(5,2) DEFAULT 0 NOT NULL,
    "rejection_rate" numeric(5,2) DEFAULT 0 NOT NULL,
    "average_accept_seconds" numeric(12,2) DEFAULT 0 NOT NULL,
    "completed_jobs" integer DEFAULT 0 NOT NULL,
    "average_rating" numeric(3,2) DEFAULT 0 NOT NULL,
    "negative_rating_count" integer DEFAULT 0 NOT NULL,
    "score" numeric(6,2) DEFAULT 0 NOT NULL,
    "snapshot_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "metadata" "jsonb" DEFAULT '{}'::"jsonb" NOT NULL,
    "completion_score" numeric(5,2) DEFAULT 100 NOT NULL,
    "dispute_score" numeric(5,2) DEFAULT 100 NOT NULL,
    "payout_reliability_score" numeric(5,2) DEFAULT 100 NOT NULL,
    "quality_tier" "text" DEFAULT 'Trusted'::"text" NOT NULL,
    "reliability_score" numeric(6,2) DEFAULT 100 NOT NULL,
    "tier" "text" DEFAULT 'Trusted'::"text" NOT NULL
);


ALTER TABLE "public"."electrician_performance_snapshots" OWNER TO "postgres";

--
-- Name: refresh_electrician_performance_snapshot("uuid"); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."refresh_electrician_performance_snapshot"("p_electrician_id" "uuid") RETURNS "public"."electrician_performance_snapshots"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
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


ALTER FUNCTION "public"."refresh_electrician_performance_snapshot"("p_electrician_id" "uuid") OWNER TO "postgres";

--
-- Name: refresh_electrician_trust_metrics("uuid"); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."refresh_electrician_trust_metrics"("p_electrician_id" "uuid") RETURNS "public"."electricians"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
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


ALTER FUNCTION "public"."refresh_electrician_trust_metrics"("p_electrician_id" "uuid") OWNER TO "postgres";

--
-- Name: refresh_operational_alerts(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."refresh_operational_alerts"() RETURNS integer
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
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
      'Job snapshot differs from canonical event projection.',
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

  count_alerts := count_alerts + public.refresh_predictive_operational_alerts();

  update public.operational_alerts
  set severity = 'critical',
      metadata = metadata || jsonb_build_object('auto_escalated_at', now())
  where status = 'open'
    and severity = 'warning'
    and alert_type in ('stuck_pairing', 'expired_assignment', 'failed_pairing', 'snapshot_drift', 'predictive_pairing_risk', 'predictive_payment_backlog', 'automation_lag')
    and last_seen_at < now() - interval '10 minutes';

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


ALTER FUNCTION "public"."refresh_operational_alerts"() OWNER TO "postgres";

--
-- Name: refresh_predictive_operational_alerts(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."refresh_predictive_operational_alerts"() RETURNS integer
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  item record;
  count_alerts integer := 0;
begin
  if not (public.is_admin() or auth.role() = 'service_role') then
    raise exception 'Admin or service role required';
  end if;

  for item in select * from public.detect_predictive_operational_risks() loop
    perform public.upsert_operational_alert(
      item.alert_type,
      item.severity,
      item.reason,
      item.job_id,
      item.electrician_id,
      item.payment_id,
      null,
      null,
      item.metadata
    );
    count_alerts := count_alerts + 1;
  end loop;

  update public.operational_alerts a
  set status = 'resolved',
      resolved_at = coalesce(resolved_at, now()),
      metadata = metadata || jsonb_build_object('predictive_resolved_at', now())
  where status = 'open'
    and alert_type in ('predictive_pairing_risk', 'predictive_payment_backlog', 'automation_lag', 'projection_replay_due')
    and not exists (
      select 1
      from public.detect_predictive_operational_risks() risk
      where risk.alert_type = a.alert_type
        and risk.job_id is not distinct from a.job_id
        and risk.electrician_id is not distinct from a.electrician_id
        and risk.payment_id is not distinct from a.payment_id
    );

  return count_alerts;
end;
$$;


ALTER FUNCTION "public"."refresh_predictive_operational_alerts"() OWNER TO "postgres";

--
-- Name: replay_all_job_events(integer, "text"); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."replay_all_job_events"("p_limit" integer DEFAULT 100, "p_request_id" "text" DEFAULT NULL::"text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  clean_request_id text := public.sanitize_request_id(p_request_id);
  request_hash text := md5('replay_all_job_events:' || coalesce(p_limit, 100)::text);
  claim jsonb;
  run_id uuid;
  item record;
  replay_payload jsonb;
  v_processed_count integer := 0;
  v_conflict_count integer := 0;
  v_stale_count integer := 0;
  v_job_count integer := 0;
  payload jsonb;
begin
  if auth.role() <> 'service_role' then
    raise exception 'Service role required';
  end if;

  claim := public.claim_operation_request(clean_request_id, 'replay_all_job_events', request_hash);
  clean_request_id := claim ->> 'request_id';

  if coalesce((claim ->> 'claimed')::boolean, false) = false then
    if claim ->> 'status' = 'completed' then
      return coalesce(claim -> 'response_payload', '{}'::jsonb) || jsonb_build_object('replayed', true);
    end if;
    return jsonb_build_object('request_id', clean_request_id, 'processed', 0, 'status', claim ->> 'status', 'replayed', true);
  end if;

  insert into public.event_replay_runs (request_id, request_hash, replay_scope, status, metadata)
  values (clean_request_id, request_hash, 'bulk', 'running', jsonb_build_object('limit', coalesce(p_limit, 100), 'request_id', clean_request_id))
  returning id into run_id;

  for item in
    select j.id
    from public.jobs j
    where exists (
      select 1
      from public.job_events e
      where e.job_id = j.id
        and e.projected_status is not null
    )
    order by coalesce(j.snapshot_reconciled_at, to_timestamp(0)) asc, j.updated_at asc
    limit greatest(coalesce(p_limit, 100), 1)
  loop
    replay_payload := public.replay_job_events_internal(item.id, run_id, 'bulk-event-replay');
    v_job_count := v_job_count + 1;
    v_processed_count := v_processed_count + coalesce((replay_payload ->> 'processed_count')::integer, 0);
    v_conflict_count := v_conflict_count + coalesce((replay_payload ->> 'conflict_count')::integer, 0);
    v_stale_count := v_stale_count + coalesce((replay_payload ->> 'stale_rejected_count')::integer, 0);
  end loop;

  payload := jsonb_build_object(
    'request_id', clean_request_id,
    'run_id', run_id,
    'jobs_replayed', v_job_count,
    'processed_count', v_processed_count,
    'conflict_count', v_conflict_count,
    'stale_rejected_count', v_stale_count,
    'processed', v_processed_count + v_stale_count + v_conflict_count
  );

  update public.event_replay_runs
  set status = 'completed',
      finished_at = now(),
      processed_count = v_processed_count,
      conflict_count = v_conflict_count,
      stale_rejected_count = v_stale_count,
      metadata = metadata || payload
  where id = run_id;

  perform public.complete_operation_request(clean_request_id, 'completed', payload, null);
  return payload;
exception
  when others then
    if run_id is not null then
      update public.event_replay_runs
      set status = 'failed',
          finished_at = now(),
          error_message = sqlerrm,
          metadata = metadata || jsonb_build_object('sqlstate', sqlstate)
      where id = run_id;
    end if;
    if clean_request_id is not null then
      perform public.complete_operation_request(clean_request_id, 'failed', jsonb_build_object('request_id', clean_request_id), sqlerrm);
    end if;
    raise;
end;
$$;


ALTER FUNCTION "public"."replay_all_job_events"("p_limit" integer, "p_request_id" "text") OWNER TO "postgres";

--
-- Name: replay_job_events("uuid", "text"); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."replay_job_events"("p_job_id" "uuid", "p_request_id" "text" DEFAULT NULL::"text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  clean_request_id text := public.sanitize_request_id(p_request_id);
  request_hash text := md5('replay_job_events:' || coalesce(p_job_id::text, ''));
  claim jsonb;
  run_id uuid;
  replay_payload jsonb;
begin
  if auth.role() <> 'service_role' then
    raise exception 'Service role required';
  end if;

  claim := public.claim_operation_request(clean_request_id, 'replay_job_events', request_hash);
  clean_request_id := claim ->> 'request_id';

  if coalesce((claim ->> 'claimed')::boolean, false) = false then
    if claim ->> 'status' = 'completed' then
      return coalesce(claim -> 'response_payload', '{}'::jsonb) || jsonb_build_object('replayed', true);
    end if;
    return jsonb_build_object('request_id', clean_request_id, 'processed', 0, 'status', claim ->> 'status', 'replayed', true);
  end if;

  insert into public.event_replay_runs (request_id, request_hash, replay_scope, job_id, status, metadata)
  values (clean_request_id, request_hash, 'single', p_job_id, 'running', jsonb_build_object('request_id', clean_request_id))
  returning id into run_id;

  replay_payload := public.replay_job_events_internal(p_job_id, run_id, 'service-replay');

  update public.event_replay_runs
  set status = 'completed',
      finished_at = now(),
      processed_count = coalesce((replay_payload ->> 'processed_count')::integer, 0),
      conflict_count = coalesce((replay_payload ->> 'conflict_count')::integer, 0),
      stale_rejected_count = coalesce((replay_payload ->> 'stale_rejected_count')::integer, 0),
      metadata = metadata || replay_payload
  where id = run_id;

  replay_payload := replay_payload || jsonb_build_object('request_id', clean_request_id, 'run_id', run_id, 'processed', coalesce((replay_payload ->> 'processed_count')::integer, 0));
  perform public.complete_operation_request(clean_request_id, 'completed', replay_payload, null);
  return replay_payload;
exception
  when others then
    if run_id is not null then
      update public.event_replay_runs
      set status = 'failed',
          finished_at = now(),
          error_message = sqlerrm,
          metadata = metadata || jsonb_build_object('sqlstate', sqlstate)
      where id = run_id;
    end if;
    if clean_request_id is not null then
      perform public.complete_operation_request(clean_request_id, 'failed', jsonb_build_object('request_id', clean_request_id), sqlerrm);
    end if;
    raise;
end;
$$;


ALTER FUNCTION "public"."replay_job_events"("p_job_id" "uuid", "p_request_id" "text") OWNER TO "postgres";

--
-- Name: replay_job_events_internal("uuid", "uuid", "text"); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."replay_job_events_internal"("p_job_id" "uuid", "p_replay_run_id" "uuid" DEFAULT NULL::"uuid", "p_reason" "text" DEFAULT 'event-replay'::"text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  job_row public.jobs;
  event_row public.job_events;
  latest_status public.job_status;
  latest_event_id uuid;
  latest_sequence bigint := 0;
  latest_version integer := 0;
  processed_count integer := 0;
  conflict_count integer := 0;
  stale_count integer := 0;
begin
  if not (public.is_admin() or auth.role() = 'service_role') then
    raise exception 'Admin or service role required';
  end if;

  select * into job_row
  from public.jobs
  where id = p_job_id
  for update;

  if not found then
    raise exception 'Job not found';
  end if;

  delete from public.job_state_projections
  where job_id = p_job_id;

  for event_row in
    select *
    from public.job_events
    where job_id = p_job_id
    order by event_sequence asc, created_at asc
  loop
    processed_count := processed_count + 1;

    if event_row.projected_status is null then
      continue;
    end if;

    if coalesce(event_row.event_version, event_row.transition_to_version, 0) < latest_version
       or (
         coalesce(event_row.event_version, event_row.transition_to_version, 0) = latest_version
         and latest_status is not null
         and event_row.projected_status is distinct from latest_status
       ) then
      stale_count := stale_count + 1;
      continue;
    end if;

    if coalesce(event_row.event_version, event_row.transition_to_version, 0) = latest_version
       and latest_status is not null
       and event_row.event_sequence < latest_sequence then
      stale_count := stale_count + 1;
      continue;
    end if;

    latest_status := event_row.projected_status;
    latest_event_id := event_row.id;
    latest_sequence := event_row.event_sequence;
    latest_version := coalesce(event_row.event_version, event_row.transition_to_version, latest_version);

    insert into public.job_state_projections (
      job_id,
      projected_status,
      event_id,
      event_sequence,
      state_version,
      projected_at,
      snapshot_synced_at,
      metadata
    )
    values (
      p_job_id,
      event_row.projected_status,
      event_row.id,
      event_row.event_sequence,
      latest_version,
      now(),
      null,
      jsonb_build_object(
        'replayed', true,
        'replay_run_id', p_replay_run_id,
        'reason', coalesce(nullif(btrim(p_reason), ''), 'event-replay'),
        'transition_id', event_row.transition_id
      )
    )
    on conflict (job_id) do update
    set projected_status = excluded.projected_status,
        event_id = excluded.event_id,
        event_sequence = excluded.event_sequence,
        state_version = excluded.state_version,
        projected_at = excluded.projected_at,
        metadata = public.job_state_projections.metadata || excluded.metadata;

    update public.job_events
    set projected_at = coalesce(projected_at, now()),
        replay_run_id = coalesce(p_replay_run_id, replay_run_id)
    where id = event_row.id;
  end loop;

  if latest_status is null then
    update public.jobs
    set snapshot_reconciled_at = now()
    where id = p_job_id;
  else
    update public.jobs
    set status = latest_status,
        state_version = greatest(coalesce(state_version, 0), latest_version),
        snapshot_reconciled_at = now(),
        updated_at = now()
    where id = p_job_id;
  end if;

  if stale_count > 0 then
    perform public.upsert_operational_alert(
      'state_conflict',
      'warning',
      'Replay skipped stale projected events.',
      p_job_id,
      null,
      null,
      null,
      latest_event_id,
      jsonb_build_object(
        'stale_rejected_count', stale_count,
        'processed_count', processed_count,
        'replay_run_id', p_replay_run_id
      )
    );
  end if;

  return jsonb_build_object(
    'job_id', p_job_id,
    'latest_event_id', latest_event_id,
    'latest_status', latest_status,
    'latest_version', latest_version,
    'processed_count', processed_count,
    'conflict_count', conflict_count,
    'stale_rejected_count', stale_count
  );
end;
$$;


ALTER FUNCTION "public"."replay_job_events_internal"("p_job_id" "uuid", "p_replay_run_id" "uuid", "p_reason" "text") OWNER TO "postgres";

--
-- Name: request_guest_otp("uuid", "text", "text", "text", "text"); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."request_guest_otp"("p_job_id" "uuid", "p_access_token" "text", "p_action_type" "text", "p_phone_confirmation" "text", "p_client_fingerprint" "text" DEFAULT NULL::"text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  job_row public.jobs;
  guest_phone text;
  expected_last4 text;
  provided_last4 text;
  raw_code text;
  challenge_id uuid;
  expires timestamptz;
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


ALTER FUNCTION "public"."request_guest_otp"("p_job_id" "uuid", "p_access_token" "text", "p_action_type" "text", "p_phone_confirmation" "text", "p_client_fingerprint" "text") OWNER TO "postgres";

--
-- Name: resolve_dispute("uuid", "text", "text", "text"); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."resolve_dispute"("p_dispute_id" "uuid", "p_status" "text", "p_resolution_action" "text" DEFAULT NULL::"text", "p_resolution_note" "text" DEFAULT NULL::"text") RETURNS "public"."disputes"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
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


ALTER FUNCTION "public"."resolve_dispute"("p_dispute_id" "uuid", "p_status" "text", "p_resolution_action" "text", "p_resolution_note" "text") OWNER TO "postgres";

--
-- Name: electrician_appeals; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE "public"."electrician_appeals" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "electrician_id" "uuid" NOT NULL,
    "status" "text" DEFAULT 'open'::"text" NOT NULL,
    "appeal_note" "text" NOT NULL,
    "supporting_file_path" "text",
    "admin_note" "text",
    "reviewed_by" "uuid",
    "reviewed_at" timestamp with time zone,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "electrician_appeals_status_check" CHECK (("status" = ANY (ARRAY['open'::"text", 'approved'::"text", 'rejected'::"text"])))
);


ALTER TABLE "public"."electrician_appeals" OWNER TO "postgres";

--
-- Name: resolve_electrician_appeal("uuid", boolean, "text"); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."resolve_electrician_appeal"("p_appeal_id" "uuid", "p_approved" boolean, "p_admin_note" "text" DEFAULT NULL::"text") RETURNS "public"."electrician_appeals"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
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


ALTER FUNCTION "public"."resolve_electrician_appeal"("p_appeal_id" "uuid", "p_approved" boolean, "p_admin_note" "text") OWNER TO "postgres";

--
-- Name: reward_completed_referral("uuid", "uuid"); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."reward_completed_referral"("p_referred_profile_id" "uuid", "p_job_id" "uuid") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
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


ALTER FUNCTION "public"."reward_completed_referral"("p_referred_profile_id" "uuid", "p_job_id" "uuid") OWNER TO "postgres";

--
-- Name: run_operational_automation(integer, "text"); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."run_operational_automation"("p_limit" integer DEFAULT 100, "p_request_id" "text" DEFAULT NULL::"text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  clean_request_id text := public.sanitize_request_id(p_request_id);
  request_hash text := md5('run_operational_automation:' || coalesce(p_limit, 100)::text);
  claim jsonb;
  run_id uuid;
  replay_payload jsonb := '{}'::jsonb;
  replay_count integer := 0;
  rebuilt_count integer := 0;
  prioritized_count integer := 0;
  synced_count integer := 0;
  dispatch_count integer := 0;
  alert_count integer := 0;
  escalated_count integer := 0;
  cooldown_count integer := 0;
  resolved_count integer := 0;
  total_count integer := 0;
  health_snapshot public.system_health_snapshots;
  payload jsonb;
begin
  if auth.role() <> 'service_role' then
    raise exception 'Service role required';
  end if;

  claim := public.claim_operation_request(clean_request_id, 'run_operational_automation', request_hash);
  clean_request_id := claim ->> 'request_id';

  if coalesce((claim ->> 'claimed')::boolean, false) = false then
    if claim ->> 'status' = 'completed' then
      return coalesce(claim -> 'response_payload', '{}'::jsonb) || jsonb_build_object('replayed', true);
    end if;

    return jsonb_build_object(
      'request_id', clean_request_id,
      'processed', 0,
      'status', claim ->> 'status',
      'replayed', true
    );
  end if;

  insert into public.operational_automation_runs (run_type, status, request_id, request_hash, metadata)
  values (
    'dispatch_heartbeat',
    'running',
    clean_request_id,
    request_hash,
    jsonb_build_object('limit', coalesce(p_limit, 100), 'request_id', clean_request_id)
  )
  returning id into run_id;

  replay_payload := public.replay_all_job_events(
    least(greatest(coalesce(p_limit, 100), 1), 25),
    clean_request_id || ':event-replay'
  );
  replay_count := coalesce((replay_payload ->> 'processed')::integer, 0);

  rebuilt_count := public.rebuild_all_job_state_projections(greatest(least(coalesce(p_limit, 100), 500), 1));
  cooldown_count := public.apply_electrician_reliability_cooldowns(greatest(least(coalesce(p_limit, 100), 200), 1));
  prioritized_count := public.prioritize_dispatch_queue(greatest(least(coalesce(p_limit, 100) * 2, 500), 1));
  synced_count := public.sync_all_job_state_projections(greatest(coalesce(p_limit, 100), 1));
  dispatch_count := public.process_dispatch_queue();
  alert_count := public.refresh_operational_alerts();
  escalated_count := public.apply_operational_escalations();
  health_snapshot := public.capture_system_health_snapshot('automation');

  update public.operational_alerts a
  set status = 'resolved',
      resolved_at = coalesce(resolved_at, now()),
      metadata = metadata || jsonb_build_object('automation_resolved_at', now())
  where status = 'open'
    and alert_type = 'snapshot_drift'
    and not exists (
      select 1 from public.detect_snapshot_drift() drift where drift.job_id = a.job_id
    );
  get diagnostics resolved_count = row_count;

  total_count := replay_count + rebuilt_count + cooldown_count + prioritized_count + synced_count + dispatch_count + alert_count + escalated_count + resolved_count;

  payload := jsonb_build_object(
    'request_id', clean_request_id,
    'run_id', run_id,
    'event_replay', replay_payload,
    'event_replay_processed', replay_count,
    'projection_rebuilds', rebuilt_count,
    'electrician_cooldowns', cooldown_count,
    'queue_prioritized', prioritized_count,
    'projection_syncs', synced_count,
    'dispatch_actions', dispatch_count,
    'alerts_refreshed', alert_count,
    'alerts_escalated', escalated_count,
    'alerts_resolved', resolved_count,
    'health_snapshot_id', health_snapshot.id,
    'processed', total_count
  );

  update public.operational_automation_runs
  set status = 'completed',
      finished_at = now(),
      processed_count = total_count,
      metadata = metadata || payload
  where id = run_id;

  perform public.complete_operation_request(clean_request_id, 'completed', payload, null);
  return payload;
exception
  when others then
    if clean_request_id is not null then
      perform public.complete_operation_request(
        clean_request_id,
        'failed',
        jsonb_build_object('request_id', clean_request_id),
        sqlerrm
      );
    end if;
    if run_id is not null then
      update public.operational_automation_runs
      set status = 'failed',
          finished_at = now(),
          error_message = sqlerrm,
          metadata = metadata || jsonb_build_object('sqlstate', sqlstate)
      where id = run_id;
    end if;
    raise;
end;
$$;


ALTER FUNCTION "public"."run_operational_automation"("p_limit" integer, "p_request_id" "text") OWNER TO "postgres";

--
-- Name: run_operational_recovery(integer, "text"); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."run_operational_recovery"("p_limit" integer DEFAULT 500, "p_request_id" "text" DEFAULT NULL::"text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  clean_request_id text := public.sanitize_request_id(p_request_id);
  request_hash text := md5('run_operational_recovery:' || coalesce(p_limit, 500)::text);
  claim jsonb;
  replay_payload jsonb := '{}'::jsonb;
  rebuilt_count integer := 0;
  automation_payload jsonb;
  payload jsonb;
begin
  if auth.role() <> 'service_role' then
    raise exception 'Service role required';
  end if;

  claim := public.claim_operation_request(clean_request_id, 'run_operational_recovery', request_hash);
  clean_request_id := claim ->> 'request_id';

  if coalesce((claim ->> 'claimed')::boolean, false) = false then
    if claim ->> 'status' = 'completed' then
      return coalesce(claim -> 'response_payload', '{}'::jsonb) || jsonb_build_object('replayed', true);
    end if;

    return jsonb_build_object(
      'request_id', clean_request_id,
      'processed', 0,
      'status', claim ->> 'status',
      'replayed', true
    );
  end if;

  update public.operation_requests
  set status = 'failed',
      updated_at = now(),
      error_message = 'Recovered stale running request'
  where status = 'running'
    and request_id <> clean_request_id
    and updated_at < now() - interval '10 minutes';

  replay_payload := public.replay_all_job_events(
    least(greatest(coalesce(p_limit, 500), 1), 250),
    clean_request_id || ':event-replay'
  );
  rebuilt_count := public.rebuild_all_job_state_projections(greatest(coalesce(p_limit, 500), 1));
  automation_payload := public.run_operational_automation(
    least(greatest(coalesce(p_limit, 500), 1), 500),
    clean_request_id || ':automation'
  );

  payload := jsonb_build_object(
    'request_id', clean_request_id,
    'event_replay', replay_payload,
    'projection_rebuilds', rebuilt_count,
    'automation', automation_payload,
    'processed',
      rebuilt_count
      + coalesce((replay_payload ->> 'processed')::integer, 0)
      + coalesce((automation_payload ->> 'processed')::integer, 0)
  );

  perform public.complete_operation_request(clean_request_id, 'completed', payload, null);
  return payload;
exception
  when others then
    if clean_request_id is not null then
      perform public.complete_operation_request(
        clean_request_id,
        'failed',
        jsonb_build_object('request_id', clean_request_id),
        sqlerrm
      );
    end if;
    raise;
end;
$$;


ALTER FUNCTION "public"."run_operational_recovery"("p_limit" integer, "p_request_id" "text") OWNER TO "postgres";

--
-- Name: sanitize_request_id("text"); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."sanitize_request_id"("p_request_id" "text") RETURNS "text"
    LANGUAGE "sql" IMMUTABLE
    SET "search_path" TO 'public'
    AS $$
  select nullif(left(regexp_replace(coalesce(p_request_id, ''), '[^a-zA-Z0-9:_\\.-]', '', 'g'), 160), '');
$$;


ALTER FUNCTION "public"."sanitize_request_id"("p_request_id" "text") OWNER TO "postgres";

--
-- Name: set_job_status("uuid", "public"."job_status", "text", "jsonb"); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."set_job_status"("p_job_id" "uuid", "p_next_status" "public"."job_status", "p_note" "text" DEFAULT NULL::"text", "p_metadata" "jsonb" DEFAULT '{}'::"jsonb") RETURNS "public"."jobs"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  job_row public.jobs;
  actor_metadata jsonb := coalesce(p_metadata, '{}'::jsonb);
  actor_customer_id uuid := public.current_customer_id();
  actor_electrician_id uuid := public.current_electrician_id();
  is_admin_actor boolean := public.is_admin();
  actor_role_value text;
begin
  select * into job_row from public.jobs where id = p_job_id;
  if not found then
    raise exception 'Job not found';
  end if;

  if is_admin_actor then
    actor_role_value := 'admin';
    actor_metadata := actor_metadata || jsonb_build_object('admin_override', true);
  elsif job_row.customer_id = actor_customer_id then
    actor_role_value := 'customer';
  elsif job_row.assigned_electrician_id = actor_electrician_id then
    actor_role_value := 'electrician';
  else
    raise exception 'You do not have permission to update this job';
  end if;

  return public.transition_job_state(
    p_job_id,
    p_next_status,
    actor_role_value,
    auth.uid(),
    p_note,
    p_note,
    actor_metadata,
    null,
    null
  );
end;
$$;


ALTER FUNCTION "public"."set_job_status"("p_job_id" "uuid", "p_next_status" "public"."job_status", "p_note" "text", "p_metadata" "jsonb") OWNER TO "postgres";

--
-- Name: ratings; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE "public"."ratings" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "job_id" "uuid" NOT NULL,
    "customer_id" "uuid" NOT NULL,
    "electrician_id" "uuid" NOT NULL,
    "score" integer NOT NULL,
    "comment" "text",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "review_direction" "text" DEFAULT 'customer_to_electrician'::"text" NOT NULL,
    "reviewer_profile_id" "uuid",
    "reviewee_profile_id" "uuid",
    "reviewee_role" "public"."user_role",
    "behavior_tags" "text"[] DEFAULT '{}'::"text"[] NOT NULL,
    CONSTRAINT "ratings_score_check" CHECK ((("score" >= 1) AND ("score" <= 5)))
);


ALTER TABLE "public"."ratings" OWNER TO "postgres";

--
-- Name: submit_customer_review("uuid", integer, "text", "text"[]); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."submit_customer_review"("p_job_id" "uuid", "p_score" integer, "p_comment" "text" DEFAULT NULL::"text", "p_behavior_tags" "text"[] DEFAULT '{}'::"text"[]) RETURNS "public"."ratings"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
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


ALTER FUNCTION "public"."submit_customer_review"("p_job_id" "uuid", "p_score" integer, "p_comment" "text", "p_behavior_tags" "text"[]) OWNER TO "postgres";

--
-- Name: submit_electrician_appeal("text", "text"); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."submit_electrician_appeal"("p_appeal_note" "text", "p_supporting_file_path" "text" DEFAULT NULL::"text") RETURNS "public"."electrician_appeals"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
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


ALTER FUNCTION "public"."submit_electrician_appeal"("p_appeal_note" "text", "p_supporting_file_path" "text") OWNER TO "postgres";

--
-- Name: job_payments; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE "public"."job_payments" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "job_id" "uuid" NOT NULL,
    "submitted_by" "uuid",
    "payment_type" "public"."payment_type" NOT NULL,
    "amount" numeric(12,2) DEFAULT 0 NOT NULL,
    "proof_path" "text",
    "reference" "text",
    "status" "public"."payment_status" DEFAULT 'submitted'::"public"."payment_status" NOT NULL,
    "admin_note" "text",
    "verified_by" "uuid",
    "verified_at" timestamp with time zone,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "guest_customer_id" "uuid"
);


ALTER TABLE "public"."job_payments" OWNER TO "postgres";

--
-- Name: submit_guest_payment_proof("uuid", "text", "public"."payment_type", numeric, "text", "text", "text", "text"); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."submit_guest_payment_proof"("p_job_id" "uuid", "p_access_token" "text", "p_payment_type" "public"."payment_type", "p_amount" numeric, "p_reference" "text", "p_proof_path" "text", "p_phone_confirmation" "text" DEFAULT NULL::"text", "p_action_token" "text" DEFAULT NULL::"text") RETURNS "public"."job_payments"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
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

  if job_row.created_at < now() - interval '30 days' then
    raise exception 'This guest payment link has expired. Contact VoltFriq support to continue.';
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

  perform public.consume_guest_action_token(p_job_id, 'payment_proof', p_action_token);

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


ALTER FUNCTION "public"."submit_guest_payment_proof"("p_job_id" "uuid", "p_access_token" "text", "p_payment_type" "public"."payment_type", "p_amount" numeric, "p_reference" "text", "p_proof_path" "text", "p_phone_confirmation" "text", "p_action_token" "text") OWNER TO "postgres";

--
-- Name: job_quotes; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE "public"."job_quotes" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "job_id" "uuid" NOT NULL,
    "electrician_id" "uuid" NOT NULL,
    "findings" "text",
    "measurements" "text",
    "labor_total" numeric(12,2) DEFAULT 0 NOT NULL,
    "material_total" numeric(12,2) DEFAULT 0 NOT NULL,
    "grand_total" numeric(12,2) DEFAULT 0 NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."job_quotes" OWNER TO "postgres";

--
-- Name: submit_job_quote("uuid", "text", "text", "jsonb"); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."submit_job_quote"("p_job_id" "uuid", "p_findings" "text", "p_measurements" "text", "p_items" "jsonb") RETURNS "public"."job_quotes"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  electrician_row public.electricians;
  job_row public.jobs;
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

  select * into job_row
  from public.jobs
  where id = p_job_id
  for update;

  if not found then
    raise exception 'Job not found';
  end if;

  if job_row.assigned_electrician_id is distinct from electrician_row.id then
    raise exception 'You can only quote jobs assigned to you';
  end if;

  if not (
    job_row.status = 'on_site'
    or (job_row.status = 'accepted' and not job_row.requires_assessment)
  ) then
    raise exception 'Quotes can only be submitted after arrival on site or after remote acceptance for non-assessment jobs';
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


ALTER FUNCTION "public"."submit_job_quote"("p_job_id" "uuid", "p_findings" "text", "p_measurements" "text", "p_items" "jsonb") OWNER TO "postgres";

--
-- Name: submit_payment_proof("uuid", "public"."payment_type", numeric, "text", "text"); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."submit_payment_proof"("p_job_id" "uuid", "p_payment_type" "public"."payment_type", "p_amount" numeric, "p_reference" "text", "p_proof_path" "text") RETURNS "public"."job_payments"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  customer_row public.customers;
  job_row public.jobs;
  payment_row public.job_payments;
  next_status job_status;
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
  for update;

  if not found then
    raise exception 'Job not found';
  end if;

  if job_row.customer_id is distinct from customer_row.id then
    raise exception 'You can only submit payment proof for your own job';
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
    raise exception 'Unsupported payment type for customer submission';
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

  insert into public.job_payments (job_id, submitted_by, payment_type, amount, proof_path, reference)
  values (p_job_id, auth.uid(), p_payment_type, coalesce(p_amount, 0), p_proof_path, p_reference)
  returning * into payment_row;

  update public.jobs
  set status = next_status
  where id = p_job_id;

  perform public.append_job_timeline(p_job_id, next_status, 'Payment proof submitted for manual verification.', auth.uid());
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


ALTER FUNCTION "public"."submit_payment_proof"("p_job_id" "uuid", "p_payment_type" "public"."payment_type", "p_amount" numeric, "p_reference" "text", "p_proof_path" "text") OWNER TO "postgres";

--
-- Name: submit_rating("uuid", integer, "text", "text"[]); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."submit_rating"("p_job_id" "uuid", "p_score" integer, "p_comment" "text" DEFAULT NULL::"text", "p_behavior_tags" "text"[] DEFAULT '{}'::"text"[]) RETURNS "public"."ratings"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
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

  if job_row.status <> 'payout_complete' then
    raise exception 'Ratings open after admin closeout is complete';
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


ALTER FUNCTION "public"."submit_rating"("p_job_id" "uuid", "p_score" integer, "p_comment" "text", "p_behavior_tags" "text"[]) OWNER TO "postgres";

--
-- Name: sync_all_job_state_projections(integer); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."sync_all_job_state_projections"("p_limit" integer DEFAULT 100) RETURNS integer
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  item record;
  synced_count integer := 0;
begin
  for item in
    select j.id
    from public.jobs j
    left join public.job_state_projections p on p.job_id = j.id
    where j.status not in ('rated', 'cancelled')
       or p.snapshot_synced_at is null
       or p.snapshot_synced_at < p.projected_at
    order by coalesce(p.snapshot_synced_at, to_timestamp(0)) asc, j.updated_at asc
    limit greatest(coalesce(p_limit, 100), 1)
  loop
    perform public.sync_job_state_projection(item.id, 'automation-projection-sync');
    synced_count := synced_count + 1;
  end loop;

  return synced_count;
end;
$$;


ALTER FUNCTION "public"."sync_all_job_state_projections"("p_limit" integer) OWNER TO "postgres";

--
-- Name: sync_app_account_for_auth_user("uuid"); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."sync_app_account_for_auth_user"("p_user_id" "uuid") RETURNS "public"."profiles"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $_$
declare
  user_row auth.users;
  existing_role public.user_role;
  user_metadata_role text;
  app_metadata_role text;
  profile_role public.user_role;
  profile_row public.profiles;
  customer_phone text;
  location_label text;
  lat_raw text;
  lng_raw text;
  years_raw text;
  score_raw text;
  parsed_latitude double precision;
  parsed_longitude double precision;
  parsed_years integer;
  parsed_score numeric;
  service_areas text[] := '{}'::text[];
  onboarding_answers jsonb := '[]'::jsonb;
begin
  select * into user_row from auth.users where id = p_user_id;
  if not found then
    raise exception 'Auth user % does not exist', p_user_id;
  end if;

  select role into existing_role
  from public.profiles
  where id = user_row.id;

  user_metadata_role := lower(nullif(coalesce(
    user_row.raw_user_meta_data ->> 'requested_role',
    user_row.raw_user_meta_data ->> 'role'
  ), ''));
  app_metadata_role := lower(nullif(coalesce(
    user_row.raw_app_meta_data ->> 'role',
    user_row.raw_app_meta_data ->> 'app_role'
  ), ''));

  profile_role := case
    when existing_role = 'admin' or app_metadata_role = 'admin' then 'admin'::public.user_role
    when existing_role = 'electrician'
      or user_metadata_role in ('electrician', 'voltfriq', 'volt_friq', 'volt-friq')
      or app_metadata_role in ('electrician', 'voltfriq', 'volt_friq', 'volt-friq')
      then 'electrician'::public.user_role
    else 'customer'::public.user_role
  end;

  customer_phone := nullif(user_row.raw_user_meta_data ->> 'phone', '');
  location_label := coalesce(
    nullif(user_row.raw_user_meta_data ->> 'location_label', ''),
    nullif(user_row.raw_user_meta_data ->> 'base_location_label', ''),
    nullif(user_row.raw_user_meta_data ->> 'primary_service_area', ''),
    nullif(user_row.raw_user_meta_data ->> 'service_area', '')
  );
  lat_raw := nullif(coalesce(user_row.raw_user_meta_data ->> 'latitude', user_row.raw_user_meta_data ->> 'lat'), '');
  lng_raw := nullif(coalesce(user_row.raw_user_meta_data ->> 'longitude', user_row.raw_user_meta_data ->> 'lng'), '');
  years_raw := nullif(user_row.raw_user_meta_data ->> 'years_experience', '');
  score_raw := nullif(user_row.raw_user_meta_data ->> 'onboarding_score', '');

  if lat_raw ~ '^-?[0-9]+(\.[0-9]+)?$' then
    parsed_latitude := lat_raw::double precision;
  end if;

  if lng_raw ~ '^-?[0-9]+(\.[0-9]+)?$' then
    parsed_longitude := lng_raw::double precision;
  end if;

  if years_raw ~ '^[0-9]+$' then
    parsed_years := years_raw::integer;
  end if;

  if score_raw ~ '^-?[0-9]+(\.[0-9]+)?$' then
    parsed_score := score_raw::numeric;
  end if;

  if jsonb_typeof(user_row.raw_user_meta_data -> 'service_areas') = 'array' then
    select coalesce(array_agg(value), '{}'::text[])
    into service_areas
    from jsonb_array_elements_text(user_row.raw_user_meta_data -> 'service_areas') as area(value)
    where nullif(value, '') is not null;
  elsif nullif(user_row.raw_user_meta_data ->> 'primary_service_area', '') is not null then
    service_areas := array[user_row.raw_user_meta_data ->> 'primary_service_area'];
  elsif nullif(user_row.raw_user_meta_data ->> 'service_area', '') is not null then
    service_areas := array[user_row.raw_user_meta_data ->> 'service_area'];
  end if;

  if jsonb_typeof(user_row.raw_user_meta_data -> 'onboarding_answers') = 'array' then
    onboarding_answers := user_row.raw_user_meta_data -> 'onboarding_answers';
  end if;

  insert into public.profiles (id, email, role, full_name, phone)
  values (
    user_row.id,
    coalesce(user_row.email, ''),
    profile_role,
    coalesce(nullif(user_row.raw_user_meta_data ->> 'full_name', ''), user_row.email, ''),
    customer_phone
  )
  on conflict (id) do update
    set email = coalesce(nullif(excluded.email, ''), public.profiles.email),
        role = case
          when public.profiles.role = 'admin' then 'admin'::public.user_role
          else excluded.role
        end,
        full_name = coalesce(nullif(excluded.full_name, ''), nullif(public.profiles.full_name, ''), user_row.email, ''),
        phone = coalesce(nullif(excluded.phone, ''), public.profiles.phone)
  returning * into profile_row;

  if profile_role = 'customer' then
    insert into public.customers (profile_id, phone, location_label, primary_service_area, latitude, longitude)
    values (
      user_row.id,
      coalesce(customer_phone, profile_row.phone),
      location_label,
      coalesce(location_label, nullif(user_row.raw_user_meta_data ->> 'primary_service_area', '')),
      parsed_latitude,
      parsed_longitude
    )
    on conflict (profile_id) do update
      set phone = coalesce(excluded.phone, public.customers.phone),
          location_label = coalesce(excluded.location_label, public.customers.location_label),
          primary_service_area = coalesce(excluded.primary_service_area, public.customers.primary_service_area),
          latitude = coalesce(excluded.latitude, public.customers.latitude),
          longitude = coalesce(excluded.longitude, public.customers.longitude);
  elsif profile_role = 'electrician' then
    insert into public.electricians (
      profile_id,
      status,
      onboarding_completed,
      years_experience,
      service_areas,
      location_label,
      latitude,
      longitude,
      bank_name,
      bank_account_number,
      bank_account_name,
      availability_status,
      onboarding_score,
      onboarding_review_status,
      onboarding_feedback,
      onboarding_answers
    )
    values (
      user_row.id,
      'pending',
      false,
      coalesce(parsed_years, 0),
      service_areas,
      location_label,
      parsed_latitude,
      parsed_longitude,
      coalesce(nullif(user_row.raw_user_meta_data ->> 'bank_name', ''), ''),
      coalesce(nullif(user_row.raw_user_meta_data ->> 'bank_account_number', ''), ''),
      coalesce(nullif(user_row.raw_user_meta_data ->> 'bank_account_name', ''), ''),
      coalesce(nullif(user_row.raw_user_meta_data ->> 'availability_status', ''), 'available'),
      coalesce(parsed_score, 0),
      coalesce(nullif(user_row.raw_user_meta_data ->> 'onboarding_review_status', ''), 'pending'),
      nullif(user_row.raw_user_meta_data ->> 'onboarding_feedback', ''),
      onboarding_answers
    )
    on conflict (profile_id) do update
      set years_experience = greatest(public.electricians.years_experience, excluded.years_experience),
          service_areas = case
            when array_length(excluded.service_areas, 1) is not null then excluded.service_areas
            else public.electricians.service_areas
          end,
          location_label = coalesce(excluded.location_label, public.electricians.location_label),
          latitude = coalesce(excluded.latitude, public.electricians.latitude),
          longitude = coalesce(excluded.longitude, public.electricians.longitude),
          bank_name = coalesce(nullif(excluded.bank_name, ''), public.electricians.bank_name),
          bank_account_number = coalesce(nullif(excluded.bank_account_number, ''), public.electricians.bank_account_number),
          bank_account_name = coalesce(nullif(excluded.bank_account_name, ''), public.electricians.bank_account_name),
          availability_status = coalesce(nullif(excluded.availability_status, ''), public.electricians.availability_status),
          onboarding_score = greatest(public.electricians.onboarding_score, excluded.onboarding_score),
          onboarding_review_status = coalesce(nullif(excluded.onboarding_review_status, ''), public.electricians.onboarding_review_status),
          onboarding_feedback = coalesce(excluded.onboarding_feedback, public.electricians.onboarding_feedback),
          onboarding_answers = case
            when jsonb_array_length(excluded.onboarding_answers) > 0 then excluded.onboarding_answers
            else public.electricians.onboarding_answers
          end;
  end if;

  return profile_row;
end;
$_$;


ALTER FUNCTION "public"."sync_app_account_for_auth_user"("p_user_id" "uuid") OWNER TO "postgres";

--
-- Name: sync_electrician_reliability_aliases(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."sync_electrician_reliability_aliases"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    SET "search_path" TO 'public'
    AS $$
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


ALTER FUNCTION "public"."sync_electrician_reliability_aliases"() OWNER TO "postgres";

--
-- Name: sync_electrician_snapshot_reliability_aliases(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."sync_electrician_snapshot_reliability_aliases"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    SET "search_path" TO 'public'
    AS $$
begin
  new.reliability_score := coalesce(nullif(new.score, 0), new.reliability_score, 100);
  new.tier := coalesce(nullif(new.quality_tier, ''), new.tier, 'Trusted');
  return new;
end;
$$;


ALTER FUNCTION "public"."sync_electrician_snapshot_reliability_aliases"() OWNER TO "postgres";

--
-- Name: sync_job_event_payload(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."sync_job_event_payload"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
begin
  if coalesce(new.metadata, '{}'::jsonb) = '{}'::jsonb
     and coalesce(new.payload, '{}'::jsonb) <> '{}'::jsonb then
    new.metadata := new.payload;
  end if;

  new.payload := coalesce(new.metadata, new.payload, '{}'::jsonb);
  return new;
end;
$$;


ALTER FUNCTION "public"."sync_job_event_payload"() OWNER TO "postgres";

--
-- Name: sync_job_state_projection("uuid", "text"); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."sync_job_state_projection"("p_job_id" "uuid", "p_reason" "text" DEFAULT 'projection-sync'::"text") RETURNS "public"."jobs"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  job_row public.jobs;
  projection_row public.job_state_projections;
  synced_row public.jobs;
begin
  select * into job_row
  from public.jobs
  where id = p_job_id
  for update;

  if not found then
    raise exception 'Job not found';
  end if;

  select * into projection_row
  from public.job_state_projections
  where job_id = p_job_id;

  if not found then
    update public.jobs
    set snapshot_reconciled_at = now()
    where id = p_job_id
    returning * into synced_row;
    return synced_row;
  end if;

  if job_row.status is distinct from projection_row.projected_status
     or coalesce(job_row.state_version, 0) < coalesce(projection_row.state_version, 0) then
    update public.jobs
    set status = projection_row.projected_status,
        state_version = greatest(coalesce(state_version, 0), coalesce(projection_row.state_version, 0)),
        snapshot_reconciled_at = now(),
        updated_at = now()
    where id = p_job_id
    returning * into synced_row;

    update public.job_state_projections
    set snapshot_synced_at = now(),
        conflict_count = conflict_count + case when job_row.status is distinct from projection_row.projected_status then 1 else 0 end,
        metadata = metadata || jsonb_build_object(
          'last_sync_reason', coalesce(nullif(btrim(p_reason), ''), 'projection-sync'),
          'previous_snapshot_status', job_row.status,
          'synced_at', now()
        )
    where job_id = p_job_id;

    perform public.upsert_operational_alert(
      'snapshot_drift',
      'warning',
      'Job snapshot was synced from canonical event projection.',
      p_job_id,
      null,
      null,
      null,
      projection_row.event_id,
      jsonb_build_object(
        'snapshot_status', job_row.status,
        'projected_status', projection_row.projected_status,
        'snapshot_version', job_row.state_version,
        'projection_version', projection_row.state_version,
        'reason', coalesce(nullif(btrim(p_reason), ''), 'projection-sync')
      )
    );

    return synced_row;
  end if;

  update public.jobs
  set snapshot_reconciled_at = now()
  where id = p_job_id
  returning * into synced_row;

  update public.job_state_projections
  set snapshot_synced_at = now()
  where job_id = p_job_id;

  return synced_row;
end;
$$;


ALTER FUNCTION "public"."sync_job_state_projection"("p_job_id" "uuid", "p_reason" "text") OWNER TO "postgres";

--
-- Name: touch_updated_at(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."touch_updated_at"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
begin
  new.updated_at = now();
  return new;
end;
$$;


ALTER FUNCTION "public"."touch_updated_at"() OWNER TO "postgres";

--
-- Name: transition_job_state("uuid", "public"."job_status", "text", "uuid", "text", "text", "jsonb", "public"."job_status", "text"); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."transition_job_state"("p_job_id" "uuid", "p_next_status" "public"."job_status", "p_actor_role" "text", "p_actor_id" "uuid" DEFAULT "auth"."uid"(), "p_public_note" "text" DEFAULT NULL::"text", "p_internal_note" "text" DEFAULT NULL::"text", "p_metadata" "jsonb" DEFAULT '{}'::"jsonb", "p_expected_status" "public"."job_status" DEFAULT NULL::"public"."job_status", "p_idempotency_key" "text" DEFAULT NULL::"text") RETURNS "public"."jobs"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $_$
declare
  job_row public.jobs;
  updated_row public.jobs;
  expected_status_value public.job_status;
  expected_state_version integer;
  metadata_value jsonb := coalesce(p_metadata, '{}'::jsonb);
  event_type_value text;
  event_key text;
  existing_event uuid;
  admin_actor boolean := lower(coalesce(p_actor_role, '')) = 'admin' or public.is_admin() or auth.role() = 'service_role';
begin
  select * into job_row
  from public.jobs
  where id = p_job_id
  for update;

  if not found then
    raise exception 'Job not found';
  end if;

  event_key := nullif(btrim(coalesce(p_idempotency_key, metadata_value ->> 'idempotency_key', '')), '');
  if event_key is not null then
    select id into existing_event
    from public.job_events
    where idempotency_key = event_key;

    if existing_event is not null then
      return job_row;
    end if;
  end if;

  if metadata_value ->> 'expected_state_version' ~ '^[0-9]+$' then
    expected_state_version := (metadata_value ->> 'expected_state_version')::integer;
    if expected_state_version <> coalesce(job_row.state_version, 0) then
      perform public.upsert_operational_alert(
        'state_conflict',
        'warning',
        'Stale job state transition blocked by version guard.',
        p_job_id,
        null,
        null,
        null,
        null,
        jsonb_build_object(
          'expected_state_version', expected_state_version,
          'actual_state_version', coalesce(job_row.state_version, 0),
          'next_status', p_next_status,
          'actor_role', p_actor_role
        )
      );
      raise exception 'This job changed from version % to %. Refresh and try again.',
        expected_state_version,
        coalesce(job_row.state_version, 0);
    end if;
  end if;

  if p_next_status = job_row.status then
    return job_row;
  end if;

  expected_status_value := p_expected_status;
  if expected_status_value is null and metadata_value ->> 'expected_status' in (
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
  ) then
    expected_status_value := (metadata_value ->> 'expected_status')::public.job_status;
  end if;

  if expected_status_value is not null and job_row.status <> expected_status_value then
    perform public.upsert_operational_alert(
      'state_conflict',
      'warning',
      'Stale job status write blocked.',
      p_job_id,
      null,
      null,
      null,
      null,
      jsonb_build_object(
        'expected_status', expected_status_value,
        'actual_status', job_row.status,
        'next_status', p_next_status,
        'actor_role', p_actor_role
      )
    );
    raise exception 'This job changed from % to %. Refresh and try again.', expected_status_value, job_row.status;
  end if;

  if not public.is_valid_job_transition(job_row.status, p_next_status, p_actor_role, admin_actor, metadata_value) then
    perform public.upsert_operational_alert(
      'state_conflict',
      'critical',
      'Invalid job status transition blocked.',
      p_job_id,
      null,
      null,
      null,
      null,
      jsonb_build_object(
        'current_status', job_row.status,
        'next_status', p_next_status,
        'actor_role', p_actor_role
      )
    );
    raise exception 'Invalid job transition from % to %', job_row.status, p_next_status;
  end if;

  update public.jobs
  set status = p_next_status,
      state_version = coalesce(state_version, 0) + 1,
      accepted_at = case when p_next_status in ('accepted', 'assessment_fee_pending') then coalesce(accepted_at, now()) else accepted_at end,
      assignment_expires_at = case when p_next_status in ('accepted', 'assessment_fee_pending', 'matching', 'cancelled') then null else assignment_expires_at end,
      customer_confirmed_at = case when p_next_status = 'customer_confirmed' then coalesce(customer_confirmed_at, now()) else customer_confirmed_at end,
      electrician_completed_at = case when p_next_status = 'electrician_completed' then coalesce(electrician_completed_at, now()) else electrician_completed_at end,
      payout_released_at = case when p_next_status = 'payout_complete' then coalesce(payout_released_at, now()) else payout_released_at end,
      updated_at = now()
  where id = p_job_id
  returning * into updated_row;

  event_type_value := public.job_event_type_for_status(p_next_status);

  perform public.log_job_event(
    p_job_id,
    event_type_value,
    p_actor_role,
    p_actor_id,
    public.public_message_for_job_event(event_type_value, p_next_status, p_public_note),
    p_internal_note,
    (metadata_value - 'expected_status' - 'expected_state_version' - 'idempotency_key') ||
      jsonb_build_object(
        'previous_status', job_row.status,
        'next_status', p_next_status,
        'previous_state_version', coalesce(job_row.state_version, 0),
        'state_version', updated_row.state_version,
        'source', coalesce(nullif(metadata_value ->> 'source', ''), 'state_transition'),
        'idempotency_key', coalesce(event_key, 'state:' || p_job_id::text || ':' || updated_row.state_version::text || ':' || p_next_status::text)
      )
  );

  return updated_row;
end;
$_$;


ALTER FUNCTION "public"."transition_job_state"("p_job_id" "uuid", "p_next_status" "public"."job_status", "p_actor_role" "text", "p_actor_id" "uuid", "p_public_note" "text", "p_internal_note" "text", "p_metadata" "jsonb", "p_expected_status" "public"."job_status", "p_idempotency_key" "text") OWNER TO "postgres";

--
-- Name: update_guest_job_status("uuid", "text", "public"."job_status", "text", "jsonb", "text"); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."update_guest_job_status"("p_job_id" "uuid", "p_access_token" "text", "p_next_status" "public"."job_status", "p_note" "text" DEFAULT NULL::"text", "p_metadata" "jsonb" DEFAULT '{}'::"jsonb", "p_action_token" "text" DEFAULT NULL::"text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  job_row public.jobs;
  safe_metadata jsonb;
begin
  select * into job_row
  from public.jobs
  where id = p_job_id
    and customer_access_token = p_access_token
    and guest_customer_id is not null;

  if not found then
    raise exception 'Guest job not found';
  end if;

  if job_row.created_at < now() - interval '30 days' then
    raise exception 'This guest action link has expired. Contact VoltFriq support to continue.';
  end if;

  if p_next_status = 'cancelled' then
    perform public.consume_guest_action_token(p_job_id, 'cancel_job', p_action_token);
  elsif p_next_status = 'customer_confirmed' then
    perform public.consume_guest_action_token(p_job_id, 'customer_confirmed', p_action_token);
  end if;

  safe_metadata := coalesce(p_metadata, '{}'::jsonb) - 'phone_confirmation';

  perform public.transition_job_state(
    p_job_id,
    p_next_status,
    'guest',
    null,
    p_note,
    p_note,
    safe_metadata || jsonb_build_object('guest_access', true),
    null,
    null
  );

  return public.guest_job_payload(p_job_id, p_access_token);
end;
$$;


ALTER FUNCTION "public"."update_guest_job_status"("p_job_id" "uuid", "p_access_token" "text", "p_next_status" "public"."job_status", "p_note" "text", "p_metadata" "jsonb", "p_action_token" "text") OWNER TO "postgres";

--
-- Name: upsert_operational_alert("text", "text", "text", "uuid", "uuid", "uuid", "uuid", "uuid", "jsonb"); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."upsert_operational_alert"("p_alert_type" "text", "p_severity" "text", "p_message" "text", "p_job_id" "uuid" DEFAULT NULL::"uuid", "p_electrician_id" "uuid" DEFAULT NULL::"uuid", "p_payment_id" "uuid" DEFAULT NULL::"uuid", "p_dispute_id" "uuid" DEFAULT NULL::"uuid", "p_event_id" "uuid" DEFAULT NULL::"uuid", "p_metadata" "jsonb" DEFAULT '{}'::"jsonb") RETURNS "public"."operational_alerts"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
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


ALTER FUNCTION "public"."upsert_operational_alert"("p_alert_type" "text", "p_severity" "text", "p_message" "text", "p_job_id" "uuid", "p_electrician_id" "uuid", "p_payment_id" "uuid", "p_dispute_id" "uuid", "p_event_id" "uuid", "p_metadata" "jsonb") OWNER TO "postgres";

--
-- Name: verify_guest_otp("uuid", "text", "text", "uuid", "text"); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."verify_guest_otp"("p_job_id" "uuid", "p_access_token" "text", "p_action_type" "text", "p_challenge_id" "uuid", "p_otp_code" "text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
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


ALTER FUNCTION "public"."verify_guest_otp"("p_job_id" "uuid", "p_access_token" "text", "p_action_type" "text", "p_challenge_id" "uuid", "p_otp_code" "text") OWNER TO "postgres";

--
-- Name: verify_job_payment("uuid", boolean, "text"); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."verify_job_payment"("p_payment_id" "uuid", "p_approved" boolean, "p_admin_note" "text" DEFAULT NULL::"text") RETURNS "public"."job_payments"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  payment_row public.job_payments;
  job_row public.jobs;
  next_status public.job_status;
  customer_profile uuid;
  electrician_profile uuid;
  event_type_value text;
begin
  if not public.is_admin() then
    raise exception 'Admin access required';
  end if;

  select * into payment_row from public.job_payments where id = p_payment_id for update;
  if not found then
    raise exception 'Payment not found';
  end if;

  select * into job_row from public.jobs where id = payment_row.job_id for update;
  if not found then
    raise exception 'Job not found';
  end if;

  if payment_row.status = 'verified' and p_approved then
    return payment_row;
  end if;

  if payment_row.status in ('verified', 'rejected')
     and payment_row.status <> (case when p_approved then 'verified'::public.payment_status else 'rejected'::public.payment_status end) then
    raise exception 'Payment has already been resolved. Refresh before changing it.';
  end if;

  if job_row.status = 'cancelled' then
    raise exception 'Cancelled jobs cannot receive payment verification.';
  end if;

  update public.job_payments
  set status = case when p_approved then 'verified'::public.payment_status else 'rejected'::public.payment_status end,
      admin_note = p_admin_note,
      verified_by = auth.uid(),
      verified_at = now()
  where id = p_payment_id
  returning * into payment_row;

  if p_approved then
    next_status := case
      when payment_row.payment_type = 'assessment_fee' then 'assessment_confirmed'::public.job_status
      else 'payment_confirmed'::public.job_status
    end;
  else
    next_status := case
      when payment_row.payment_type = 'assessment_fee' then 'assessment_fee_pending'::public.job_status
      else 'quote_accepted'::public.job_status
    end;
  end if;

  job_row := public.transition_job_state(
    payment_row.job_id,
    next_status,
    'admin',
    auth.uid(),
    case when p_approved then 'Payment verified.' else 'Payment needs to be resubmitted.' end,
    case when p_approved then 'Payment verified by admin.' else 'Payment rejected by admin.' end,
    jsonb_build_object(
      'payment_id', payment_row.id,
      'payment_type', payment_row.payment_type,
      'approved', p_approved,
      'source', 'verify_job_payment',
      'expected_state_version', job_row.state_version
    ),
    job_row.status,
    'payment-verification:' || payment_row.id::text || ':' || case when p_approved then 'approved' else 'rejected' end
  );

  event_type_value := case when p_approved then 'PAYMENT_VERIFIED' else 'JOB_UPDATED' end;
  perform public.log_job_event(
    payment_row.job_id,
    event_type_value,
    'admin',
    auth.uid(),
    case when p_approved then 'Payment verified.' else 'Payment needs to be resubmitted.' end,
    case when p_approved then 'Payment verified by admin.' else 'Payment rejected by admin.' end,
    jsonb_build_object(
      'payment_id', payment_row.id,
      'payment_type', payment_row.payment_type,
      'source', 'verify_job_payment',
      'idempotency_key', 'payment-event:' || payment_row.id::text || ':' || case when p_approved then 'approved' else 'rejected' end
    )
  );

  select c.profile_id into customer_profile
  from public.jobs j
  join public.customers c on c.id = j.customer_id
  where j.id = payment_row.job_id;

  select e.profile_id into electrician_profile
  from public.jobs j
  join public.electricians e on e.id = j.assigned_electrician_id
  where j.id = payment_row.job_id;

  if p_approved then
    perform public.create_notification(customer_profile, payment_row.job_id, 'payment_verified', 'Payment verified', 'Your payment was verified and the job can move forward.', jsonb_build_object('payment_id', payment_row.id));
    perform public.create_notification(electrician_profile, payment_row.job_id, 'payment_verified', 'Payment confirmed', 'Admin verified customer payment for this job.', jsonb_build_object('payment_id', payment_row.id));
  else
    perform public.create_notification(customer_profile, payment_row.job_id, 'payment_rejected', 'Payment review needed', 'VoltFriq could not verify that proof. Please resubmit clearly.', jsonb_build_object('payment_id', payment_row.id));
  end if;

  return payment_row;
end;
$$;


ALTER FUNCTION "public"."verify_job_payment"("p_payment_id" "uuid", "p_approved" boolean, "p_admin_note" "text") OWNER TO "postgres";

--
-- Name: allow_any_operation("text"[]); Type: FUNCTION; Schema: storage; Owner: supabase_storage_admin
--

CREATE FUNCTION "storage"."allow_any_operation"("expected_operations" "text"[]) RETURNS boolean
    LANGUAGE "sql" STABLE
    AS $$
  WITH current_operation AS (
    SELECT storage.operation() AS raw_operation
  ),
  normalized AS (
    SELECT CASE
      WHEN raw_operation LIKE 'storage.%' THEN substr(raw_operation, 9)
      ELSE raw_operation
    END AS current_operation
    FROM current_operation
  )
  SELECT EXISTS (
    SELECT 1
    FROM normalized n
    CROSS JOIN LATERAL unnest(expected_operations) AS expected_operation
    WHERE expected_operation IS NOT NULL
      AND expected_operation <> ''
      AND n.current_operation = CASE
        WHEN expected_operation LIKE 'storage.%' THEN substr(expected_operation, 9)
        ELSE expected_operation
      END
  );
$$;


ALTER FUNCTION "storage"."allow_any_operation"("expected_operations" "text"[]) OWNER TO "supabase_storage_admin";

--
-- Name: allow_only_operation("text"); Type: FUNCTION; Schema: storage; Owner: supabase_storage_admin
--

CREATE FUNCTION "storage"."allow_only_operation"("expected_operation" "text") RETURNS boolean
    LANGUAGE "sql" STABLE
    AS $$
  WITH current_operation AS (
    SELECT storage.operation() AS raw_operation
  ),
  normalized AS (
    SELECT
      CASE
        WHEN raw_operation LIKE 'storage.%' THEN substr(raw_operation, 9)
        ELSE raw_operation
      END AS current_operation,
      CASE
        WHEN expected_operation LIKE 'storage.%' THEN substr(expected_operation, 9)
        ELSE expected_operation
      END AS requested_operation
    FROM current_operation
  )
  SELECT CASE
    WHEN requested_operation IS NULL OR requested_operation = '' THEN FALSE
    ELSE COALESCE(current_operation = requested_operation, FALSE)
  END
  FROM normalized;
$$;


ALTER FUNCTION "storage"."allow_only_operation"("expected_operation" "text") OWNER TO "supabase_storage_admin";

--
-- Name: can_insert_object("text", "text", "uuid", "jsonb"); Type: FUNCTION; Schema: storage; Owner: supabase_storage_admin
--

CREATE FUNCTION "storage"."can_insert_object"("bucketid" "text", "name" "text", "owner" "uuid", "metadata" "jsonb") RETURNS "void"
    LANGUAGE "plpgsql"
    AS $$
BEGIN
  INSERT INTO "storage"."objects" ("bucket_id", "name", "owner", "metadata") VALUES (bucketid, name, owner, metadata);
  -- hack to rollback the successful insert
  RAISE sqlstate 'PT200' using
  message = 'ROLLBACK',
  detail = 'rollback successful insert';
END
$$;


ALTER FUNCTION "storage"."can_insert_object"("bucketid" "text", "name" "text", "owner" "uuid", "metadata" "jsonb") OWNER TO "supabase_storage_admin";

--
-- Name: enforce_bucket_name_length(); Type: FUNCTION; Schema: storage; Owner: supabase_storage_admin
--

CREATE FUNCTION "storage"."enforce_bucket_name_length"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
begin
    if length(new.name) > 100 then
        raise exception 'bucket name "%" is too long (% characters). Max is 100.', new.name, length(new.name);
    end if;
    return new;
end;
$$;


ALTER FUNCTION "storage"."enforce_bucket_name_length"() OWNER TO "supabase_storage_admin";

--
-- Name: extension("text"); Type: FUNCTION; Schema: storage; Owner: supabase_storage_admin
--

CREATE FUNCTION "storage"."extension"("name" "text") RETURNS "text"
    LANGUAGE "plpgsql" IMMUTABLE
    AS $$
DECLARE
    _parts text[];
    _filename text;
BEGIN
    -- Split on "/" to get path segments
    SELECT string_to_array(name, '/') INTO _parts;
    -- Get the last path segment (the actual filename)
    SELECT _parts[array_length(_parts, 1)] INTO _filename;
    -- Extract extension: reverse, split on '.', then reverse again
    RETURN reverse(split_part(reverse(_filename), '.', 1));
END
$$;


ALTER FUNCTION "storage"."extension"("name" "text") OWNER TO "supabase_storage_admin";

--
-- Name: filename("text"); Type: FUNCTION; Schema: storage; Owner: supabase_storage_admin
--

CREATE FUNCTION "storage"."filename"("name" "text") RETURNS "text"
    LANGUAGE "plpgsql"
    AS $$
DECLARE
_parts text[];
BEGIN
	select string_to_array(name, '/') into _parts;
	return _parts[array_length(_parts,1)];
END
$$;


ALTER FUNCTION "storage"."filename"("name" "text") OWNER TO "supabase_storage_admin";

--
-- Name: foldername("text"); Type: FUNCTION; Schema: storage; Owner: supabase_storage_admin
--

CREATE FUNCTION "storage"."foldername"("name" "text") RETURNS "text"[]
    LANGUAGE "plpgsql" IMMUTABLE
    AS $$
DECLARE
    _parts text[];
BEGIN
    -- Split on "/" to get path segments
    SELECT string_to_array(name, '/') INTO _parts;
    -- Return everything except the last segment
    RETURN _parts[1 : array_length(_parts,1) - 1];
END
$$;


ALTER FUNCTION "storage"."foldername"("name" "text") OWNER TO "supabase_storage_admin";

--
-- Name: get_common_prefix("text", "text", "text"); Type: FUNCTION; Schema: storage; Owner: supabase_storage_admin
--

CREATE FUNCTION "storage"."get_common_prefix"("p_key" "text", "p_prefix" "text", "p_delimiter" "text") RETURNS "text"
    LANGUAGE "sql" IMMUTABLE
    AS $$
SELECT CASE
    WHEN position(p_delimiter IN substring(p_key FROM length(p_prefix) + 1)) > 0
    THEN left(p_key, length(p_prefix) + position(p_delimiter IN substring(p_key FROM length(p_prefix) + 1)))
    ELSE NULL
END;
$$;


ALTER FUNCTION "storage"."get_common_prefix"("p_key" "text", "p_prefix" "text", "p_delimiter" "text") OWNER TO "supabase_storage_admin";

--
-- Name: get_size_by_bucket(); Type: FUNCTION; Schema: storage; Owner: supabase_storage_admin
--

CREATE FUNCTION "storage"."get_size_by_bucket"() RETURNS TABLE("size" bigint, "bucket_id" "text")
    LANGUAGE "plpgsql" STABLE
    AS $$
BEGIN
    return query
        select sum((metadata->>'size')::bigint)::bigint as size, obj.bucket_id
        from "storage".objects as obj
        group by obj.bucket_id;
END
$$;


ALTER FUNCTION "storage"."get_size_by_bucket"() OWNER TO "supabase_storage_admin";

--
-- Name: list_multipart_uploads_with_delimiter("text", "text", "text", integer, "text", "text"); Type: FUNCTION; Schema: storage; Owner: supabase_storage_admin
--

CREATE FUNCTION "storage"."list_multipart_uploads_with_delimiter"("bucket_id" "text", "prefix_param" "text", "delimiter_param" "text", "max_keys" integer DEFAULT 100, "next_key_token" "text" DEFAULT ''::"text", "next_upload_token" "text" DEFAULT ''::"text") RETURNS TABLE("key" "text", "id" "text", "created_at" timestamp with time zone)
    LANGUAGE "plpgsql"
    AS $_$
BEGIN
    RETURN QUERY EXECUTE
        'SELECT DISTINCT ON(key COLLATE "C") * from (
            SELECT
                CASE
                    WHEN position($2 IN substring(key from length($1) + 1)) > 0 THEN
                        substring(key from 1 for length($1) + position($2 IN substring(key from length($1) + 1)))
                    ELSE
                        key
                END AS key, id, created_at
            FROM
                storage.s3_multipart_uploads
            WHERE
                bucket_id = $5 AND
                key ILIKE $1 || ''%'' AND
                CASE
                    WHEN $4 != '''' AND $6 = '''' THEN
                        CASE
                            WHEN position($2 IN substring(key from length($1) + 1)) > 0 THEN
                                substring(key from 1 for length($1) + position($2 IN substring(key from length($1) + 1))) COLLATE "C" > $4
                            ELSE
                                key COLLATE "C" > $4
                            END
                    ELSE
                        true
                END AND
                CASE
                    WHEN $6 != '''' THEN
                        id COLLATE "C" > $6
                    ELSE
                        true
                    END
            ORDER BY
                key COLLATE "C" ASC, created_at ASC) as e order by key COLLATE "C" LIMIT $3'
        USING prefix_param, delimiter_param, max_keys, next_key_token, bucket_id, next_upload_token;
END;
$_$;


ALTER FUNCTION "storage"."list_multipart_uploads_with_delimiter"("bucket_id" "text", "prefix_param" "text", "delimiter_param" "text", "max_keys" integer, "next_key_token" "text", "next_upload_token" "text") OWNER TO "supabase_storage_admin";

--
-- Name: list_objects_with_delimiter("text", "text", "text", integer, "text", "text", "text"); Type: FUNCTION; Schema: storage; Owner: supabase_storage_admin
--

CREATE FUNCTION "storage"."list_objects_with_delimiter"("_bucket_id" "text", "prefix_param" "text", "delimiter_param" "text", "max_keys" integer DEFAULT 100, "start_after" "text" DEFAULT ''::"text", "next_token" "text" DEFAULT ''::"text", "sort_order" "text" DEFAULT 'asc'::"text") RETURNS TABLE("name" "text", "id" "uuid", "metadata" "jsonb", "updated_at" timestamp with time zone, "created_at" timestamp with time zone, "last_accessed_at" timestamp with time zone)
    LANGUAGE "plpgsql" STABLE
    AS $_$
DECLARE
    v_peek_name TEXT;
    v_current RECORD;
    v_common_prefix TEXT;

    -- Configuration
    v_is_asc BOOLEAN;
    v_prefix TEXT;
    v_start TEXT;
    v_upper_bound TEXT;
    v_file_batch_size INT;

    -- Seek state
    v_next_seek TEXT;
    v_count INT := 0;

    -- Dynamic SQL for batch query only
    v_batch_query TEXT;

BEGIN
    -- ========================================================================
    -- INITIALIZATION
    -- ========================================================================
    v_is_asc := lower(coalesce(sort_order, 'asc')) = 'asc';
    v_prefix := coalesce(prefix_param, '');
    v_start := CASE WHEN coalesce(next_token, '') <> '' THEN next_token ELSE coalesce(start_after, '') END;
    v_file_batch_size := LEAST(GREATEST(max_keys * 2, 100), 1000);

    -- Calculate upper bound for prefix filtering (bytewise, using COLLATE "C")
    IF v_prefix = '' THEN
        v_upper_bound := NULL;
    ELSIF right(v_prefix, 1) = delimiter_param THEN
        v_upper_bound := left(v_prefix, -1) || chr(ascii(delimiter_param) + 1);
    ELSE
        v_upper_bound := left(v_prefix, -1) || chr(ascii(right(v_prefix, 1)) + 1);
    END IF;

    -- Build batch query (dynamic SQL - called infrequently, amortized over many rows)
    IF v_is_asc THEN
        IF v_upper_bound IS NOT NULL THEN
            v_batch_query := 'SELECT o.name, o.id, o.updated_at, o.created_at, o.last_accessed_at, o.metadata ' ||
                'FROM storage.objects o WHERE o.bucket_id = $1 AND o.name COLLATE "C" >= $2 ' ||
                'AND o.name COLLATE "C" < $3 ORDER BY o.name COLLATE "C" ASC LIMIT $4';
        ELSE
            v_batch_query := 'SELECT o.name, o.id, o.updated_at, o.created_at, o.last_accessed_at, o.metadata ' ||
                'FROM storage.objects o WHERE o.bucket_id = $1 AND o.name COLLATE "C" >= $2 ' ||
                'ORDER BY o.name COLLATE "C" ASC LIMIT $4';
        END IF;
    ELSE
        IF v_upper_bound IS NOT NULL THEN
            v_batch_query := 'SELECT o.name, o.id, o.updated_at, o.created_at, o.last_accessed_at, o.metadata ' ||
                'FROM storage.objects o WHERE o.bucket_id = $1 AND o.name COLLATE "C" < $2 ' ||
                'AND o.name COLLATE "C" >= $3 ORDER BY o.name COLLATE "C" DESC LIMIT $4';
        ELSE
            v_batch_query := 'SELECT o.name, o.id, o.updated_at, o.created_at, o.last_accessed_at, o.metadata ' ||
                'FROM storage.objects o WHERE o.bucket_id = $1 AND o.name COLLATE "C" < $2 ' ||
                'ORDER BY o.name COLLATE "C" DESC LIMIT $4';
        END IF;
    END IF;

    -- ========================================================================
    -- SEEK INITIALIZATION: Determine starting position
    -- ========================================================================
    IF v_start = '' THEN
        IF v_is_asc THEN
            v_next_seek := v_prefix;
        ELSE
            -- DESC without cursor: find the last item in range
            IF v_upper_bound IS NOT NULL THEN
                SELECT o.name INTO v_next_seek FROM storage.objects o
                WHERE o.bucket_id = _bucket_id AND o.name COLLATE "C" >= v_prefix AND o.name COLLATE "C" < v_upper_bound
                ORDER BY o.name COLLATE "C" DESC LIMIT 1;
            ELSIF v_prefix <> '' THEN
                SELECT o.name INTO v_next_seek FROM storage.objects o
                WHERE o.bucket_id = _bucket_id AND o.name COLLATE "C" >= v_prefix
                ORDER BY o.name COLLATE "C" DESC LIMIT 1;
            ELSE
                SELECT o.name INTO v_next_seek FROM storage.objects o
                WHERE o.bucket_id = _bucket_id
                ORDER BY o.name COLLATE "C" DESC LIMIT 1;
            END IF;

            IF v_next_seek IS NOT NULL THEN
                v_next_seek := v_next_seek || delimiter_param;
            ELSE
                RETURN;
            END IF;
        END IF;
    ELSE
        -- Cursor provided: determine if it refers to a folder or leaf
        IF EXISTS (
            SELECT 1 FROM storage.objects o
            WHERE o.bucket_id = _bucket_id
              AND o.name COLLATE "C" LIKE v_start || delimiter_param || '%'
            LIMIT 1
        ) THEN
            -- Cursor refers to a folder
            IF v_is_asc THEN
                v_next_seek := v_start || chr(ascii(delimiter_param) + 1);
            ELSE
                v_next_seek := v_start || delimiter_param;
            END IF;
        ELSE
            -- Cursor refers to a leaf object
            IF v_is_asc THEN
                v_next_seek := v_start || delimiter_param;
            ELSE
                v_next_seek := v_start;
            END IF;
        END IF;
    END IF;

    -- ========================================================================
    -- MAIN LOOP: Hybrid peek-then-batch algorithm
    -- Uses STATIC SQL for peek (hot path) and DYNAMIC SQL for batch
    -- ========================================================================
    LOOP
        EXIT WHEN v_count >= max_keys;

        -- STEP 1: PEEK using STATIC SQL (plan cached, very fast)
        IF v_is_asc THEN
            IF v_upper_bound IS NOT NULL THEN
                SELECT o.name INTO v_peek_name FROM storage.objects o
                WHERE o.bucket_id = _bucket_id AND o.name COLLATE "C" >= v_next_seek AND o.name COLLATE "C" < v_upper_bound
                ORDER BY o.name COLLATE "C" ASC LIMIT 1;
            ELSE
                SELECT o.name INTO v_peek_name FROM storage.objects o
                WHERE o.bucket_id = _bucket_id AND o.name COLLATE "C" >= v_next_seek
                ORDER BY o.name COLLATE "C" ASC LIMIT 1;
            END IF;
        ELSE
            IF v_upper_bound IS NOT NULL THEN
                SELECT o.name INTO v_peek_name FROM storage.objects o
                WHERE o.bucket_id = _bucket_id AND o.name COLLATE "C" < v_next_seek AND o.name COLLATE "C" >= v_prefix
                ORDER BY o.name COLLATE "C" DESC LIMIT 1;
            ELSIF v_prefix <> '' THEN
                SELECT o.name INTO v_peek_name FROM storage.objects o
                WHERE o.bucket_id = _bucket_id AND o.name COLLATE "C" < v_next_seek AND o.name COLLATE "C" >= v_prefix
                ORDER BY o.name COLLATE "C" DESC LIMIT 1;
            ELSE
                SELECT o.name INTO v_peek_name FROM storage.objects o
                WHERE o.bucket_id = _bucket_id AND o.name COLLATE "C" < v_next_seek
                ORDER BY o.name COLLATE "C" DESC LIMIT 1;
            END IF;
        END IF;

        EXIT WHEN v_peek_name IS NULL;

        -- STEP 2: Check if this is a FOLDER or FILE
        v_common_prefix := storage.get_common_prefix(v_peek_name, v_prefix, delimiter_param);

        IF v_common_prefix IS NOT NULL THEN
            -- FOLDER: Emit and skip to next folder (no heap access needed)
            name := rtrim(v_common_prefix, delimiter_param);
            id := NULL;
            updated_at := NULL;
            created_at := NULL;
            last_accessed_at := NULL;
            metadata := NULL;
            RETURN NEXT;
            v_count := v_count + 1;

            -- Advance seek past the folder range
            IF v_is_asc THEN
                v_next_seek := left(v_common_prefix, -1) || chr(ascii(delimiter_param) + 1);
            ELSE
                v_next_seek := v_common_prefix;
            END IF;
        ELSE
            -- FILE: Batch fetch using DYNAMIC SQL (overhead amortized over many rows)
            -- For ASC: upper_bound is the exclusive upper limit (< condition)
            -- For DESC: prefix is the inclusive lower limit (>= condition)
            FOR v_current IN EXECUTE v_batch_query USING _bucket_id, v_next_seek,
                CASE WHEN v_is_asc THEN COALESCE(v_upper_bound, v_prefix) ELSE v_prefix END, v_file_batch_size
            LOOP
                v_common_prefix := storage.get_common_prefix(v_current.name, v_prefix, delimiter_param);

                IF v_common_prefix IS NOT NULL THEN
                    -- Hit a folder: exit batch, let peek handle it
                    v_next_seek := v_current.name;
                    EXIT;
                END IF;

                -- Emit file
                name := v_current.name;
                id := v_current.id;
                updated_at := v_current.updated_at;
                created_at := v_current.created_at;
                last_accessed_at := v_current.last_accessed_at;
                metadata := v_current.metadata;
                RETURN NEXT;
                v_count := v_count + 1;

                -- Advance seek past this file
                IF v_is_asc THEN
                    v_next_seek := v_current.name || delimiter_param;
                ELSE
                    v_next_seek := v_current.name;
                END IF;

                EXIT WHEN v_count >= max_keys;
            END LOOP;
        END IF;
    END LOOP;
END;
$_$;


ALTER FUNCTION "storage"."list_objects_with_delimiter"("_bucket_id" "text", "prefix_param" "text", "delimiter_param" "text", "max_keys" integer, "start_after" "text", "next_token" "text", "sort_order" "text") OWNER TO "supabase_storage_admin";

--
-- Name: operation(); Type: FUNCTION; Schema: storage; Owner: supabase_storage_admin
--

CREATE FUNCTION "storage"."operation"() RETURNS "text"
    LANGUAGE "plpgsql" STABLE
    AS $$
BEGIN
    RETURN current_setting('storage.operation', true);
END;
$$;


ALTER FUNCTION "storage"."operation"() OWNER TO "supabase_storage_admin";

--
-- Name: protect_delete(); Type: FUNCTION; Schema: storage; Owner: supabase_storage_admin
--

CREATE FUNCTION "storage"."protect_delete"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
BEGIN
    -- Check if storage.allow_delete_query is set to 'true'
    IF COALESCE(current_setting('storage.allow_delete_query', true), 'false') != 'true' THEN
        RAISE EXCEPTION 'Direct deletion from storage tables is not allowed. Use the Storage API instead.'
            USING HINT = 'This prevents accidental data loss from orphaned objects.',
                  ERRCODE = '42501';
    END IF;
    RETURN NULL;
END;
$$;


ALTER FUNCTION "storage"."protect_delete"() OWNER TO "supabase_storage_admin";

--
-- Name: search("text", "text", integer, integer, integer, "text", "text", "text"); Type: FUNCTION; Schema: storage; Owner: supabase_storage_admin
--

CREATE FUNCTION "storage"."search"("prefix" "text", "bucketname" "text", "limits" integer DEFAULT 100, "levels" integer DEFAULT 1, "offsets" integer DEFAULT 0, "search" "text" DEFAULT ''::"text", "sortcolumn" "text" DEFAULT 'name'::"text", "sortorder" "text" DEFAULT 'asc'::"text") RETURNS TABLE("name" "text", "id" "uuid", "updated_at" timestamp with time zone, "created_at" timestamp with time zone, "last_accessed_at" timestamp with time zone, "metadata" "jsonb")
    LANGUAGE "plpgsql" STABLE
    AS $_$
DECLARE
    v_peek_name TEXT;
    v_current RECORD;
    v_common_prefix TEXT;
    v_delimiter CONSTANT TEXT := '/';

    -- Configuration
    v_limit INT;
    v_prefix TEXT;
    v_prefix_lower TEXT;
    v_is_asc BOOLEAN;
    v_order_by TEXT;
    v_sort_order TEXT;
    v_upper_bound TEXT;
    v_file_batch_size INT;

    -- Dynamic SQL for batch query only
    v_batch_query TEXT;

    -- Seek state
    v_next_seek TEXT;
    v_count INT := 0;
    v_skipped INT := 0;
BEGIN
    -- ========================================================================
    -- INITIALIZATION
    -- ========================================================================
    v_limit := LEAST(coalesce(limits, 100), 1500);
    v_prefix := coalesce(prefix, '') || coalesce(search, '');
    v_prefix_lower := lower(v_prefix);
    v_is_asc := lower(coalesce(sortorder, 'asc')) = 'asc';
    v_file_batch_size := LEAST(GREATEST(v_limit * 2, 100), 1000);

    -- Validate sort column
    CASE lower(coalesce(sortcolumn, 'name'))
        WHEN 'name' THEN v_order_by := 'name';
        WHEN 'updated_at' THEN v_order_by := 'updated_at';
        WHEN 'created_at' THEN v_order_by := 'created_at';
        WHEN 'last_accessed_at' THEN v_order_by := 'last_accessed_at';
        ELSE v_order_by := 'name';
    END CASE;

    v_sort_order := CASE WHEN v_is_asc THEN 'asc' ELSE 'desc' END;

    -- ========================================================================
    -- NON-NAME SORTING: Use path_tokens approach (unchanged)
    -- ========================================================================
    IF v_order_by != 'name' THEN
        RETURN QUERY EXECUTE format(
            $sql$
            WITH folders AS (
                SELECT path_tokens[$1] AS folder
                FROM storage.objects
                WHERE objects.name ILIKE $2 || '%%'
                  AND bucket_id = $3
                  AND array_length(objects.path_tokens, 1) <> $1
                GROUP BY folder
                ORDER BY folder %s
            )
            (SELECT folder AS "name",
                   NULL::uuid AS id,
                   NULL::timestamptz AS updated_at,
                   NULL::timestamptz AS created_at,
                   NULL::timestamptz AS last_accessed_at,
                   NULL::jsonb AS metadata FROM folders)
            UNION ALL
            (SELECT path_tokens[$1] AS "name",
                   id, updated_at, created_at, last_accessed_at, metadata
             FROM storage.objects
             WHERE objects.name ILIKE $2 || '%%'
               AND bucket_id = $3
               AND array_length(objects.path_tokens, 1) = $1
             ORDER BY %I %s)
            LIMIT $4 OFFSET $5
            $sql$, v_sort_order, v_order_by, v_sort_order
        ) USING levels, v_prefix, bucketname, v_limit, offsets;
        RETURN;
    END IF;

    -- ========================================================================
    -- NAME SORTING: Hybrid skip-scan with batch optimization
    -- ========================================================================

    -- Calculate upper bound for prefix filtering
    IF v_prefix_lower = '' THEN
        v_upper_bound := NULL;
    ELSIF right(v_prefix_lower, 1) = v_delimiter THEN
        v_upper_bound := left(v_prefix_lower, -1) || chr(ascii(v_delimiter) + 1);
    ELSE
        v_upper_bound := left(v_prefix_lower, -1) || chr(ascii(right(v_prefix_lower, 1)) + 1);
    END IF;

    -- Build batch query (dynamic SQL - called infrequently, amortized over many rows)
    IF v_is_asc THEN
        IF v_upper_bound IS NOT NULL THEN
            v_batch_query := 'SELECT o.name, o.id, o.updated_at, o.created_at, o.last_accessed_at, o.metadata ' ||
                'FROM storage.objects o WHERE o.bucket_id = $1 AND lower(o.name) COLLATE "C" >= $2 ' ||
                'AND lower(o.name) COLLATE "C" < $3 ORDER BY lower(o.name) COLLATE "C" ASC LIMIT $4';
        ELSE
            v_batch_query := 'SELECT o.name, o.id, o.updated_at, o.created_at, o.last_accessed_at, o.metadata ' ||
                'FROM storage.objects o WHERE o.bucket_id = $1 AND lower(o.name) COLLATE "C" >= $2 ' ||
                'ORDER BY lower(o.name) COLLATE "C" ASC LIMIT $4';
        END IF;
    ELSE
        IF v_upper_bound IS NOT NULL THEN
            v_batch_query := 'SELECT o.name, o.id, o.updated_at, o.created_at, o.last_accessed_at, o.metadata ' ||
                'FROM storage.objects o WHERE o.bucket_id = $1 AND lower(o.name) COLLATE "C" < $2 ' ||
                'AND lower(o.name) COLLATE "C" >= $3 ORDER BY lower(o.name) COLLATE "C" DESC LIMIT $4';
        ELSE
            v_batch_query := 'SELECT o.name, o.id, o.updated_at, o.created_at, o.last_accessed_at, o.metadata ' ||
                'FROM storage.objects o WHERE o.bucket_id = $1 AND lower(o.name) COLLATE "C" < $2 ' ||
                'ORDER BY lower(o.name) COLLATE "C" DESC LIMIT $4';
        END IF;
    END IF;

    -- Initialize seek position
    IF v_is_asc THEN
        v_next_seek := v_prefix_lower;
    ELSE
        -- DESC: find the last item in range first (static SQL)
        IF v_upper_bound IS NOT NULL THEN
            SELECT o.name INTO v_peek_name FROM storage.objects o
            WHERE o.bucket_id = bucketname AND lower(o.name) COLLATE "C" >= v_prefix_lower AND lower(o.name) COLLATE "C" < v_upper_bound
            ORDER BY lower(o.name) COLLATE "C" DESC LIMIT 1;
        ELSIF v_prefix_lower <> '' THEN
            SELECT o.name INTO v_peek_name FROM storage.objects o
            WHERE o.bucket_id = bucketname AND lower(o.name) COLLATE "C" >= v_prefix_lower
            ORDER BY lower(o.name) COLLATE "C" DESC LIMIT 1;
        ELSE
            SELECT o.name INTO v_peek_name FROM storage.objects o
            WHERE o.bucket_id = bucketname
            ORDER BY lower(o.name) COLLATE "C" DESC LIMIT 1;
        END IF;

        IF v_peek_name IS NOT NULL THEN
            v_next_seek := lower(v_peek_name) || v_delimiter;
        ELSE
            RETURN;
        END IF;
    END IF;

    -- ========================================================================
    -- MAIN LOOP: Hybrid peek-then-batch algorithm
    -- Uses STATIC SQL for peek (hot path) and DYNAMIC SQL for batch
    -- ========================================================================
    LOOP
        EXIT WHEN v_count >= v_limit;

        -- STEP 1: PEEK using STATIC SQL (plan cached, very fast)
        IF v_is_asc THEN
            IF v_upper_bound IS NOT NULL THEN
                SELECT o.name INTO v_peek_name FROM storage.objects o
                WHERE o.bucket_id = bucketname AND lower(o.name) COLLATE "C" >= v_next_seek AND lower(o.name) COLLATE "C" < v_upper_bound
                ORDER BY lower(o.name) COLLATE "C" ASC LIMIT 1;
            ELSE
                SELECT o.name INTO v_peek_name FROM storage.objects o
                WHERE o.bucket_id = bucketname AND lower(o.name) COLLATE "C" >= v_next_seek
                ORDER BY lower(o.name) COLLATE "C" ASC LIMIT 1;
            END IF;
        ELSE
            IF v_upper_bound IS NOT NULL THEN
                SELECT o.name INTO v_peek_name FROM storage.objects o
                WHERE o.bucket_id = bucketname AND lower(o.name) COLLATE "C" < v_next_seek AND lower(o.name) COLLATE "C" >= v_prefix_lower
                ORDER BY lower(o.name) COLLATE "C" DESC LIMIT 1;
            ELSIF v_prefix_lower <> '' THEN
                SELECT o.name INTO v_peek_name FROM storage.objects o
                WHERE o.bucket_id = bucketname AND lower(o.name) COLLATE "C" < v_next_seek AND lower(o.name) COLLATE "C" >= v_prefix_lower
                ORDER BY lower(o.name) COLLATE "C" DESC LIMIT 1;
            ELSE
                SELECT o.name INTO v_peek_name FROM storage.objects o
                WHERE o.bucket_id = bucketname AND lower(o.name) COLLATE "C" < v_next_seek
                ORDER BY lower(o.name) COLLATE "C" DESC LIMIT 1;
            END IF;
        END IF;

        EXIT WHEN v_peek_name IS NULL;

        -- STEP 2: Check if this is a FOLDER or FILE
        v_common_prefix := storage.get_common_prefix(lower(v_peek_name), v_prefix_lower, v_delimiter);

        IF v_common_prefix IS NOT NULL THEN
            -- FOLDER: Handle offset, emit if needed, skip to next folder
            IF v_skipped < offsets THEN
                v_skipped := v_skipped + 1;
            ELSE
                name := split_part(rtrim(storage.get_common_prefix(v_peek_name, v_prefix, v_delimiter), v_delimiter), v_delimiter, levels);
                id := NULL;
                updated_at := NULL;
                created_at := NULL;
                last_accessed_at := NULL;
                metadata := NULL;
                RETURN NEXT;
                v_count := v_count + 1;
            END IF;

            -- Advance seek past the folder range
            IF v_is_asc THEN
                v_next_seek := lower(left(v_common_prefix, -1)) || chr(ascii(v_delimiter) + 1);
            ELSE
                v_next_seek := lower(v_common_prefix);
            END IF;
        ELSE
            -- FILE: Batch fetch using DYNAMIC SQL (overhead amortized over many rows)
            -- For ASC: upper_bound is the exclusive upper limit (< condition)
            -- For DESC: prefix_lower is the inclusive lower limit (>= condition)
            FOR v_current IN EXECUTE v_batch_query
                USING bucketname, v_next_seek,
                    CASE WHEN v_is_asc THEN COALESCE(v_upper_bound, v_prefix_lower) ELSE v_prefix_lower END, v_file_batch_size
            LOOP
                v_common_prefix := storage.get_common_prefix(lower(v_current.name), v_prefix_lower, v_delimiter);

                IF v_common_prefix IS NOT NULL THEN
                    -- Hit a folder: exit batch, let peek handle it
                    v_next_seek := lower(v_current.name);
                    EXIT;
                END IF;

                -- Handle offset skipping
                IF v_skipped < offsets THEN
                    v_skipped := v_skipped + 1;
                ELSE
                    -- Emit file
                    name := split_part(v_current.name, v_delimiter, levels);
                    id := v_current.id;
                    updated_at := v_current.updated_at;
                    created_at := v_current.created_at;
                    last_accessed_at := v_current.last_accessed_at;
                    metadata := v_current.metadata;
                    RETURN NEXT;
                    v_count := v_count + 1;
                END IF;

                -- Advance seek past this file
                IF v_is_asc THEN
                    v_next_seek := lower(v_current.name) || v_delimiter;
                ELSE
                    v_next_seek := lower(v_current.name);
                END IF;

                EXIT WHEN v_count >= v_limit;
            END LOOP;
        END IF;
    END LOOP;
END;
$_$;


ALTER FUNCTION "storage"."search"("prefix" "text", "bucketname" "text", "limits" integer, "levels" integer, "offsets" integer, "search" "text", "sortcolumn" "text", "sortorder" "text") OWNER TO "supabase_storage_admin";

--
-- Name: search_by_timestamp("text", "text", integer, integer, "text", "text", "text", "text"); Type: FUNCTION; Schema: storage; Owner: supabase_storage_admin
--

CREATE FUNCTION "storage"."search_by_timestamp"("p_prefix" "text", "p_bucket_id" "text", "p_limit" integer, "p_level" integer, "p_start_after" "text", "p_sort_order" "text", "p_sort_column" "text", "p_sort_column_after" "text") RETURNS TABLE("key" "text", "name" "text", "id" "uuid", "updated_at" timestamp with time zone, "created_at" timestamp with time zone, "last_accessed_at" timestamp with time zone, "metadata" "jsonb")
    LANGUAGE "plpgsql" STABLE
    AS $_$
DECLARE
    v_cursor_op text;
    v_query text;
    v_prefix text;
BEGIN
    v_prefix := coalesce(p_prefix, '');

    IF p_sort_order = 'asc' THEN
        v_cursor_op := '>';
    ELSE
        v_cursor_op := '<';
    END IF;

    v_query := format($sql$
        WITH raw_objects AS (
            SELECT
                o.name AS obj_name,
                o.id AS obj_id,
                o.updated_at AS obj_updated_at,
                o.created_at AS obj_created_at,
                o.last_accessed_at AS obj_last_accessed_at,
                o.metadata AS obj_metadata,
                storage.get_common_prefix(o.name, $1, '/') AS common_prefix
            FROM storage.objects o
            WHERE o.bucket_id = $2
              AND o.name COLLATE "C" LIKE $1 || '%%'
        ),
        -- Aggregate common prefixes (folders)
        -- Both created_at and updated_at use MIN(obj_created_at) to match the old prefixes table behavior
        aggregated_prefixes AS (
            SELECT
                rtrim(common_prefix, '/') AS name,
                NULL::uuid AS id,
                MIN(obj_created_at) AS updated_at,
                MIN(obj_created_at) AS created_at,
                NULL::timestamptz AS last_accessed_at,
                NULL::jsonb AS metadata,
                TRUE AS is_prefix
            FROM raw_objects
            WHERE common_prefix IS NOT NULL
            GROUP BY common_prefix
        ),
        leaf_objects AS (
            SELECT
                obj_name AS name,
                obj_id AS id,
                obj_updated_at AS updated_at,
                obj_created_at AS created_at,
                obj_last_accessed_at AS last_accessed_at,
                obj_metadata AS metadata,
                FALSE AS is_prefix
            FROM raw_objects
            WHERE common_prefix IS NULL
        ),
        combined AS (
            SELECT * FROM aggregated_prefixes
            UNION ALL
            SELECT * FROM leaf_objects
        ),
        filtered AS (
            SELECT *
            FROM combined
            WHERE (
                $5 = ''
                OR ROW(
                    date_trunc('milliseconds', %I),
                    name COLLATE "C"
                ) %s ROW(
                    COALESCE(NULLIF($6, '')::timestamptz, 'epoch'::timestamptz),
                    $5
                )
            )
        )
        SELECT
            split_part(name, '/', $3) AS key,
            name,
            id,
            updated_at,
            created_at,
            last_accessed_at,
            metadata
        FROM filtered
        ORDER BY
            COALESCE(date_trunc('milliseconds', %I), 'epoch'::timestamptz) %s,
            name COLLATE "C" %s
        LIMIT $4
    $sql$,
        p_sort_column,
        v_cursor_op,
        p_sort_column,
        p_sort_order,
        p_sort_order
    );

    RETURN QUERY EXECUTE v_query
    USING v_prefix, p_bucket_id, p_level, p_limit, p_start_after, p_sort_column_after;
END;
$_$;


ALTER FUNCTION "storage"."search_by_timestamp"("p_prefix" "text", "p_bucket_id" "text", "p_limit" integer, "p_level" integer, "p_start_after" "text", "p_sort_order" "text", "p_sort_column" "text", "p_sort_column_after" "text") OWNER TO "supabase_storage_admin";

--
-- Name: search_v2("text", "text", integer, integer, "text", "text", "text", "text"); Type: FUNCTION; Schema: storage; Owner: supabase_storage_admin
--

CREATE FUNCTION "storage"."search_v2"("prefix" "text", "bucket_name" "text", "limits" integer DEFAULT 100, "levels" integer DEFAULT 1, "start_after" "text" DEFAULT ''::"text", "sort_order" "text" DEFAULT 'asc'::"text", "sort_column" "text" DEFAULT 'name'::"text", "sort_column_after" "text" DEFAULT ''::"text") RETURNS TABLE("key" "text", "name" "text", "id" "uuid", "updated_at" timestamp with time zone, "created_at" timestamp with time zone, "last_accessed_at" timestamp with time zone, "metadata" "jsonb")
    LANGUAGE "plpgsql" STABLE
    AS $$
DECLARE
    v_sort_col text;
    v_sort_ord text;
    v_limit int;
BEGIN
    -- Cap limit to maximum of 1500 records
    v_limit := LEAST(coalesce(limits, 100), 1500);

    -- Validate and normalize sort_order
    v_sort_ord := lower(coalesce(sort_order, 'asc'));
    IF v_sort_ord NOT IN ('asc', 'desc') THEN
        v_sort_ord := 'asc';
    END IF;

    -- Validate and normalize sort_column
    v_sort_col := lower(coalesce(sort_column, 'name'));
    IF v_sort_col NOT IN ('name', 'updated_at', 'created_at') THEN
        v_sort_col := 'name';
    END IF;

    -- Route to appropriate implementation
    IF v_sort_col = 'name' THEN
        -- Use list_objects_with_delimiter for name sorting (most efficient: O(k * log n))
        RETURN QUERY
        SELECT
            split_part(l.name, '/', levels) AS key,
            l.name AS name,
            l.id,
            l.updated_at,
            l.created_at,
            l.last_accessed_at,
            l.metadata
        FROM storage.list_objects_with_delimiter(
            bucket_name,
            coalesce(prefix, ''),
            '/',
            v_limit,
            start_after,
            '',
            v_sort_ord
        ) l;
    ELSE
        -- Use aggregation approach for timestamp sorting
        -- Not efficient for large datasets but supports correct pagination
        RETURN QUERY SELECT * FROM storage.search_by_timestamp(
            prefix, bucket_name, v_limit, levels, start_after,
            v_sort_ord, v_sort_col, sort_column_after
        );
    END IF;
END;
$$;


ALTER FUNCTION "storage"."search_v2"("prefix" "text", "bucket_name" "text", "limits" integer, "levels" integer, "start_after" "text", "sort_order" "text", "sort_column" "text", "sort_column_after" "text") OWNER TO "supabase_storage_admin";

--
-- Name: update_updated_at_column(); Type: FUNCTION; Schema: storage; Owner: supabase_storage_admin
--

CREATE FUNCTION "storage"."update_updated_at_column"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
BEGIN
    NEW.updated_at = now();
    RETURN NEW; 
END;
$$;


ALTER FUNCTION "storage"."update_updated_at_column"() OWNER TO "supabase_storage_admin";

--
-- Name: admin_settings; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE "public"."admin_settings" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "service_areas" "text"[] DEFAULT '{"Lekki Phase 1","Victoria Island",Ikeja,Surulere,Yaba,Ajah}'::"text"[] NOT NULL,
    "issue_categories" "text"[] DEFAULT '{"Power outage","Wiring issue","Tripped breaker","Light fitting","Socket repair",Generator,"CCTV Installation","Solar Installation","General Installation","Security Alarm",Inverter,Other}'::"text"[] NOT NULL,
    "assessment_fee" numeric(12,2) DEFAULT 5000 NOT NULL,
    "ranking_weights" "jsonb" DEFAULT '{"rating": 50, "distance": 20, "skill_match": 70, "availability": 20, "completed_jobs": 30}'::"jsonb" NOT NULL,
    "platform_bank_name" "text" DEFAULT 'First Bank of Nigeria'::"text" NOT NULL,
    "platform_account_number" "text" DEFAULT '3012845678'::"text" NOT NULL,
    "platform_account_name" "text" DEFAULT 'Voltfriq Services Ltd'::"text" NOT NULL,
    "workmanship_prices" "jsonb" DEFAULT '[]'::"jsonb" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "trust_settings" "jsonb" DEFAULT '{"elite_jobs": 60, "rising_jobs": 3, "trusted_jobs": 10, "top_rated_jobs": 25, "negative_rating_limit": 3, "negative_rating_max_score": 2, "watchlist_rank_penalty_km": 8}'::"jsonb" NOT NULL,
    "supported_states" "text"[] DEFAULT '{}'::"text"[] NOT NULL,
    "supported_cities" "text"[] DEFAULT '{}'::"text"[] NOT NULL,
    "launch_cities" "text"[] DEFAULT '{}'::"text"[] NOT NULL,
    "disabled_service_areas" "text"[] DEFAULT '{}'::"text"[] NOT NULL
);


ALTER TABLE "public"."admin_settings" OWNER TO "postgres";

--
-- Name: customer_addresses; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE "public"."customer_addresses" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "profile_id" "uuid" NOT NULL,
    "label" "text" DEFAULT 'Saved address'::"text" NOT NULL,
    "address_text" "text" NOT NULL,
    "location_label" "text",
    "latitude" double precision,
    "longitude" double precision,
    "last_used_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."customer_addresses" OWNER TO "postgres";

--
-- Name: electrician_certifications; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE "public"."electrician_certifications" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "electrician_id" "uuid" NOT NULL,
    "title" "text" NOT NULL,
    "license_number" "text",
    "issuer" "text",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."electrician_certifications" OWNER TO "postgres";

--
-- Name: electrician_documents; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE "public"."electrician_documents" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "electrician_id" "uuid" NOT NULL,
    "document_type" "text" NOT NULL,
    "file_path" "text",
    "file_url" "text",
    "status" "text" DEFAULT 'pending'::"text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."electrician_documents" OWNER TO "postgres";

--
-- Name: electrician_skills; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE "public"."electrician_skills" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "electrician_id" "uuid" NOT NULL,
    "category" "text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."electrician_skills" OWNER TO "postgres";

--
-- Name: event_replay_runs; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE "public"."event_replay_runs" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "request_id" "text",
    "request_hash" "text",
    "replay_scope" "text" DEFAULT 'single'::"text" NOT NULL,
    "job_id" "uuid",
    "status" "text" DEFAULT 'running'::"text" NOT NULL,
    "processed_count" integer DEFAULT 0 NOT NULL,
    "conflict_count" integer DEFAULT 0 NOT NULL,
    "stale_rejected_count" integer DEFAULT 0 NOT NULL,
    "metadata" "jsonb" DEFAULT '{}'::"jsonb" NOT NULL,
    "error_message" "text",
    "started_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "finished_at" timestamp with time zone,
    CONSTRAINT "event_replay_runs_status_check" CHECK (("status" = ANY (ARRAY['running'::"text", 'completed'::"text", 'failed'::"text"])))
);


ALTER TABLE "public"."event_replay_runs" OWNER TO "postgres";

--
-- Name: expertise_categories; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE "public"."expertise_categories" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "label" "text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."expertise_categories" OWNER TO "postgres";

--
-- Name: guest_action_tokens; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE "public"."guest_action_tokens" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "job_id" "uuid" NOT NULL,
    "action_type" "text" NOT NULL,
    "token_hash" "text" NOT NULL,
    "expires_at" timestamp with time zone DEFAULT ("now"() + '00:10:00'::interval) NOT NULL,
    "consumed_at" timestamp with time zone,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "guest_action_tokens_action_type_check" CHECK (("action_type" = ANY (ARRAY['cancel_job'::"text", 'payment_proof'::"text", 'dispute'::"text", 'customer_confirmed'::"text"])))
);


ALTER TABLE "public"."guest_action_tokens" OWNER TO "postgres";

--
-- Name: guest_booking_attempts; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE "public"."guest_booking_attempts" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "phone_hash" "text" NOT NULL,
    "device_key" "text",
    "job_id" "uuid",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."guest_booking_attempts" OWNER TO "postgres";

--
-- Name: guest_customers; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE "public"."guest_customers" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "phone" "text" NOT NULL,
    "location_label" "text",
    "latitude" double precision,
    "longitude" double precision,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "last_seen_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."guest_customers" OWNER TO "postgres";

--
-- Name: guest_otps; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE "public"."guest_otps" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "job_id" "uuid" NOT NULL,
    "action_type" "text" NOT NULL,
    "phone_last4" "text" NOT NULL,
    "code_hash" "text" NOT NULL,
    "request_fingerprint" "text",
    "delivery_status" "text" DEFAULT 'pending'::"text" NOT NULL,
    "attempts" integer DEFAULT 0 NOT NULL,
    "expires_at" timestamp with time zone DEFAULT ("now"() + '00:10:00'::interval) NOT NULL,
    "verified_at" timestamp with time zone,
    "consumed_at" timestamp with time zone,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "metadata" "jsonb" DEFAULT '{}'::"jsonb" NOT NULL,
    CONSTRAINT "guest_otps_action_type_check" CHECK (("action_type" = ANY (ARRAY['cancel_job'::"text", 'payment_proof'::"text", 'dispute'::"text", 'customer_confirmed'::"text", 'dispatch_confirm'::"text"]))),
    CONSTRAINT "guest_otps_delivery_status_check" CHECK (("delivery_status" = ANY (ARRAY['pending'::"text", 'sent'::"text", 'failed'::"text", 'verified'::"text"])))
);


ALTER TABLE "public"."guest_otps" OWNER TO "postgres";

--
-- Name: job_events; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE "public"."job_events" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "job_id" "uuid" NOT NULL,
    "event_type" "text" NOT NULL,
    "actor_role" "text",
    "actor_id" "uuid",
    "public_message" "text",
    "internal_note" "text",
    "metadata" "jsonb" DEFAULT '{}'::"jsonb" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "idempotency_key" "text",
    "severity" "text" DEFAULT 'info'::"text" NOT NULL,
    "visibility" "text" DEFAULT 'public'::"text" NOT NULL,
    "source" "text" DEFAULT 'app'::"text" NOT NULL,
    "event_sequence" bigint NOT NULL,
    "transition_from_version" integer,
    "transition_to_version" integer,
    "projected_status" "public"."job_status",
    "projected_at" timestamp with time zone,
    "request_id" "text",
    "request_hash" "text",
    "replay_of_event_id" "uuid",
    "replay_run_id" "uuid",
    "event_version" integer,
    "transition_id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "payload" "jsonb" DEFAULT '{}'::"jsonb" NOT NULL,
    CONSTRAINT "job_events_event_type_check" CHECK (("event_type" = ANY (ARRAY['JOB_CREATED'::"text", 'PAIRING_STARTED'::"text", 'ELECTRICIAN_ASSIGNED'::"text", 'ASSIGNMENT_ACCEPTED'::"text", 'ASSIGNMENT_REJECTED'::"text", 'ASSIGNMENT_EXPIRED'::"text", 'PAYMENT_SUBMITTED'::"text", 'PAYMENT_VERIFIED'::"text", 'WORK_STARTED'::"text", 'WORK_COMPLETED'::"text", 'CUSTOMER_CONFIRMED'::"text", 'DISPUTE_OPENED'::"text", 'JOB_CANCELLED'::"text", 'QUOTE_SUBMITTED'::"text", 'PAYOUT_RELEASED'::"text", 'RATING_SUBMITTED'::"text", 'JOB_UPDATED'::"text"]))),
    CONSTRAINT "job_events_severity_check" CHECK (("severity" = ANY (ARRAY['info'::"text", 'warning'::"text", 'critical'::"text"]))),
    CONSTRAINT "job_events_visibility_check" CHECK (("visibility" = ANY (ARRAY['public'::"text", 'internal'::"text"])))
);


ALTER TABLE "public"."job_events" OWNER TO "postgres";

--
-- Name: job_state_projections; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE "public"."job_state_projections" (
    "job_id" "uuid" NOT NULL,
    "projected_status" "public"."job_status" NOT NULL,
    "event_id" "uuid",
    "event_sequence" bigint NOT NULL,
    "state_version" integer DEFAULT 0 NOT NULL,
    "projected_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "snapshot_synced_at" timestamp with time zone,
    "conflict_count" integer DEFAULT 0 NOT NULL,
    "metadata" "jsonb" DEFAULT '{}'::"jsonb" NOT NULL
);


ALTER TABLE "public"."job_state_projections" OWNER TO "postgres";

--
-- Name: job_current_state_from_events; Type: VIEW; Schema: public; Owner: postgres
--

CREATE VIEW "public"."job_current_state_from_events" AS
 SELECT "p"."job_id",
    "p"."projected_status" AS "event_status",
    "e"."event_type",
    "p"."event_id",
    "e"."created_at",
    "p"."state_version"
   FROM ("public"."job_state_projections" "p"
     LEFT JOIN "public"."job_events" "e" ON (("e"."id" = "p"."event_id")));


ALTER VIEW "public"."job_current_state_from_events" OWNER TO "postgres";

--
-- Name: job_events_event_sequence_seq; Type: SEQUENCE; Schema: public; Owner: postgres
--

CREATE SEQUENCE "public"."job_events_event_sequence_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE "public"."job_events_event_sequence_seq" OWNER TO "postgres";

--
-- Name: job_events_event_sequence_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: postgres
--

ALTER SEQUENCE "public"."job_events_event_sequence_seq" OWNED BY "public"."job_events"."event_sequence";


--
-- Name: job_messages; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE "public"."job_messages" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "job_id" "uuid" NOT NULL,
    "sender_profile_id" "uuid" NOT NULL,
    "sender_role" "public"."user_role" NOT NULL,
    "message_type" "text" DEFAULT 'text'::"text" NOT NULL,
    "content" "jsonb" DEFAULT '{}'::"jsonb" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."job_messages" OWNER TO "postgres";

--
-- Name: job_photos; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE "public"."job_photos" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "job_id" "uuid" NOT NULL,
    "file_path" "text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."job_photos" OWNER TO "postgres";

--
-- Name: job_timeline; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE "public"."job_timeline" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "job_id" "uuid" NOT NULL,
    "status" "public"."job_status" NOT NULL,
    "note" "text",
    "actor_profile_id" "uuid",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "metadata" "jsonb" DEFAULT '{}'::"jsonb" NOT NULL
);


ALTER TABLE "public"."job_timeline" OWNER TO "postgres";

--
-- Name: job_timeline_from_events; Type: VIEW; Schema: public; Owner: postgres
--

CREATE VIEW "public"."job_timeline_from_events" AS
 SELECT "e"."id" AS "event_id",
    "e"."job_id",
    COALESCE("public"."job_status_for_event"("e"."event_type", "e"."metadata"), "j"."status") AS "status",
    "e"."public_message" AS "note",
        CASE
            WHEN (EXISTS ( SELECT 1
               FROM "public"."profiles" "p"
              WHERE ("p"."id" = "e"."actor_id"))) THEN "e"."actor_id"
            ELSE NULL::"uuid"
        END AS "actor_profile_id",
    "e"."metadata",
    "e"."created_at"
   FROM ("public"."job_events" "e"
     JOIN "public"."jobs" "j" ON (("j"."id" = "e"."job_id")))
  WHERE (NULLIF("btrim"(COALESCE("e"."public_message", ''::"text")), ''::"text") IS NOT NULL);


ALTER VIEW "public"."job_timeline_from_events" OWNER TO "postgres";

--
-- Name: notifications; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE "public"."notifications" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "profile_id" "uuid" NOT NULL,
    "job_id" "uuid",
    "event" "public"."notification_event" NOT NULL,
    "title" "text" NOT NULL,
    "body" "text" NOT NULL,
    "metadata" "jsonb" DEFAULT '{}'::"jsonb" NOT NULL,
    "read_at" timestamp with time zone,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."notifications" OWNER TO "postgres";

--
-- Name: operation_requests; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE "public"."operation_requests" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "request_id" "text" NOT NULL,
    "operation_name" "text" NOT NULL,
    "request_hash" "text" NOT NULL,
    "status" "text" DEFAULT 'running'::"text" NOT NULL,
    "response_payload" "jsonb",
    "error_message" "text",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "completed_at" timestamp with time zone,
    CONSTRAINT "operation_requests_status_check" CHECK (("status" = ANY (ARRAY['running'::"text", 'completed'::"text", 'failed'::"text"])))
);


ALTER TABLE "public"."operation_requests" OWNER TO "postgres";

--
-- Name: operational_automation_runs; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE "public"."operational_automation_runs" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "run_type" "text" DEFAULT 'dispatch_heartbeat'::"text" NOT NULL,
    "status" "text" DEFAULT 'running'::"text" NOT NULL,
    "started_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "finished_at" timestamp with time zone,
    "processed_count" integer DEFAULT 0 NOT NULL,
    "metadata" "jsonb" DEFAULT '{}'::"jsonb" NOT NULL,
    "error_message" "text",
    "request_id" "text",
    "request_hash" "text",
    CONSTRAINT "operational_automation_runs_status_check" CHECK (("status" = ANY (ARRAY['running'::"text", 'completed'::"text", 'failed'::"text"])))
);


ALTER TABLE "public"."operational_automation_runs" OWNER TO "postgres";

--
-- Name: operational_metrics; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE "public"."operational_metrics" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "metric_name" "text" NOT NULL,
    "metric_value" numeric DEFAULT 0 NOT NULL,
    "metric_unit" "text" DEFAULT 'count'::"text" NOT NULL,
    "dimensions" "jsonb" DEFAULT '{}'::"jsonb" NOT NULL,
    "source" "text" DEFAULT 'automation'::"text" NOT NULL,
    "captured_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."operational_metrics" OWNER TO "postgres";

--
-- Name: quote_items; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE "public"."quote_items" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "quote_id" "uuid" NOT NULL,
    "item_type" "text" DEFAULT 'labor'::"text" NOT NULL,
    "description" "text" NOT NULL,
    "quantity" numeric(12,2) DEFAULT 1 NOT NULL,
    "unit_price" numeric(12,2) DEFAULT 0 NOT NULL,
    "line_total" numeric(12,2) DEFAULT 0 NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."quote_items" OWNER TO "postgres";

--
-- Name: wallet_transactions; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE "public"."wallet_transactions" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "wallet_id" "uuid" NOT NULL,
    "profile_id" "uuid" NOT NULL,
    "job_id" "uuid",
    "transaction_type" "text" NOT NULL,
    "amount" numeric(12,2) NOT NULL,
    "note" "text",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."wallet_transactions" OWNER TO "postgres";

--
-- Name: buckets; Type: TABLE; Schema: storage; Owner: supabase_storage_admin
--

CREATE TABLE "storage"."buckets" (
    "id" "text" NOT NULL,
    "name" "text" NOT NULL,
    "owner" "uuid",
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"(),
    "public" boolean DEFAULT false,
    "avif_autodetection" boolean DEFAULT false,
    "file_size_limit" bigint,
    "allowed_mime_types" "text"[],
    "owner_id" "text",
    "type" "storage"."buckettype" DEFAULT 'STANDARD'::"storage"."buckettype" NOT NULL
);


ALTER TABLE "storage"."buckets" OWNER TO "supabase_storage_admin";

--
-- Name: COLUMN "buckets"."owner"; Type: COMMENT; Schema: storage; Owner: supabase_storage_admin
--

COMMENT ON COLUMN "storage"."buckets"."owner" IS 'Field is deprecated, use owner_id instead';


--
-- Name: buckets_analytics; Type: TABLE; Schema: storage; Owner: supabase_storage_admin
--

CREATE TABLE "storage"."buckets_analytics" (
    "name" "text" NOT NULL,
    "type" "storage"."buckettype" DEFAULT 'ANALYTICS'::"storage"."buckettype" NOT NULL,
    "format" "text" DEFAULT 'ICEBERG'::"text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "deleted_at" timestamp with time zone
);


ALTER TABLE "storage"."buckets_analytics" OWNER TO "supabase_storage_admin";

--
-- Name: buckets_vectors; Type: TABLE; Schema: storage; Owner: supabase_storage_admin
--

CREATE TABLE "storage"."buckets_vectors" (
    "id" "text" NOT NULL,
    "type" "storage"."buckettype" DEFAULT 'VECTOR'::"storage"."buckettype" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "storage"."buckets_vectors" OWNER TO "supabase_storage_admin";

--
-- Name: migrations; Type: TABLE; Schema: storage; Owner: supabase_storage_admin
--

CREATE TABLE "storage"."migrations" (
    "id" integer NOT NULL,
    "name" character varying(100) NOT NULL,
    "hash" character varying(40) NOT NULL,
    "executed_at" timestamp without time zone DEFAULT CURRENT_TIMESTAMP
);


ALTER TABLE "storage"."migrations" OWNER TO "supabase_storage_admin";

--
-- Name: objects; Type: TABLE; Schema: storage; Owner: supabase_storage_admin
--

CREATE TABLE "storage"."objects" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "bucket_id" "text",
    "name" "text",
    "owner" "uuid",
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"(),
    "last_accessed_at" timestamp with time zone DEFAULT "now"(),
    "metadata" "jsonb",
    "path_tokens" "text"[] GENERATED ALWAYS AS ("string_to_array"("name", '/'::"text")) STORED,
    "version" "text",
    "owner_id" "text",
    "user_metadata" "jsonb"
);


ALTER TABLE "storage"."objects" OWNER TO "supabase_storage_admin";

--
-- Name: COLUMN "objects"."owner"; Type: COMMENT; Schema: storage; Owner: supabase_storage_admin
--

COMMENT ON COLUMN "storage"."objects"."owner" IS 'Field is deprecated, use owner_id instead';


--
-- Name: s3_multipart_uploads; Type: TABLE; Schema: storage; Owner: supabase_storage_admin
--

CREATE TABLE "storage"."s3_multipart_uploads" (
    "id" "text" NOT NULL,
    "in_progress_size" bigint DEFAULT 0 NOT NULL,
    "upload_signature" "text" NOT NULL,
    "bucket_id" "text" NOT NULL,
    "key" "text" NOT NULL COLLATE "pg_catalog"."C",
    "version" "text" NOT NULL,
    "owner_id" "text",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "user_metadata" "jsonb",
    "metadata" "jsonb"
);


ALTER TABLE "storage"."s3_multipart_uploads" OWNER TO "supabase_storage_admin";

--
-- Name: s3_multipart_uploads_parts; Type: TABLE; Schema: storage; Owner: supabase_storage_admin
--

CREATE TABLE "storage"."s3_multipart_uploads_parts" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "upload_id" "text" NOT NULL,
    "size" bigint DEFAULT 0 NOT NULL,
    "part_number" integer NOT NULL,
    "bucket_id" "text" NOT NULL,
    "key" "text" NOT NULL COLLATE "pg_catalog"."C",
    "etag" "text" NOT NULL,
    "owner_id" "text",
    "version" "text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "storage"."s3_multipart_uploads_parts" OWNER TO "supabase_storage_admin";

--
-- Name: vector_indexes; Type: TABLE; Schema: storage; Owner: supabase_storage_admin
--

CREATE TABLE "storage"."vector_indexes" (
    "id" "text" DEFAULT "gen_random_uuid"() NOT NULL,
    "name" "text" NOT NULL COLLATE "pg_catalog"."C",
    "bucket_id" "text" NOT NULL,
    "data_type" "text" NOT NULL,
    "dimension" integer NOT NULL,
    "distance_metric" "text" NOT NULL,
    "metadata_configuration" "jsonb",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "storage"."vector_indexes" OWNER TO "supabase_storage_admin";

--
-- Name: job_events event_sequence; Type: DEFAULT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."job_events" ALTER COLUMN "event_sequence" SET DEFAULT "nextval"('"public"."job_events_event_sequence_seq"'::"regclass");


--
-- Name: admin_settings admin_settings_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."admin_settings"
    ADD CONSTRAINT "admin_settings_pkey" PRIMARY KEY ("id");


--
-- Name: customer_addresses customer_addresses_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."customer_addresses"
    ADD CONSTRAINT "customer_addresses_pkey" PRIMARY KEY ("id");


--
-- Name: customers customers_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."customers"
    ADD CONSTRAINT "customers_pkey" PRIMARY KEY ("id");


--
-- Name: customers customers_profile_id_key; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."customers"
    ADD CONSTRAINT "customers_profile_id_key" UNIQUE ("profile_id");


--
-- Name: disputes disputes_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."disputes"
    ADD CONSTRAINT "disputes_pkey" PRIMARY KEY ("id");


--
-- Name: electrician_appeals electrician_appeals_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."electrician_appeals"
    ADD CONSTRAINT "electrician_appeals_pkey" PRIMARY KEY ("id");


--
-- Name: electrician_certifications electrician_certifications_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."electrician_certifications"
    ADD CONSTRAINT "electrician_certifications_pkey" PRIMARY KEY ("id");


--
-- Name: electrician_documents electrician_documents_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."electrician_documents"
    ADD CONSTRAINT "electrician_documents_pkey" PRIMARY KEY ("id");


--
-- Name: electrician_performance_snapshots electrician_performance_snapshots_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."electrician_performance_snapshots"
    ADD CONSTRAINT "electrician_performance_snapshots_pkey" PRIMARY KEY ("id");


--
-- Name: electrician_skills electrician_skills_electrician_id_category_key; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."electrician_skills"
    ADD CONSTRAINT "electrician_skills_electrician_id_category_key" UNIQUE ("electrician_id", "category");


--
-- Name: electrician_skills electrician_skills_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."electrician_skills"
    ADD CONSTRAINT "electrician_skills_pkey" PRIMARY KEY ("id");


--
-- Name: electricians electricians_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."electricians"
    ADD CONSTRAINT "electricians_pkey" PRIMARY KEY ("id");


--
-- Name: electricians electricians_profile_id_key; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."electricians"
    ADD CONSTRAINT "electricians_profile_id_key" UNIQUE ("profile_id");


--
-- Name: event_replay_runs event_replay_runs_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."event_replay_runs"
    ADD CONSTRAINT "event_replay_runs_pkey" PRIMARY KEY ("id");


--
-- Name: expertise_categories expertise_categories_label_key; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."expertise_categories"
    ADD CONSTRAINT "expertise_categories_label_key" UNIQUE ("label");


--
-- Name: expertise_categories expertise_categories_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."expertise_categories"
    ADD CONSTRAINT "expertise_categories_pkey" PRIMARY KEY ("id");


--
-- Name: guest_action_tokens guest_action_tokens_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."guest_action_tokens"
    ADD CONSTRAINT "guest_action_tokens_pkey" PRIMARY KEY ("id");


--
-- Name: guest_action_tokens guest_action_tokens_token_hash_key; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."guest_action_tokens"
    ADD CONSTRAINT "guest_action_tokens_token_hash_key" UNIQUE ("token_hash");


--
-- Name: guest_booking_attempts guest_booking_attempts_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."guest_booking_attempts"
    ADD CONSTRAINT "guest_booking_attempts_pkey" PRIMARY KEY ("id");


--
-- Name: guest_customers guest_customers_phone_key; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."guest_customers"
    ADD CONSTRAINT "guest_customers_phone_key" UNIQUE ("phone");


--
-- Name: guest_customers guest_customers_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."guest_customers"
    ADD CONSTRAINT "guest_customers_pkey" PRIMARY KEY ("id");


--
-- Name: guest_otps guest_otps_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."guest_otps"
    ADD CONSTRAINT "guest_otps_pkey" PRIMARY KEY ("id");


--
-- Name: job_events job_events_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."job_events"
    ADD CONSTRAINT "job_events_pkey" PRIMARY KEY ("id");


--
-- Name: job_messages job_messages_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."job_messages"
    ADD CONSTRAINT "job_messages_pkey" PRIMARY KEY ("id");


--
-- Name: job_payments job_payments_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."job_payments"
    ADD CONSTRAINT "job_payments_pkey" PRIMARY KEY ("id");


--
-- Name: job_payments job_payments_submitter_check; Type: CHECK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE "public"."job_payments"
    ADD CONSTRAINT "job_payments_submitter_check" CHECK ((("submitted_by" IS NOT NULL) OR ("guest_customer_id" IS NOT NULL))) NOT VALID;


--
-- Name: job_photos job_photos_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."job_photos"
    ADD CONSTRAINT "job_photos_pkey" PRIMARY KEY ("id");


--
-- Name: job_quotes job_quotes_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."job_quotes"
    ADD CONSTRAINT "job_quotes_pkey" PRIMARY KEY ("id");


--
-- Name: job_state_projections job_state_projections_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."job_state_projections"
    ADD CONSTRAINT "job_state_projections_pkey" PRIMARY KEY ("job_id");


--
-- Name: job_timeline job_timeline_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."job_timeline"
    ADD CONSTRAINT "job_timeline_pkey" PRIMARY KEY ("id");


--
-- Name: jobs jobs_customer_or_guest_check; Type: CHECK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE "public"."jobs"
    ADD CONSTRAINT "jobs_customer_or_guest_check" CHECK ((("customer_id" IS NOT NULL) OR ("guest_customer_id" IS NOT NULL))) NOT VALID;


--
-- Name: jobs jobs_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."jobs"
    ADD CONSTRAINT "jobs_pkey" PRIMARY KEY ("id");


--
-- Name: jobs jobs_ticket_key; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."jobs"
    ADD CONSTRAINT "jobs_ticket_key" UNIQUE ("ticket");


--
-- Name: notifications notifications_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."notifications"
    ADD CONSTRAINT "notifications_pkey" PRIMARY KEY ("id");


--
-- Name: operation_requests operation_requests_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."operation_requests"
    ADD CONSTRAINT "operation_requests_pkey" PRIMARY KEY ("id");


--
-- Name: operational_alerts operational_alerts_dedupe_key_key; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."operational_alerts"
    ADD CONSTRAINT "operational_alerts_dedupe_key_key" UNIQUE ("dedupe_key");


--
-- Name: operational_alerts operational_alerts_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."operational_alerts"
    ADD CONSTRAINT "operational_alerts_pkey" PRIMARY KEY ("id");


--
-- Name: operational_automation_runs operational_automation_runs_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."operational_automation_runs"
    ADD CONSTRAINT "operational_automation_runs_pkey" PRIMARY KEY ("id");


--
-- Name: operational_metrics operational_metrics_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."operational_metrics"
    ADD CONSTRAINT "operational_metrics_pkey" PRIMARY KEY ("id");


--
-- Name: profiles profiles_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."profiles"
    ADD CONSTRAINT "profiles_pkey" PRIMARY KEY ("id");


--
-- Name: quote_items quote_items_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."quote_items"
    ADD CONSTRAINT "quote_items_pkey" PRIMARY KEY ("id");


--
-- Name: ratings ratings_job_direction_key; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."ratings"
    ADD CONSTRAINT "ratings_job_direction_key" UNIQUE ("job_id", "review_direction");


--
-- Name: ratings ratings_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."ratings"
    ADD CONSTRAINT "ratings_pkey" PRIMARY KEY ("id");


--
-- Name: referrals referrals_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."referrals"
    ADD CONSTRAINT "referrals_pkey" PRIMARY KEY ("id");


--
-- Name: referrals referrals_referred_profile_id_key; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."referrals"
    ADD CONSTRAINT "referrals_referred_profile_id_key" UNIQUE ("referred_profile_id");


--
-- Name: system_health_snapshots system_health_snapshots_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."system_health_snapshots"
    ADD CONSTRAINT "system_health_snapshots_pkey" PRIMARY KEY ("id");


--
-- Name: upload_failures upload_failures_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."upload_failures"
    ADD CONSTRAINT "upload_failures_pkey" PRIMARY KEY ("id");


--
-- Name: wallet_transactions wallet_transactions_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."wallet_transactions"
    ADD CONSTRAINT "wallet_transactions_pkey" PRIMARY KEY ("id");


--
-- Name: wallets wallets_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."wallets"
    ADD CONSTRAINT "wallets_pkey" PRIMARY KEY ("id");


--
-- Name: wallets wallets_profile_id_key; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."wallets"
    ADD CONSTRAINT "wallets_profile_id_key" UNIQUE ("profile_id");


--
-- Name: buckets_analytics buckets_analytics_pkey; Type: CONSTRAINT; Schema: storage; Owner: supabase_storage_admin
--

ALTER TABLE ONLY "storage"."buckets_analytics"
    ADD CONSTRAINT "buckets_analytics_pkey" PRIMARY KEY ("id");


--
-- Name: buckets buckets_pkey; Type: CONSTRAINT; Schema: storage; Owner: supabase_storage_admin
--

ALTER TABLE ONLY "storage"."buckets"
    ADD CONSTRAINT "buckets_pkey" PRIMARY KEY ("id");


--
-- Name: buckets_vectors buckets_vectors_pkey; Type: CONSTRAINT; Schema: storage; Owner: supabase_storage_admin
--

ALTER TABLE ONLY "storage"."buckets_vectors"
    ADD CONSTRAINT "buckets_vectors_pkey" PRIMARY KEY ("id");


--
-- Name: migrations migrations_name_key; Type: CONSTRAINT; Schema: storage; Owner: supabase_storage_admin
--

ALTER TABLE ONLY "storage"."migrations"
    ADD CONSTRAINT "migrations_name_key" UNIQUE ("name");


--
-- Name: migrations migrations_pkey; Type: CONSTRAINT; Schema: storage; Owner: supabase_storage_admin
--

ALTER TABLE ONLY "storage"."migrations"
    ADD CONSTRAINT "migrations_pkey" PRIMARY KEY ("id");


--
-- Name: objects objects_pkey; Type: CONSTRAINT; Schema: storage; Owner: supabase_storage_admin
--

ALTER TABLE ONLY "storage"."objects"
    ADD CONSTRAINT "objects_pkey" PRIMARY KEY ("id");


--
-- Name: s3_multipart_uploads_parts s3_multipart_uploads_parts_pkey; Type: CONSTRAINT; Schema: storage; Owner: supabase_storage_admin
--

ALTER TABLE ONLY "storage"."s3_multipart_uploads_parts"
    ADD CONSTRAINT "s3_multipart_uploads_parts_pkey" PRIMARY KEY ("id");


--
-- Name: s3_multipart_uploads s3_multipart_uploads_pkey; Type: CONSTRAINT; Schema: storage; Owner: supabase_storage_admin
--

ALTER TABLE ONLY "storage"."s3_multipart_uploads"
    ADD CONSTRAINT "s3_multipart_uploads_pkey" PRIMARY KEY ("id");


--
-- Name: vector_indexes vector_indexes_pkey; Type: CONSTRAINT; Schema: storage; Owner: supabase_storage_admin
--

ALTER TABLE ONLY "storage"."vector_indexes"
    ADD CONSTRAINT "vector_indexes_pkey" PRIMARY KEY ("id");


--
-- Name: customer_addresses_profile_address_idx; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX "customer_addresses_profile_address_idx" ON "public"."customer_addresses" USING "btree" ("profile_id", "lower"("address_text"));


--
-- Name: customer_addresses_profile_idx; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX "customer_addresses_profile_idx" ON "public"."customer_addresses" USING "btree" ("profile_id", "last_used_at" DESC);


--
-- Name: electrician_appeals_electrician_id_idx; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX "electrician_appeals_electrician_id_idx" ON "public"."electrician_appeals" USING "btree" ("electrician_id");


--
-- Name: electrician_performance_snapshots_electrician_idx; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX "electrician_performance_snapshots_electrician_idx" ON "public"."electrician_performance_snapshots" USING "btree" ("electrician_id", "snapshot_at" DESC);


--
-- Name: event_replay_runs_job_started_idx; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX "event_replay_runs_job_started_idx" ON "public"."event_replay_runs" USING "btree" ("job_id", "started_at" DESC) WHERE ("job_id" IS NOT NULL);


--
-- Name: event_replay_runs_request_id_uidx; Type: INDEX; Schema: public; Owner: postgres
--

CREATE UNIQUE INDEX "event_replay_runs_request_id_uidx" ON "public"."event_replay_runs" USING "btree" ("request_id") WHERE ("request_id" IS NOT NULL);


--
-- Name: event_replay_runs_status_started_idx; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX "event_replay_runs_status_started_idx" ON "public"."event_replay_runs" USING "btree" ("status", "started_at" DESC);


--
-- Name: guest_action_tokens_job_action_idx; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX "guest_action_tokens_job_action_idx" ON "public"."guest_action_tokens" USING "btree" ("job_id", "action_type", "expires_at" DESC);


--
-- Name: guest_booking_attempts_device_created_idx; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX "guest_booking_attempts_device_created_idx" ON "public"."guest_booking_attempts" USING "btree" ("device_key", "created_at" DESC) WHERE ("device_key" IS NOT NULL);


--
-- Name: guest_booking_attempts_phone_created_idx; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX "guest_booking_attempts_phone_created_idx" ON "public"."guest_booking_attempts" USING "btree" ("phone_hash", "created_at" DESC);


--
-- Name: guest_otps_expiry_idx; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX "guest_otps_expiry_idx" ON "public"."guest_otps" USING "btree" ("expires_at") WHERE (("verified_at" IS NULL) AND ("consumed_at" IS NULL));


--
-- Name: guest_otps_job_action_idx; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX "guest_otps_job_action_idx" ON "public"."guest_otps" USING "btree" ("job_id", "action_type", "created_at" DESC);


--
-- Name: job_events_event_sequence_uidx; Type: INDEX; Schema: public; Owner: postgres
--

CREATE UNIQUE INDEX "job_events_event_sequence_uidx" ON "public"."job_events" USING "btree" ("event_sequence");


--
-- Name: job_events_idempotency_key_uidx; Type: INDEX; Schema: public; Owner: postgres
--

CREATE UNIQUE INDEX "job_events_idempotency_key_uidx" ON "public"."job_events" USING "btree" ("idempotency_key") WHERE ("idempotency_key" IS NOT NULL);


--
-- Name: job_events_job_created_idx; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX "job_events_job_created_idx" ON "public"."job_events" USING "btree" ("job_id", "created_at");


--
-- Name: job_events_job_event_version_idx; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX "job_events_job_event_version_idx" ON "public"."job_events" USING "btree" ("job_id", "event_version" DESC, "event_sequence" DESC);


--
-- Name: job_events_job_type_created_idx; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX "job_events_job_type_created_idx" ON "public"."job_events" USING "btree" ("job_id", "event_type", "created_at" DESC);


--
-- Name: job_events_job_version_idx; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX "job_events_job_version_idx" ON "public"."job_events" USING "btree" ("job_id", "transition_to_version" DESC, "event_sequence" DESC);


--
-- Name: job_events_replay_run_idx; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX "job_events_replay_run_idx" ON "public"."job_events" USING "btree" ("replay_run_id") WHERE ("replay_run_id" IS NOT NULL);


--
-- Name: job_events_request_hash_idx; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX "job_events_request_hash_idx" ON "public"."job_events" USING "btree" ("request_hash") WHERE ("request_hash" IS NOT NULL);


--
-- Name: job_events_request_id_uidx; Type: INDEX; Schema: public; Owner: postgres
--

CREATE UNIQUE INDEX "job_events_request_id_uidx" ON "public"."job_events" USING "btree" ("request_id") WHERE ("request_id" IS NOT NULL);


--
-- Name: job_events_transition_id_uidx; Type: INDEX; Schema: public; Owner: postgres
--

CREATE UNIQUE INDEX "job_events_transition_id_uidx" ON "public"."job_events" USING "btree" ("transition_id");


--
-- Name: job_events_type_created_idx; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX "job_events_type_created_idx" ON "public"."job_events" USING "btree" ("event_type", "created_at" DESC);


--
-- Name: job_payments_one_submitted_per_job_idx; Type: INDEX; Schema: public; Owner: postgres
--

CREATE UNIQUE INDEX "job_payments_one_submitted_per_job_idx" ON "public"."job_payments" USING "btree" ("job_id") WHERE ("status" = 'submitted'::"public"."payment_status");


--
-- Name: job_state_projections_status_idx; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX "job_state_projections_status_idx" ON "public"."job_state_projections" USING "btree" ("projected_status", "projected_at" DESC);


--
-- Name: jobs_current_assignment_event_idx; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX "jobs_current_assignment_event_idx" ON "public"."jobs" USING "btree" ("current_assignment_event_id") WHERE ("current_assignment_event_id" IS NOT NULL);


--
-- Name: jobs_current_assignment_token_idx; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX "jobs_current_assignment_token_idx" ON "public"."jobs" USING "btree" ("current_assignment_token") WHERE ("current_assignment_token" IS NOT NULL);


--
-- Name: jobs_customer_access_token_key; Type: INDEX; Schema: public; Owner: postgres
--

CREATE UNIQUE INDEX "jobs_customer_access_token_key" ON "public"."jobs" USING "btree" ("customer_access_token") WHERE ("customer_access_token" IS NOT NULL);


--
-- Name: jobs_dispatch_priority_idx; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX "jobs_dispatch_priority_idx" ON "public"."jobs" USING "btree" ("dispatch_priority_score" DESC, "created_at") WHERE ("status" = ANY (ARRAY['requested'::"public"."job_status", 'matching'::"public"."job_status", 'assigned'::"public"."job_status"]));


--
-- Name: operation_requests_request_id_uidx; Type: INDEX; Schema: public; Owner: postgres
--

CREATE UNIQUE INDEX "operation_requests_request_id_uidx" ON "public"."operation_requests" USING "btree" ("request_id");


--
-- Name: operation_requests_status_updated_idx; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX "operation_requests_status_updated_idx" ON "public"."operation_requests" USING "btree" ("status", "updated_at" DESC);


--
-- Name: operational_alerts_created_idx; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX "operational_alerts_created_idx" ON "public"."operational_alerts" USING "btree" ("created_at" DESC);


--
-- Name: operational_alerts_escalation_idx; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX "operational_alerts_escalation_idx" ON "public"."operational_alerts" USING "btree" ("status", "escalation_level" DESC, "next_review_at");


--
-- Name: operational_alerts_job_idx; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX "operational_alerts_job_idx" ON "public"."operational_alerts" USING "btree" ("job_id") WHERE ("job_id" IS NOT NULL);


--
-- Name: operational_alerts_status_type_idx; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX "operational_alerts_status_type_idx" ON "public"."operational_alerts" USING "btree" ("status", "alert_type", "last_seen_at" DESC);


--
-- Name: operational_automation_runs_request_id_uidx; Type: INDEX; Schema: public; Owner: postgres
--

CREATE UNIQUE INDEX "operational_automation_runs_request_id_uidx" ON "public"."operational_automation_runs" USING "btree" ("request_id") WHERE ("request_id" IS NOT NULL);


--
-- Name: operational_automation_runs_started_idx; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX "operational_automation_runs_started_idx" ON "public"."operational_automation_runs" USING "btree" ("started_at" DESC);


--
-- Name: operational_metrics_name_captured_idx; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX "operational_metrics_name_captured_idx" ON "public"."operational_metrics" USING "btree" ("metric_name", "captured_at" DESC);


--
-- Name: profiles_referral_code_key; Type: INDEX; Schema: public; Owner: postgres
--

CREATE UNIQUE INDEX "profiles_referral_code_key" ON "public"."profiles" USING "btree" ("referral_code") WHERE ("referral_code" IS NOT NULL);


--
-- Name: ratings_review_direction_idx; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX "ratings_review_direction_idx" ON "public"."ratings" USING "btree" ("review_direction");


--
-- Name: system_health_snapshots_captured_idx; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX "system_health_snapshots_captured_idx" ON "public"."system_health_snapshots" USING "btree" ("captured_at" DESC);


--
-- Name: upload_failures_created_idx; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX "upload_failures_created_idx" ON "public"."upload_failures" USING "btree" ("created_at" DESC);


--
-- Name: upload_failures_job_idx; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX "upload_failures_job_idx" ON "public"."upload_failures" USING "btree" ("job_id") WHERE ("job_id" IS NOT NULL);


--
-- Name: bname; Type: INDEX; Schema: storage; Owner: supabase_storage_admin
--

CREATE UNIQUE INDEX "bname" ON "storage"."buckets" USING "btree" ("name");


--
-- Name: bucketid_objname; Type: INDEX; Schema: storage; Owner: supabase_storage_admin
--

CREATE UNIQUE INDEX "bucketid_objname" ON "storage"."objects" USING "btree" ("bucket_id", "name");


--
-- Name: buckets_analytics_unique_name_idx; Type: INDEX; Schema: storage; Owner: supabase_storage_admin
--

CREATE UNIQUE INDEX "buckets_analytics_unique_name_idx" ON "storage"."buckets_analytics" USING "btree" ("name") WHERE ("deleted_at" IS NULL);


--
-- Name: idx_multipart_uploads_list; Type: INDEX; Schema: storage; Owner: supabase_storage_admin
--

CREATE INDEX "idx_multipart_uploads_list" ON "storage"."s3_multipart_uploads" USING "btree" ("bucket_id", "key", "created_at");


--
-- Name: idx_objects_bucket_id_name; Type: INDEX; Schema: storage; Owner: supabase_storage_admin
--

CREATE INDEX "idx_objects_bucket_id_name" ON "storage"."objects" USING "btree" ("bucket_id", "name" COLLATE "C");


--
-- Name: idx_objects_bucket_id_name_lower; Type: INDEX; Schema: storage; Owner: supabase_storage_admin
--

CREATE INDEX "idx_objects_bucket_id_name_lower" ON "storage"."objects" USING "btree" ("bucket_id", "lower"("name") COLLATE "C");


--
-- Name: name_prefix_search; Type: INDEX; Schema: storage; Owner: supabase_storage_admin
--

CREATE INDEX "name_prefix_search" ON "storage"."objects" USING "btree" ("name" "text_pattern_ops");


--
-- Name: vector_indexes_name_bucket_id_idx; Type: INDEX; Schema: storage; Owner: supabase_storage_admin
--

CREATE UNIQUE INDEX "vector_indexes_name_bucket_id_idx" ON "storage"."vector_indexes" USING "btree" ("name", "bucket_id");


--
-- Name: admin_settings admin_settings_touch_updated_at; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER "admin_settings_touch_updated_at" BEFORE UPDATE ON "public"."admin_settings" FOR EACH ROW EXECUTE FUNCTION "public"."touch_updated_at"();


--
-- Name: jobs audit_direct_job_status_write_trigger; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER "audit_direct_job_status_write_trigger" AFTER UPDATE OF "status" ON "public"."jobs" FOR EACH ROW EXECUTE FUNCTION "public"."audit_direct_job_status_write"();


--
-- Name: customer_addresses customer_addresses_touch_updated_at; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER "customer_addresses_touch_updated_at" BEFORE UPDATE ON "public"."customer_addresses" FOR EACH ROW EXECUTE FUNCTION "public"."touch_updated_at"();


--
-- Name: customers customers_touch_updated_at; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER "customers_touch_updated_at" BEFORE UPDATE ON "public"."customers" FOR EACH ROW EXECUTE FUNCTION "public"."touch_updated_at"();


--
-- Name: electrician_appeals electrician_appeals_touch_updated_at; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER "electrician_appeals_touch_updated_at" BEFORE UPDATE ON "public"."electrician_appeals" FOR EACH ROW EXECUTE FUNCTION "public"."touch_updated_at"();


--
-- Name: electricians electricians_touch_updated_at; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER "electricians_touch_updated_at" BEFORE UPDATE ON "public"."electricians" FOR EACH ROW EXECUTE FUNCTION "public"."touch_updated_at"();


--
-- Name: jobs enforce_job_status_event_insert_trigger; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE CONSTRAINT TRIGGER "enforce_job_status_event_insert_trigger" AFTER INSERT ON "public"."jobs" DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION "public"."enforce_job_status_event"();


--
-- Name: jobs enforce_job_status_event_update_trigger; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE CONSTRAINT TRIGGER "enforce_job_status_event_update_trigger" AFTER UPDATE OF "status" ON "public"."jobs" DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION "public"."enforce_job_status_event"();


--
-- Name: job_events job_event_to_timeline_trigger; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER "job_event_to_timeline_trigger" AFTER INSERT ON "public"."job_events" FOR EACH ROW EXECUTE FUNCTION "public"."job_event_to_timeline"();


--
-- Name: job_timeline job_timeline_to_event_trigger; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER "job_timeline_to_event_trigger" AFTER INSERT ON "public"."job_timeline" FOR EACH ROW EXECUTE FUNCTION "public"."job_timeline_to_event"();


--
-- Name: jobs jobs_status_notifications; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER "jobs_status_notifications" AFTER UPDATE ON "public"."jobs" FOR EACH ROW EXECUTE FUNCTION "public"."handle_job_status_notifications"();


--
-- Name: jobs jobs_touch_updated_at; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER "jobs_touch_updated_at" BEFORE UPDATE ON "public"."jobs" FOR EACH ROW EXECUTE FUNCTION "public"."touch_updated_at"();


--
-- Name: job_events prepare_job_event_version_trigger; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER "prepare_job_event_version_trigger" BEFORE INSERT ON "public"."job_events" FOR EACH ROW EXECUTE FUNCTION "public"."prepare_job_event_version"();


--
-- Name: profiles profiles_rewards_setup; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER "profiles_rewards_setup" BEFORE INSERT ON "public"."profiles" FOR EACH ROW EXECUTE FUNCTION "public"."handle_profile_rewards_setup"();


--
-- Name: profiles profiles_touch_updated_at; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER "profiles_touch_updated_at" BEFORE UPDATE ON "public"."profiles" FOR EACH ROW EXECUTE FUNCTION "public"."touch_updated_at"();


--
-- Name: profiles profiles_wallet_setup; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER "profiles_wallet_setup" AFTER INSERT ON "public"."profiles" FOR EACH ROW EXECUTE FUNCTION "public"."handle_profile_wallet_setup"();


--
-- Name: job_events project_job_event_state_trigger; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER "project_job_event_state_trigger" AFTER INSERT ON "public"."job_events" FOR EACH ROW EXECUTE FUNCTION "public"."project_job_event_state"();


--
-- Name: electricians sync_electrician_reliability_aliases_trigger; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER "sync_electrician_reliability_aliases_trigger" BEFORE INSERT OR UPDATE OF "response_score", "response_rate", "acceptance_score", "acceptance_rate", "completion_score", "dispute_score", "payout_confidence_score", "payout_reliability_score", "quality_tier" ON "public"."electricians" FOR EACH ROW EXECUTE FUNCTION "public"."sync_electrician_reliability_aliases"();


--
-- Name: electrician_performance_snapshots sync_electrician_snapshot_reliability_aliases_trigger; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER "sync_electrician_snapshot_reliability_aliases_trigger" BEFORE INSERT OR UPDATE OF "score", "quality_tier" ON "public"."electrician_performance_snapshots" FOR EACH ROW EXECUTE FUNCTION "public"."sync_electrician_snapshot_reliability_aliases"();


--
-- Name: job_events sync_job_event_payload_trigger; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER "sync_job_event_payload_trigger" BEFORE INSERT OR UPDATE OF "metadata", "payload" ON "public"."job_events" FOR EACH ROW EXECUTE FUNCTION "public"."sync_job_event_payload"();


--
-- Name: wallets wallets_touch_updated_at; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER "wallets_touch_updated_at" BEFORE UPDATE ON "public"."wallets" FOR EACH ROW EXECUTE FUNCTION "public"."handle_wallets_touch_updated_at"();


--
-- Name: buckets enforce_bucket_name_length_trigger; Type: TRIGGER; Schema: storage; Owner: supabase_storage_admin
--

CREATE TRIGGER "enforce_bucket_name_length_trigger" BEFORE INSERT OR UPDATE OF "name" ON "storage"."buckets" FOR EACH ROW EXECUTE FUNCTION "storage"."enforce_bucket_name_length"();


--
-- Name: buckets protect_buckets_delete; Type: TRIGGER; Schema: storage; Owner: supabase_storage_admin
--

CREATE TRIGGER "protect_buckets_delete" BEFORE DELETE ON "storage"."buckets" FOR EACH STATEMENT EXECUTE FUNCTION "storage"."protect_delete"();


--
-- Name: objects protect_objects_delete; Type: TRIGGER; Schema: storage; Owner: supabase_storage_admin
--

CREATE TRIGGER "protect_objects_delete" BEFORE DELETE ON "storage"."objects" FOR EACH STATEMENT EXECUTE FUNCTION "storage"."protect_delete"();


--
-- Name: objects update_objects_updated_at; Type: TRIGGER; Schema: storage; Owner: supabase_storage_admin
--

CREATE TRIGGER "update_objects_updated_at" BEFORE UPDATE ON "storage"."objects" FOR EACH ROW EXECUTE FUNCTION "storage"."update_updated_at_column"();


--
-- Name: customer_addresses customer_addresses_profile_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."customer_addresses"
    ADD CONSTRAINT "customer_addresses_profile_id_fkey" FOREIGN KEY ("profile_id") REFERENCES "public"."profiles"("id") ON DELETE CASCADE;


--
-- Name: customers customers_profile_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."customers"
    ADD CONSTRAINT "customers_profile_id_fkey" FOREIGN KEY ("profile_id") REFERENCES "public"."profiles"("id") ON DELETE CASCADE;


--
-- Name: disputes disputes_customer_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."disputes"
    ADD CONSTRAINT "disputes_customer_id_fkey" FOREIGN KEY ("customer_id") REFERENCES "public"."customers"("id") ON DELETE CASCADE;


--
-- Name: disputes disputes_electrician_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."disputes"
    ADD CONSTRAINT "disputes_electrician_id_fkey" FOREIGN KEY ("electrician_id") REFERENCES "public"."electricians"("id") ON DELETE SET NULL;


--
-- Name: disputes disputes_guest_customer_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."disputes"
    ADD CONSTRAINT "disputes_guest_customer_id_fkey" FOREIGN KEY ("guest_customer_id") REFERENCES "public"."guest_customers"("id") ON DELETE CASCADE;


--
-- Name: disputes disputes_job_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."disputes"
    ADD CONSTRAINT "disputes_job_id_fkey" FOREIGN KEY ("job_id") REFERENCES "public"."jobs"("id") ON DELETE CASCADE;


--
-- Name: disputes disputes_resolved_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."disputes"
    ADD CONSTRAINT "disputes_resolved_by_fkey" FOREIGN KEY ("resolved_by") REFERENCES "public"."profiles"("id") ON DELETE SET NULL;


--
-- Name: electrician_appeals electrician_appeals_electrician_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."electrician_appeals"
    ADD CONSTRAINT "electrician_appeals_electrician_id_fkey" FOREIGN KEY ("electrician_id") REFERENCES "public"."electricians"("id") ON DELETE CASCADE;


--
-- Name: electrician_appeals electrician_appeals_reviewed_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."electrician_appeals"
    ADD CONSTRAINT "electrician_appeals_reviewed_by_fkey" FOREIGN KEY ("reviewed_by") REFERENCES "public"."profiles"("id") ON DELETE SET NULL;


--
-- Name: electrician_certifications electrician_certifications_electrician_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."electrician_certifications"
    ADD CONSTRAINT "electrician_certifications_electrician_id_fkey" FOREIGN KEY ("electrician_id") REFERENCES "public"."electricians"("id") ON DELETE CASCADE;


--
-- Name: electrician_documents electrician_documents_electrician_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."electrician_documents"
    ADD CONSTRAINT "electrician_documents_electrician_id_fkey" FOREIGN KEY ("electrician_id") REFERENCES "public"."electricians"("id") ON DELETE CASCADE;


--
-- Name: electrician_performance_snapshots electrician_performance_snapshots_electrician_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."electrician_performance_snapshots"
    ADD CONSTRAINT "electrician_performance_snapshots_electrician_id_fkey" FOREIGN KEY ("electrician_id") REFERENCES "public"."electricians"("id") ON DELETE CASCADE;


--
-- Name: electrician_skills electrician_skills_electrician_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."electrician_skills"
    ADD CONSTRAINT "electrician_skills_electrician_id_fkey" FOREIGN KEY ("electrician_id") REFERENCES "public"."electricians"("id") ON DELETE CASCADE;


--
-- Name: electricians electricians_profile_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."electricians"
    ADD CONSTRAINT "electricians_profile_id_fkey" FOREIGN KEY ("profile_id") REFERENCES "public"."profiles"("id") ON DELETE CASCADE;


--
-- Name: event_replay_runs event_replay_runs_job_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."event_replay_runs"
    ADD CONSTRAINT "event_replay_runs_job_id_fkey" FOREIGN KEY ("job_id") REFERENCES "public"."jobs"("id") ON DELETE SET NULL;


--
-- Name: guest_action_tokens guest_action_tokens_job_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."guest_action_tokens"
    ADD CONSTRAINT "guest_action_tokens_job_id_fkey" FOREIGN KEY ("job_id") REFERENCES "public"."jobs"("id") ON DELETE CASCADE;


--
-- Name: guest_booking_attempts guest_booking_attempts_job_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."guest_booking_attempts"
    ADD CONSTRAINT "guest_booking_attempts_job_id_fkey" FOREIGN KEY ("job_id") REFERENCES "public"."jobs"("id") ON DELETE SET NULL;


--
-- Name: guest_otps guest_otps_job_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."guest_otps"
    ADD CONSTRAINT "guest_otps_job_id_fkey" FOREIGN KEY ("job_id") REFERENCES "public"."jobs"("id") ON DELETE CASCADE;


--
-- Name: job_events job_events_job_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."job_events"
    ADD CONSTRAINT "job_events_job_id_fkey" FOREIGN KEY ("job_id") REFERENCES "public"."jobs"("id") ON DELETE CASCADE;


--
-- Name: job_events job_events_replay_of_event_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."job_events"
    ADD CONSTRAINT "job_events_replay_of_event_id_fkey" FOREIGN KEY ("replay_of_event_id") REFERENCES "public"."job_events"("id") ON DELETE SET NULL;


--
-- Name: job_events job_events_replay_run_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."job_events"
    ADD CONSTRAINT "job_events_replay_run_id_fkey" FOREIGN KEY ("replay_run_id") REFERENCES "public"."event_replay_runs"("id") ON DELETE SET NULL;


--
-- Name: job_messages job_messages_job_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."job_messages"
    ADD CONSTRAINT "job_messages_job_id_fkey" FOREIGN KEY ("job_id") REFERENCES "public"."jobs"("id") ON DELETE CASCADE;


--
-- Name: job_messages job_messages_sender_profile_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."job_messages"
    ADD CONSTRAINT "job_messages_sender_profile_id_fkey" FOREIGN KEY ("sender_profile_id") REFERENCES "public"."profiles"("id") ON DELETE CASCADE;


--
-- Name: job_payments job_payments_guest_customer_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."job_payments"
    ADD CONSTRAINT "job_payments_guest_customer_id_fkey" FOREIGN KEY ("guest_customer_id") REFERENCES "public"."guest_customers"("id") ON DELETE SET NULL;


--
-- Name: job_payments job_payments_job_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."job_payments"
    ADD CONSTRAINT "job_payments_job_id_fkey" FOREIGN KEY ("job_id") REFERENCES "public"."jobs"("id") ON DELETE CASCADE;


--
-- Name: job_payments job_payments_submitted_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."job_payments"
    ADD CONSTRAINT "job_payments_submitted_by_fkey" FOREIGN KEY ("submitted_by") REFERENCES "public"."profiles"("id") ON DELETE CASCADE;


--
-- Name: job_payments job_payments_verified_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."job_payments"
    ADD CONSTRAINT "job_payments_verified_by_fkey" FOREIGN KEY ("verified_by") REFERENCES "public"."profiles"("id") ON DELETE SET NULL;


--
-- Name: job_photos job_photos_job_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."job_photos"
    ADD CONSTRAINT "job_photos_job_id_fkey" FOREIGN KEY ("job_id") REFERENCES "public"."jobs"("id") ON DELETE CASCADE;


--
-- Name: job_quotes job_quotes_electrician_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."job_quotes"
    ADD CONSTRAINT "job_quotes_electrician_id_fkey" FOREIGN KEY ("electrician_id") REFERENCES "public"."electricians"("id") ON DELETE CASCADE;


--
-- Name: job_quotes job_quotes_job_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."job_quotes"
    ADD CONSTRAINT "job_quotes_job_id_fkey" FOREIGN KEY ("job_id") REFERENCES "public"."jobs"("id") ON DELETE CASCADE;


--
-- Name: job_state_projections job_state_projections_event_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."job_state_projections"
    ADD CONSTRAINT "job_state_projections_event_id_fkey" FOREIGN KEY ("event_id") REFERENCES "public"."job_events"("id") ON DELETE SET NULL;


--
-- Name: job_state_projections job_state_projections_job_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."job_state_projections"
    ADD CONSTRAINT "job_state_projections_job_id_fkey" FOREIGN KEY ("job_id") REFERENCES "public"."jobs"("id") ON DELETE CASCADE;


--
-- Name: job_timeline job_timeline_actor_profile_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."job_timeline"
    ADD CONSTRAINT "job_timeline_actor_profile_id_fkey" FOREIGN KEY ("actor_profile_id") REFERENCES "public"."profiles"("id") ON DELETE SET NULL;


--
-- Name: job_timeline job_timeline_job_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."job_timeline"
    ADD CONSTRAINT "job_timeline_job_id_fkey" FOREIGN KEY ("job_id") REFERENCES "public"."jobs"("id") ON DELETE CASCADE;


--
-- Name: jobs jobs_assigned_electrician_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."jobs"
    ADD CONSTRAINT "jobs_assigned_electrician_id_fkey" FOREIGN KEY ("assigned_electrician_id") REFERENCES "public"."electricians"("id") ON DELETE SET NULL;


--
-- Name: jobs jobs_current_assignment_event_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."jobs"
    ADD CONSTRAINT "jobs_current_assignment_event_id_fkey" FOREIGN KEY ("current_assignment_event_id") REFERENCES "public"."job_events"("id") ON DELETE SET NULL;


--
-- Name: jobs jobs_current_quote_fk; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."jobs"
    ADD CONSTRAINT "jobs_current_quote_fk" FOREIGN KEY ("current_quote_id") REFERENCES "public"."job_quotes"("id") ON DELETE SET NULL;


--
-- Name: jobs jobs_customer_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."jobs"
    ADD CONSTRAINT "jobs_customer_id_fkey" FOREIGN KEY ("customer_id") REFERENCES "public"."customers"("id") ON DELETE CASCADE;


--
-- Name: jobs jobs_guest_customer_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."jobs"
    ADD CONSTRAINT "jobs_guest_customer_id_fkey" FOREIGN KEY ("guest_customer_id") REFERENCES "public"."guest_customers"("id") ON DELETE SET NULL;


--
-- Name: notifications notifications_job_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."notifications"
    ADD CONSTRAINT "notifications_job_id_fkey" FOREIGN KEY ("job_id") REFERENCES "public"."jobs"("id") ON DELETE CASCADE;


--
-- Name: notifications notifications_profile_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."notifications"
    ADD CONSTRAINT "notifications_profile_id_fkey" FOREIGN KEY ("profile_id") REFERENCES "public"."profiles"("id") ON DELETE CASCADE;


--
-- Name: operational_alerts operational_alerts_dispute_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."operational_alerts"
    ADD CONSTRAINT "operational_alerts_dispute_id_fkey" FOREIGN KEY ("dispute_id") REFERENCES "public"."disputes"("id") ON DELETE CASCADE;


--
-- Name: operational_alerts operational_alerts_electrician_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."operational_alerts"
    ADD CONSTRAINT "operational_alerts_electrician_id_fkey" FOREIGN KEY ("electrician_id") REFERENCES "public"."electricians"("id") ON DELETE CASCADE;


--
-- Name: operational_alerts operational_alerts_event_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."operational_alerts"
    ADD CONSTRAINT "operational_alerts_event_id_fkey" FOREIGN KEY ("event_id") REFERENCES "public"."job_events"("id") ON DELETE SET NULL;


--
-- Name: operational_alerts operational_alerts_job_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."operational_alerts"
    ADD CONSTRAINT "operational_alerts_job_id_fkey" FOREIGN KEY ("job_id") REFERENCES "public"."jobs"("id") ON DELETE CASCADE;


--
-- Name: operational_alerts operational_alerts_payment_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."operational_alerts"
    ADD CONSTRAINT "operational_alerts_payment_id_fkey" FOREIGN KEY ("payment_id") REFERENCES "public"."job_payments"("id") ON DELETE CASCADE;


--
-- Name: profiles profiles_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."profiles"
    ADD CONSTRAINT "profiles_id_fkey" FOREIGN KEY ("id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;


--
-- Name: quote_items quote_items_quote_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."quote_items"
    ADD CONSTRAINT "quote_items_quote_id_fkey" FOREIGN KEY ("quote_id") REFERENCES "public"."job_quotes"("id") ON DELETE CASCADE;


--
-- Name: ratings ratings_customer_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."ratings"
    ADD CONSTRAINT "ratings_customer_id_fkey" FOREIGN KEY ("customer_id") REFERENCES "public"."customers"("id") ON DELETE CASCADE;


--
-- Name: ratings ratings_electrician_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."ratings"
    ADD CONSTRAINT "ratings_electrician_id_fkey" FOREIGN KEY ("electrician_id") REFERENCES "public"."electricians"("id") ON DELETE CASCADE;


--
-- Name: ratings ratings_job_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."ratings"
    ADD CONSTRAINT "ratings_job_id_fkey" FOREIGN KEY ("job_id") REFERENCES "public"."jobs"("id") ON DELETE CASCADE;


--
-- Name: ratings ratings_reviewee_profile_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."ratings"
    ADD CONSTRAINT "ratings_reviewee_profile_id_fkey" FOREIGN KEY ("reviewee_profile_id") REFERENCES "public"."profiles"("id") ON DELETE SET NULL;


--
-- Name: ratings ratings_reviewer_profile_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."ratings"
    ADD CONSTRAINT "ratings_reviewer_profile_id_fkey" FOREIGN KEY ("reviewer_profile_id") REFERENCES "public"."profiles"("id") ON DELETE SET NULL;


--
-- Name: referrals referrals_referred_profile_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."referrals"
    ADD CONSTRAINT "referrals_referred_profile_id_fkey" FOREIGN KEY ("referred_profile_id") REFERENCES "public"."profiles"("id") ON DELETE CASCADE;


--
-- Name: referrals referrals_referrer_profile_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."referrals"
    ADD CONSTRAINT "referrals_referrer_profile_id_fkey" FOREIGN KEY ("referrer_profile_id") REFERENCES "public"."profiles"("id") ON DELETE CASCADE;


--
-- Name: upload_failures upload_failures_job_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."upload_failures"
    ADD CONSTRAINT "upload_failures_job_id_fkey" FOREIGN KEY ("job_id") REFERENCES "public"."jobs"("id") ON DELETE CASCADE;


--
-- Name: wallet_transactions wallet_transactions_job_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."wallet_transactions"
    ADD CONSTRAINT "wallet_transactions_job_id_fkey" FOREIGN KEY ("job_id") REFERENCES "public"."jobs"("id") ON DELETE SET NULL;


--
-- Name: wallet_transactions wallet_transactions_profile_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."wallet_transactions"
    ADD CONSTRAINT "wallet_transactions_profile_id_fkey" FOREIGN KEY ("profile_id") REFERENCES "public"."profiles"("id") ON DELETE CASCADE;


--
-- Name: wallet_transactions wallet_transactions_wallet_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."wallet_transactions"
    ADD CONSTRAINT "wallet_transactions_wallet_id_fkey" FOREIGN KEY ("wallet_id") REFERENCES "public"."wallets"("id") ON DELETE CASCADE;


--
-- Name: wallets wallets_profile_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."wallets"
    ADD CONSTRAINT "wallets_profile_id_fkey" FOREIGN KEY ("profile_id") REFERENCES "public"."profiles"("id") ON DELETE CASCADE;


--
-- Name: objects objects_bucketId_fkey; Type: FK CONSTRAINT; Schema: storage; Owner: supabase_storage_admin
--

ALTER TABLE ONLY "storage"."objects"
    ADD CONSTRAINT "objects_bucketId_fkey" FOREIGN KEY ("bucket_id") REFERENCES "storage"."buckets"("id");


--
-- Name: s3_multipart_uploads s3_multipart_uploads_bucket_id_fkey; Type: FK CONSTRAINT; Schema: storage; Owner: supabase_storage_admin
--

ALTER TABLE ONLY "storage"."s3_multipart_uploads"
    ADD CONSTRAINT "s3_multipart_uploads_bucket_id_fkey" FOREIGN KEY ("bucket_id") REFERENCES "storage"."buckets"("id");


--
-- Name: s3_multipart_uploads_parts s3_multipart_uploads_parts_bucket_id_fkey; Type: FK CONSTRAINT; Schema: storage; Owner: supabase_storage_admin
--

ALTER TABLE ONLY "storage"."s3_multipart_uploads_parts"
    ADD CONSTRAINT "s3_multipart_uploads_parts_bucket_id_fkey" FOREIGN KEY ("bucket_id") REFERENCES "storage"."buckets"("id");


--
-- Name: s3_multipart_uploads_parts s3_multipart_uploads_parts_upload_id_fkey; Type: FK CONSTRAINT; Schema: storage; Owner: supabase_storage_admin
--

ALTER TABLE ONLY "storage"."s3_multipart_uploads_parts"
    ADD CONSTRAINT "s3_multipart_uploads_parts_upload_id_fkey" FOREIGN KEY ("upload_id") REFERENCES "storage"."s3_multipart_uploads"("id") ON DELETE CASCADE;


--
-- Name: vector_indexes vector_indexes_bucket_id_fkey; Type: FK CONSTRAINT; Schema: storage; Owner: supabase_storage_admin
--

ALTER TABLE ONLY "storage"."vector_indexes"
    ADD CONSTRAINT "vector_indexes_bucket_id_fkey" FOREIGN KEY ("bucket_id") REFERENCES "storage"."buckets_vectors"("id");


--
-- Name: admin_settings admin settings admin write; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY "admin settings admin write" ON "public"."admin_settings" USING ("public"."is_admin"()) WITH CHECK ("public"."is_admin"());


--
-- Name: admin_settings admin settings readable by authenticated; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY "admin settings readable by authenticated" ON "public"."admin_settings" FOR SELECT USING (("auth"."uid"() IS NOT NULL));


--
-- Name: admin_settings; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE "public"."admin_settings" ENABLE ROW LEVEL SECURITY;

--
-- Name: operational_automation_runs automation runs admin read; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY "automation runs admin read" ON "public"."operational_automation_runs" FOR SELECT TO "authenticated" USING ("public"."is_admin"());


--
-- Name: operational_automation_runs automation runs service write; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY "automation runs service write" ON "public"."operational_automation_runs" TO "service_role" USING (("auth"."role"() = 'service_role'::"text")) WITH CHECK (("auth"."role"() = 'service_role'::"text"));


--
-- Name: customer_addresses customer addresses owner or admin; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY "customer addresses owner or admin" ON "public"."customer_addresses" USING ((("profile_id" = "auth"."uid"()) OR "public"."is_admin"())) WITH CHECK ((("profile_id" = "auth"."uid"()) OR "public"."is_admin"()));


--
-- Name: customer_addresses; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE "public"."customer_addresses" ENABLE ROW LEVEL SECURITY;

--
-- Name: customers; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE "public"."customers" ENABLE ROW LEVEL SECURITY;

--
-- Name: customers customers self or admin; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY "customers self or admin" ON "public"."customers" USING ((("profile_id" = "auth"."uid"()) OR "public"."is_admin"())) WITH CHECK ((("profile_id" = "auth"."uid"()) OR "public"."is_admin"()));


--
-- Name: disputes; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE "public"."disputes" ENABLE ROW LEVEL SECURITY;

--
-- Name: disputes disputes admin update; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY "disputes admin update" ON "public"."disputes" FOR UPDATE USING ("public"."is_admin"()) WITH CHECK ("public"."is_admin"());


--
-- Name: disputes disputes customer electrician or admin read; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY "disputes customer electrician or admin read" ON "public"."disputes" FOR SELECT USING (("public"."is_admin"() OR ("customer_id" = "public"."current_customer_id"()) OR ("electrician_id" = "public"."current_electrician_id"())));


--
-- Name: disputes disputes customer insert; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY "disputes customer insert" ON "public"."disputes" FOR INSERT WITH CHECK ((("customer_id" = "public"."current_customer_id"()) OR "public"."is_admin"()));


--
-- Name: electrician_appeals electrician appeals admin update; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY "electrician appeals admin update" ON "public"."electrician_appeals" FOR UPDATE USING ("public"."is_admin"()) WITH CHECK ("public"."is_admin"());


--
-- Name: electrician_appeals electrician appeals own insert; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY "electrician appeals own insert" ON "public"."electrician_appeals" FOR INSERT WITH CHECK ((("electrician_id" = "public"."current_electrician_id"()) OR "public"."is_admin"()));


--
-- Name: electrician_appeals electrician appeals own or admin read; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY "electrician appeals own or admin read" ON "public"."electrician_appeals" FOR SELECT USING (("public"."is_admin"() OR ("electrician_id" = "public"."current_electrician_id"())));


--
-- Name: electrician_certifications electrician certifications own insert; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY "electrician certifications own insert" ON "public"."electrician_certifications" FOR INSERT TO "authenticated" WITH CHECK (("public"."is_admin"() OR (EXISTS ( SELECT 1
   FROM "public"."electricians" "e"
  WHERE (("e"."id" = "electrician_certifications"."electrician_id") AND ("e"."profile_id" = "auth"."uid"()))))));


--
-- Name: electrician_certifications electrician certifications own or admin read; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY "electrician certifications own or admin read" ON "public"."electrician_certifications" FOR SELECT TO "authenticated" USING (("public"."is_admin"() OR (EXISTS ( SELECT 1
   FROM "public"."electricians" "e"
  WHERE (("e"."id" = "electrician_certifications"."electrician_id") AND ("e"."profile_id" = "auth"."uid"()))))));


--
-- Name: electrician_documents electrician documents visible to owner or admin; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY "electrician documents visible to owner or admin" ON "public"."electrician_documents" USING (("public"."is_admin"() OR (EXISTS ( SELECT 1
   FROM "public"."electricians" "e"
  WHERE (("e"."id" = "electrician_documents"."electrician_id") AND ("e"."profile_id" = "auth"."uid"())))))) WITH CHECK (("public"."is_admin"() OR (EXISTS ( SELECT 1
   FROM "public"."electricians" "e"
  WHERE (("e"."id" = "electrician_documents"."electrician_id") AND ("e"."profile_id" = "auth"."uid"()))))));


--
-- Name: electrician_performance_snapshots electrician performance admin read; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY "electrician performance admin read" ON "public"."electrician_performance_snapshots" FOR SELECT USING ("public"."is_admin"());


--
-- Name: electrician_performance_snapshots electrician performance service write; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY "electrician performance service write" ON "public"."electrician_performance_snapshots" USING (("auth"."role"() = 'service_role'::"text")) WITH CHECK (("auth"."role"() = 'service_role'::"text"));


--
-- Name: electrician_skills electrician skills owner or admin write; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY "electrician skills owner or admin write" ON "public"."electrician_skills" USING (("public"."is_admin"() OR (EXISTS ( SELECT 1
   FROM "public"."electricians" "e"
  WHERE (("e"."id" = "electrician_skills"."electrician_id") AND ("e"."profile_id" = "auth"."uid"())))))) WITH CHECK (("public"."is_admin"() OR (EXISTS ( SELECT 1
   FROM "public"."electricians" "e"
  WHERE (("e"."id" = "electrician_skills"."electrician_id") AND ("e"."profile_id" = "auth"."uid"()))))));


--
-- Name: electrician_skills electrician skills visible broadly; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY "electrician skills visible broadly" ON "public"."electrician_skills" FOR SELECT USING (true);


--
-- Name: electrician_appeals; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE "public"."electrician_appeals" ENABLE ROW LEVEL SECURITY;

--
-- Name: electrician_certifications; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE "public"."electrician_certifications" ENABLE ROW LEVEL SECURITY;

--
-- Name: electrician_documents; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE "public"."electrician_documents" ENABLE ROW LEVEL SECURITY;

--
-- Name: electrician_performance_snapshots; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE "public"."electrician_performance_snapshots" ENABLE ROW LEVEL SECURITY;

--
-- Name: electrician_skills; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE "public"."electrician_skills" ENABLE ROW LEVEL SECURITY;

--
-- Name: electricians; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE "public"."electricians" ENABLE ROW LEVEL SECURITY;

--
-- Name: electricians electricians self insert; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY "electricians self insert" ON "public"."electricians" FOR INSERT WITH CHECK (("profile_id" = "auth"."uid"()));


--
-- Name: electricians electricians self or admin read; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY "electricians self or admin read" ON "public"."electricians" FOR SELECT USING ((("profile_id" = "auth"."uid"()) OR "public"."is_admin"() OR ("status" = 'approved'::"public"."electrician_status")));


--
-- Name: electricians electricians self update or admin; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY "electricians self update or admin" ON "public"."electricians" FOR UPDATE USING ((("profile_id" = "auth"."uid"()) OR "public"."is_admin"())) WITH CHECK ((("profile_id" = "auth"."uid"()) OR "public"."is_admin"()));


--
-- Name: event_replay_runs event replay runs admin read; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY "event replay runs admin read" ON "public"."event_replay_runs" FOR SELECT TO "authenticated" USING ("public"."is_admin"());


--
-- Name: event_replay_runs event replay runs service write; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY "event replay runs service write" ON "public"."event_replay_runs" TO "service_role" USING (("auth"."role"() = 'service_role'::"text")) WITH CHECK (("auth"."role"() = 'service_role'::"text"));


--
-- Name: event_replay_runs; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE "public"."event_replay_runs" ENABLE ROW LEVEL SECURITY;

--
-- Name: expertise_categories expertise categories admin write; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY "expertise categories admin write" ON "public"."expertise_categories" TO "authenticated" USING ("public"."is_admin"()) WITH CHECK ("public"."is_admin"());


--
-- Name: expertise_categories expertise categories readable by all; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY "expertise categories readable by all" ON "public"."expertise_categories" FOR SELECT TO "authenticated", "anon" USING (true);


--
-- Name: expertise_categories; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE "public"."expertise_categories" ENABLE ROW LEVEL SECURITY;

--
-- Name: guest_action_tokens guest action tokens service role only; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY "guest action tokens service role only" ON "public"."guest_action_tokens" USING (("auth"."role"() = 'service_role'::"text")) WITH CHECK (("auth"."role"() = 'service_role'::"text"));


--
-- Name: guest_customers guest customers admin or assigned electrician read; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY "guest customers admin or assigned electrician read" ON "public"."guest_customers" FOR SELECT USING (("public"."is_admin"() OR (EXISTS ( SELECT 1
   FROM "public"."jobs" "j"
  WHERE (("j"."guest_customer_id" = "guest_customers"."id") AND ("j"."assigned_electrician_id" = "public"."current_electrician_id"()))))));


--
-- Name: guest_otps guest otps service role only; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY "guest otps service role only" ON "public"."guest_otps" USING (("auth"."role"() = 'service_role'::"text")) WITH CHECK (("auth"."role"() = 'service_role'::"text"));


--
-- Name: guest_action_tokens; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE "public"."guest_action_tokens" ENABLE ROW LEVEL SECURITY;

--
-- Name: guest_booking_attempts; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE "public"."guest_booking_attempts" ENABLE ROW LEVEL SECURITY;

--
-- Name: guest_customers; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE "public"."guest_customers" ENABLE ROW LEVEL SECURITY;

--
-- Name: guest_otps; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE "public"."guest_otps" ENABLE ROW LEVEL SECURITY;

--
-- Name: job_events job events admin read; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY "job events admin read" ON "public"."job_events" FOR SELECT USING ("public"."is_admin"());


--
-- Name: job_events job events service role write; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY "job events service role write" ON "public"."job_events" USING (("auth"."role"() = 'service_role'::"text")) WITH CHECK (("auth"."role"() = 'service_role'::"text"));


--
-- Name: job_messages job messages customer electrician or admin read; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY "job messages customer electrician or admin read" ON "public"."job_messages" FOR SELECT USING (("public"."is_admin"() OR (EXISTS ( SELECT 1
   FROM "public"."jobs" "j"
  WHERE (("j"."id" = "job_messages"."job_id") AND (("j"."customer_id" = "public"."current_customer_id"()) OR ("j"."assigned_electrician_id" = "public"."current_electrician_id"())))))));


--
-- Name: job_messages job messages customer electrician or admin write; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY "job messages customer electrician or admin write" ON "public"."job_messages" FOR INSERT WITH CHECK (("public"."is_admin"() OR ("sender_profile_id" = "auth"."uid"())));


--
-- Name: job_payments job payments customer electrician or admin; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY "job payments customer electrician or admin" ON "public"."job_payments" FOR SELECT USING (("public"."is_admin"() OR (EXISTS ( SELECT 1
   FROM "public"."jobs" "j"
  WHERE (("j"."id" = "job_payments"."job_id") AND (("j"."customer_id" = "public"."current_customer_id"()) OR ("j"."assigned_electrician_id" = "public"."current_electrician_id"())))))));


--
-- Name: job_photos job photos customer electrician or admin; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY "job photos customer electrician or admin" ON "public"."job_photos" FOR SELECT USING (("public"."is_admin"() OR (EXISTS ( SELECT 1
   FROM "public"."jobs" "j"
  WHERE (("j"."id" = "job_photos"."job_id") AND (("j"."customer_id" = "public"."current_customer_id"()) OR ("j"."assigned_electrician_id" = "public"."current_electrician_id"())))))));


--
-- Name: job_quotes job quotes customer electrician or admin; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY "job quotes customer electrician or admin" ON "public"."job_quotes" FOR SELECT USING (("public"."is_admin"() OR (EXISTS ( SELECT 1
   FROM "public"."jobs" "j"
  WHERE (("j"."id" = "job_quotes"."job_id") AND (("j"."customer_id" = "public"."current_customer_id"()) OR ("j"."assigned_electrician_id" = "public"."current_electrician_id"())))))));


--
-- Name: job_state_projections job state projections admin read; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY "job state projections admin read" ON "public"."job_state_projections" FOR SELECT TO "authenticated" USING ("public"."is_admin"());


--
-- Name: job_state_projections job state projections service write; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY "job state projections service write" ON "public"."job_state_projections" TO "service_role" USING (("auth"."role"() = 'service_role'::"text")) WITH CHECK (("auth"."role"() = 'service_role'::"text"));


--
-- Name: job_timeline job timeline customer electrician or admin; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY "job timeline customer electrician or admin" ON "public"."job_timeline" FOR SELECT USING (("public"."is_admin"() OR (EXISTS ( SELECT 1
   FROM "public"."jobs" "j"
  WHERE (("j"."id" = "job_timeline"."job_id") AND (("j"."customer_id" = "public"."current_customer_id"()) OR ("j"."assigned_electrician_id" = "public"."current_electrician_id"())))))));


--
-- Name: job_events; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE "public"."job_events" ENABLE ROW LEVEL SECURITY;

--
-- Name: job_messages; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE "public"."job_messages" ENABLE ROW LEVEL SECURITY;

--
-- Name: job_payments; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE "public"."job_payments" ENABLE ROW LEVEL SECURITY;

--
-- Name: job_photos; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE "public"."job_photos" ENABLE ROW LEVEL SECURITY;

--
-- Name: job_quotes; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE "public"."job_quotes" ENABLE ROW LEVEL SECURITY;

--
-- Name: job_state_projections; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE "public"."job_state_projections" ENABLE ROW LEVEL SECURITY;

--
-- Name: job_timeline; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE "public"."job_timeline" ENABLE ROW LEVEL SECURITY;

--
-- Name: jobs; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE "public"."jobs" ENABLE ROW LEVEL SECURITY;

--
-- Name: jobs jobs customer electrician or admin; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY "jobs customer electrician or admin" ON "public"."jobs" FOR SELECT USING (("public"."is_admin"() OR ("customer_id" = "public"."current_customer_id"()) OR ("assigned_electrician_id" = "public"."current_electrician_id"())));


--
-- Name: notifications; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE "public"."notifications" ENABLE ROW LEVEL SECURITY;

--
-- Name: notifications notifications own or admin; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY "notifications own or admin" ON "public"."notifications" FOR SELECT USING ((("profile_id" = "auth"."uid"()) OR "public"."is_admin"()));


--
-- Name: notifications notifications own update; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY "notifications own update" ON "public"."notifications" FOR UPDATE USING ((("profile_id" = "auth"."uid"()) OR "public"."is_admin"())) WITH CHECK ((("profile_id" = "auth"."uid"()) OR "public"."is_admin"()));


--
-- Name: operation_requests operation requests admin read; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY "operation requests admin read" ON "public"."operation_requests" FOR SELECT TO "authenticated" USING ("public"."is_admin"());


--
-- Name: operation_requests operation requests service write; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY "operation requests service write" ON "public"."operation_requests" TO "service_role" USING (("auth"."role"() = 'service_role'::"text")) WITH CHECK (("auth"."role"() = 'service_role'::"text"));


--
-- Name: operation_requests; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE "public"."operation_requests" ENABLE ROW LEVEL SECURITY;

--
-- Name: operational_alerts operational alerts admin read; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY "operational alerts admin read" ON "public"."operational_alerts" FOR SELECT USING ("public"."is_admin"());


--
-- Name: operational_alerts operational alerts service write; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY "operational alerts service write" ON "public"."operational_alerts" USING (("auth"."role"() = 'service_role'::"text")) WITH CHECK (("auth"."role"() = 'service_role'::"text"));


--
-- Name: operational_metrics operational metrics admin read; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY "operational metrics admin read" ON "public"."operational_metrics" FOR SELECT TO "authenticated" USING ("public"."is_admin"());


--
-- Name: operational_metrics operational metrics service write; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY "operational metrics service write" ON "public"."operational_metrics" TO "service_role" USING (("auth"."role"() = 'service_role'::"text")) WITH CHECK (("auth"."role"() = 'service_role'::"text"));


--
-- Name: operational_alerts; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE "public"."operational_alerts" ENABLE ROW LEVEL SECURITY;

--
-- Name: operational_automation_runs; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE "public"."operational_automation_runs" ENABLE ROW LEVEL SECURITY;

--
-- Name: operational_metrics; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE "public"."operational_metrics" ENABLE ROW LEVEL SECURITY;

--
-- Name: profiles; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE "public"."profiles" ENABLE ROW LEVEL SECURITY;

--
-- Name: profiles profiles self or admin; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY "profiles self or admin" ON "public"."profiles" FOR SELECT USING ((("auth"."uid"() = "id") OR "public"."is_admin"()));


--
-- Name: profiles profiles self update; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY "profiles self update" ON "public"."profiles" FOR UPDATE USING (("auth"."uid"() = "id")) WITH CHECK (("auth"."uid"() = "id"));


--
-- Name: quote_items quote items customer electrician or admin; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY "quote items customer electrician or admin" ON "public"."quote_items" FOR SELECT USING (("public"."is_admin"() OR (EXISTS ( SELECT 1
   FROM ("public"."job_quotes" "q"
     JOIN "public"."jobs" "j" ON (("j"."id" = "q"."job_id")))
  WHERE (("q"."id" = "quote_items"."quote_id") AND (("j"."customer_id" = "public"."current_customer_id"()) OR ("j"."assigned_electrician_id" = "public"."current_electrician_id"())))))));


--
-- Name: quote_items; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE "public"."quote_items" ENABLE ROW LEVEL SECURITY;

--
-- Name: ratings; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE "public"."ratings" ENABLE ROW LEVEL SECURITY;

--
-- Name: ratings ratings customer electrician or admin; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY "ratings customer electrician or admin" ON "public"."ratings" FOR SELECT USING (("public"."is_admin"() OR ("customer_id" = "public"."current_customer_id"()) OR ("electrician_id" = "public"."current_electrician_id"())));


--
-- Name: referrals; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE "public"."referrals" ENABLE ROW LEVEL SECURITY;

--
-- Name: referrals referrals admin update; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY "referrals admin update" ON "public"."referrals" FOR UPDATE USING ("public"."is_admin"()) WITH CHECK ("public"."is_admin"());


--
-- Name: referrals referrals self insert; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY "referrals self insert" ON "public"."referrals" FOR INSERT WITH CHECK ((("referred_profile_id" = "auth"."uid"()) OR "public"."is_admin"()));


--
-- Name: referrals referrals self or admin read; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY "referrals self or admin read" ON "public"."referrals" FOR SELECT USING ((("referrer_profile_id" = "auth"."uid"()) OR ("referred_profile_id" = "auth"."uid"()) OR "public"."is_admin"()));


--
-- Name: system_health_snapshots system health snapshots admin read; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY "system health snapshots admin read" ON "public"."system_health_snapshots" FOR SELECT TO "authenticated" USING ("public"."is_admin"());


--
-- Name: system_health_snapshots system health snapshots service write; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY "system health snapshots service write" ON "public"."system_health_snapshots" TO "service_role" USING (("auth"."role"() = 'service_role'::"text")) WITH CHECK (("auth"."role"() = 'service_role'::"text"));


--
-- Name: system_health_snapshots; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE "public"."system_health_snapshots" ENABLE ROW LEVEL SECURITY;

--
-- Name: upload_failures upload failures admin read; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY "upload failures admin read" ON "public"."upload_failures" FOR SELECT USING ("public"."is_admin"());


--
-- Name: upload_failures upload failures service write; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY "upload failures service write" ON "public"."upload_failures" USING (("auth"."role"() = 'service_role'::"text")) WITH CHECK (("auth"."role"() = 'service_role'::"text"));


--
-- Name: upload_failures; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE "public"."upload_failures" ENABLE ROW LEVEL SECURITY;

--
-- Name: wallet_transactions wallet transactions admin write; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY "wallet transactions admin write" ON "public"."wallet_transactions" USING ("public"."is_admin"()) WITH CHECK ("public"."is_admin"());


--
-- Name: wallet_transactions wallet transactions self or admin; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY "wallet transactions self or admin" ON "public"."wallet_transactions" FOR SELECT USING ((("profile_id" = "auth"."uid"()) OR "public"."is_admin"()));


--
-- Name: wallet_transactions; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE "public"."wallet_transactions" ENABLE ROW LEVEL SECURITY;

--
-- Name: wallets; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE "public"."wallets" ENABLE ROW LEVEL SECURITY;

--
-- Name: wallets wallets admin write; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY "wallets admin write" ON "public"."wallets" USING ("public"."is_admin"()) WITH CHECK ("public"."is_admin"());


--
-- Name: wallets wallets self or admin; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY "wallets self or admin" ON "public"."wallets" FOR SELECT USING ((("profile_id" = "auth"."uid"()) OR "public"."is_admin"()));


--
-- Name: buckets; Type: ROW SECURITY; Schema: storage; Owner: supabase_storage_admin
--

ALTER TABLE "storage"."buckets" ENABLE ROW LEVEL SECURITY;

--
-- Name: buckets_analytics; Type: ROW SECURITY; Schema: storage; Owner: supabase_storage_admin
--

ALTER TABLE "storage"."buckets_analytics" ENABLE ROW LEVEL SECURITY;

--
-- Name: buckets_vectors; Type: ROW SECURITY; Schema: storage; Owner: supabase_storage_admin
--

ALTER TABLE "storage"."buckets_vectors" ENABLE ROW LEVEL SECURITY;

--
-- Name: migrations; Type: ROW SECURITY; Schema: storage; Owner: supabase_storage_admin
--

ALTER TABLE "storage"."migrations" ENABLE ROW LEVEL SECURITY;

--
-- Name: objects; Type: ROW SECURITY; Schema: storage; Owner: supabase_storage_admin
--

ALTER TABLE "storage"."objects" ENABLE ROW LEVEL SECURITY;

--
-- Name: s3_multipart_uploads; Type: ROW SECURITY; Schema: storage; Owner: supabase_storage_admin
--

ALTER TABLE "storage"."s3_multipart_uploads" ENABLE ROW LEVEL SECURITY;

--
-- Name: s3_multipart_uploads_parts; Type: ROW SECURITY; Schema: storage; Owner: supabase_storage_admin
--

ALTER TABLE "storage"."s3_multipart_uploads_parts" ENABLE ROW LEVEL SECURITY;

--
-- Name: vector_indexes; Type: ROW SECURITY; Schema: storage; Owner: supabase_storage_admin
--

ALTER TABLE "storage"."vector_indexes" ENABLE ROW LEVEL SECURITY;

--
-- Name: objects voltfriq authenticated job photo update; Type: POLICY; Schema: storage; Owner: supabase_storage_admin
--

CREATE POLICY "voltfriq authenticated job photo update" ON "storage"."objects" FOR UPDATE TO "authenticated" USING ((("bucket_id" = 'job-photos'::"text") AND (("owner" = "auth"."uid"()) OR "public"."is_admin"()))) WITH CHECK ((("bucket_id" = 'job-photos'::"text") AND (("owner" = "auth"."uid"()) OR "public"."is_admin"())));


--
-- Name: objects voltfriq authenticated job photo write; Type: POLICY; Schema: storage; Owner: supabase_storage_admin
--

CREATE POLICY "voltfriq authenticated job photo write" ON "storage"."objects" FOR INSERT TO "authenticated" WITH CHECK ((("bucket_id" = 'job-photos'::"text") AND ("split_part"("name", '/'::"text", 1) = 'job-photos'::"text") AND ("split_part"("name", '/'::"text", 2) = ("auth"."uid"())::"text")));


--
-- Name: objects voltfriq authenticated payment proof update; Type: POLICY; Schema: storage; Owner: supabase_storage_admin
--

CREATE POLICY "voltfriq authenticated payment proof update" ON "storage"."objects" FOR UPDATE TO "authenticated" USING ((("bucket_id" = 'payment-proofs'::"text") AND (("owner" = "auth"."uid"()) OR "public"."is_admin"()))) WITH CHECK ((("bucket_id" = 'payment-proofs'::"text") AND (("owner" = "auth"."uid"()) OR "public"."is_admin"())));


--
-- Name: objects voltfriq authenticated payment proof write; Type: POLICY; Schema: storage; Owner: supabase_storage_admin
--

CREATE POLICY "voltfriq authenticated payment proof write" ON "storage"."objects" FOR INSERT TO "authenticated" WITH CHECK ((("bucket_id" = 'payment-proofs'::"text") AND ("public"."is_admin"() OR ("split_part"("name", '/'::"text", 1) = 'payments'::"text"))));


--
-- Name: objects voltfriq avatar owner update; Type: POLICY; Schema: storage; Owner: supabase_storage_admin
--

CREATE POLICY "voltfriq avatar owner update" ON "storage"."objects" FOR UPDATE TO "authenticated" USING ((("bucket_id" = 'avatars'::"text") AND (("owner" = "auth"."uid"()) OR "public"."is_admin"()))) WITH CHECK ((("bucket_id" = 'avatars'::"text") AND (("owner" = "auth"."uid"()) OR "public"."is_admin"())));


--
-- Name: objects voltfriq avatar owner write; Type: POLICY; Schema: storage; Owner: supabase_storage_admin
--

CREATE POLICY "voltfriq avatar owner write" ON "storage"."objects" FOR INSERT TO "authenticated" WITH CHECK ((("bucket_id" = 'avatars'::"text") AND ("owner" = "auth"."uid"()) AND ("split_part"("name", '/'::"text", 1) = ("auth"."uid"())::"text")));


--
-- Name: objects voltfriq avatar public read; Type: POLICY; Schema: storage; Owner: supabase_storage_admin
--

CREATE POLICY "voltfriq avatar public read" ON "storage"."objects" FOR SELECT TO "authenticated", "anon" USING (("bucket_id" = 'avatars'::"text"));


--
-- Name: objects voltfriq electrician docs read; Type: POLICY; Schema: storage; Owner: supabase_storage_admin
--

CREATE POLICY "voltfriq electrician docs read" ON "storage"."objects" FOR SELECT TO "authenticated" USING ((("bucket_id" = 'electrician-documents'::"text") AND ("public"."is_admin"() OR (EXISTS ( SELECT 1
   FROM ("public"."electrician_documents" "d"
     JOIN "public"."electricians" "e" ON (("e"."id" = "d"."electrician_id")))
  WHERE (("d"."file_path" = "objects"."name") AND ("e"."profile_id" = "auth"."uid"())))) OR (EXISTS ( SELECT 1
   FROM ("public"."electrician_appeals" "a"
     JOIN "public"."electricians" "e" ON (("e"."id" = "a"."electrician_id")))
  WHERE (("a"."supporting_file_path" = "objects"."name") AND ("e"."profile_id" = "auth"."uid"())))))));


--
-- Name: objects voltfriq electrician docs update; Type: POLICY; Schema: storage; Owner: supabase_storage_admin
--

CREATE POLICY "voltfriq electrician docs update" ON "storage"."objects" FOR UPDATE TO "authenticated" USING ((("bucket_id" = 'electrician-documents'::"text") AND (("owner" = "auth"."uid"()) OR "public"."is_admin"()))) WITH CHECK ((("bucket_id" = 'electrician-documents'::"text") AND (("owner" = "auth"."uid"()) OR "public"."is_admin"())));


--
-- Name: objects voltfriq electrician docs write; Type: POLICY; Schema: storage; Owner: supabase_storage_admin
--

CREATE POLICY "voltfriq electrician docs write" ON "storage"."objects" FOR INSERT TO "authenticated" WITH CHECK ((("bucket_id" = 'electrician-documents'::"text") AND ("public"."is_admin"() OR (("owner" = "auth"."uid"()) AND (("split_part"("name", '/'::"text", 1) = ("auth"."uid"())::"text") OR ("split_part"("name", '/'::"text", 1) = 'appeals'::"text") OR (EXISTS ( SELECT 1
   FROM "public"."electricians" "e"
  WHERE (("e"."profile_id" = "auth"."uid"()) AND ("split_part"("objects"."name", '/'::"text", 1) = ("e"."id")::"text")))))))));


--
-- Name: objects voltfriq guest upload write; Type: POLICY; Schema: storage; Owner: supabase_storage_admin
--

CREATE POLICY "voltfriq guest upload write" ON "storage"."objects" FOR INSERT TO "anon" WITH CHECK ((("bucket_id" = ANY (ARRAY['job-photos'::"text", 'payment-proofs'::"text"])) AND ("split_part"("name", '/'::"text", 1) = 'guest'::"text") AND ("length"("split_part"("name", '/'::"text", 2)) = 36) AND ("length"("split_part"("name", '/'::"text", 3)) >= 12) AND ("split_part"("name", '/'::"text", 4) <> ''::"text") AND ((("bucket_id" = 'job-photos'::"text") AND ((("metadata" ->> 'size'::"text") IS NULL) OR ((("metadata" ->> 'size'::"text"))::bigint <= 5242880))) OR (("bucket_id" = 'payment-proofs'::"text") AND ((("metadata" ->> 'size'::"text") IS NULL) OR ((("metadata" ->> 'size'::"text"))::bigint <= 8388608))))));


--
-- Name: objects voltfriq job photos protected read; Type: POLICY; Schema: storage; Owner: supabase_storage_admin
--

CREATE POLICY "voltfriq job photos protected read" ON "storage"."objects" FOR SELECT TO "authenticated" USING ((("bucket_id" = 'job-photos'::"text") AND ("public"."is_admin"() OR (EXISTS ( SELECT 1
   FROM ((("public"."job_photos" "jp"
     JOIN "public"."jobs" "j" ON (("j"."id" = "jp"."job_id")))
     LEFT JOIN "public"."customers" "c" ON (("c"."id" = "j"."customer_id")))
     LEFT JOIN "public"."electricians" "e" ON (("e"."id" = "j"."assigned_electrician_id")))
  WHERE (("jp"."file_path" = "objects"."name") AND (("c"."profile_id" = "auth"."uid"()) OR ("e"."profile_id" = "auth"."uid"()))))))));


--
-- Name: objects voltfriq payment proof read; Type: POLICY; Schema: storage; Owner: supabase_storage_admin
--

CREATE POLICY "voltfriq payment proof read" ON "storage"."objects" FOR SELECT TO "authenticated" USING ((("bucket_id" = 'payment-proofs'::"text") AND ("public"."is_admin"() OR (EXISTS ( SELECT 1
   FROM ((("public"."job_payments" "jp"
     JOIN "public"."jobs" "j" ON (("j"."id" = "jp"."job_id")))
     LEFT JOIN "public"."customers" "c" ON (("c"."id" = "j"."customer_id")))
     LEFT JOIN "public"."electricians" "e" ON (("e"."id" = "j"."assigned_electrician_id")))
  WHERE (("jp"."proof_path" = "objects"."name") AND (("jp"."submitted_by" = "auth"."uid"()) OR ("c"."profile_id" = "auth"."uid"()) OR ("e"."profile_id" = "auth"."uid"()))))))));


--
-- Name: SCHEMA "public"; Type: ACL; Schema: -; Owner: pg_database_owner
--

GRANT USAGE ON SCHEMA "public" TO "postgres";
GRANT USAGE ON SCHEMA "public" TO "anon";
GRANT USAGE ON SCHEMA "public" TO "authenticated";
GRANT USAGE ON SCHEMA "public" TO "service_role";


--
-- Name: SCHEMA "storage"; Type: ACL; Schema: -; Owner: supabase_admin
--

GRANT USAGE ON SCHEMA "storage" TO "postgres" WITH GRANT OPTION;
GRANT USAGE ON SCHEMA "storage" TO "anon";
GRANT USAGE ON SCHEMA "storage" TO "authenticated";
GRANT USAGE ON SCHEMA "storage" TO "service_role";
GRANT ALL ON SCHEMA "storage" TO "supabase_storage_admin" WITH GRANT OPTION;
GRANT ALL ON SCHEMA "storage" TO "dashboard_user";


--
-- Name: FUNCTION "actor_role_for_profile"("p_profile_id" "uuid"); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."actor_role_for_profile"("p_profile_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."actor_role_for_profile"("p_profile_id" "uuid") TO "service_role";


--
-- Name: FUNCTION "admin_assign_electrician_to_job"("p_job_id" "uuid", "p_electrician_id" "uuid", "p_force" boolean); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."admin_assign_electrician_to_job"("p_job_id" "uuid", "p_electrician_id" "uuid", "p_force" boolean) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."admin_assign_electrician_to_job"("p_job_id" "uuid", "p_electrician_id" "uuid", "p_force" boolean) TO "service_role";
GRANT ALL ON FUNCTION "public"."admin_assign_electrician_to_job"("p_job_id" "uuid", "p_electrician_id" "uuid", "p_force" boolean) TO "authenticated";


--
-- Name: FUNCTION "admin_job_payload"("p_job_id" "uuid"); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."admin_job_payload"("p_job_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."admin_job_payload"("p_job_id" "uuid") TO "service_role";
GRANT ALL ON FUNCTION "public"."admin_job_payload"("p_job_id" "uuid") TO "authenticated";


--
-- Name: FUNCTION "admin_operational_queues"(); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."admin_operational_queues"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."admin_operational_queues"() TO "service_role";
GRANT ALL ON FUNCTION "public"."admin_operational_queues"() TO "authenticated";


--
-- Name: FUNCTION "admin_operational_summary"(); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."admin_operational_summary"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."admin_operational_summary"() TO "service_role";
GRANT ALL ON FUNCTION "public"."admin_operational_summary"() TO "authenticated";


--
-- Name: TABLE "jobs"; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE "public"."jobs" TO "service_role";
GRANT SELECT ON TABLE "public"."jobs" TO "authenticated";


--
-- Name: FUNCTION "admin_rebuild_job_projection"("p_job_id" "uuid"); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."admin_rebuild_job_projection"("p_job_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."admin_rebuild_job_projection"("p_job_id" "uuid") TO "service_role";


--
-- Name: FUNCTION "admin_reconcile_job_state"("p_job_id" "uuid"); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."admin_reconcile_job_state"("p_job_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."admin_reconcile_job_state"("p_job_id" "uuid") TO "service_role";
GRANT ALL ON FUNCTION "public"."admin_reconcile_job_state"("p_job_id" "uuid") TO "authenticated";


--
-- Name: FUNCTION "admin_replay_job_events"("p_job_id" "uuid"); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."admin_replay_job_events"("p_job_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."admin_replay_job_events"("p_job_id" "uuid") TO "service_role";


--
-- Name: TABLE "operational_alerts"; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE "public"."operational_alerts" TO "service_role";
GRANT SELECT ON TABLE "public"."operational_alerts" TO "authenticated";


--
-- Name: FUNCTION "admin_resolve_operational_alert"("p_alert_id" "uuid", "p_note" "text"); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."admin_resolve_operational_alert"("p_alert_id" "uuid", "p_note" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."admin_resolve_operational_alert"("p_alert_id" "uuid", "p_note" "text") TO "service_role";
GRANT ALL ON FUNCTION "public"."admin_resolve_operational_alert"("p_alert_id" "uuid", "p_note" "text") TO "authenticated";


--
-- Name: FUNCTION "admin_retry_dispatch_job"("p_job_id" "uuid"); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."admin_retry_dispatch_job"("p_job_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."admin_retry_dispatch_job"("p_job_id" "uuid") TO "service_role";
GRANT ALL ON FUNCTION "public"."admin_retry_dispatch_job"("p_job_id" "uuid") TO "authenticated";


--
-- Name: TABLE "electricians"; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE "public"."electricians" TO "anon";
GRANT ALL ON TABLE "public"."electricians" TO "authenticated";
GRANT ALL ON TABLE "public"."electricians" TO "service_role";


--
-- Name: FUNCTION "admin_set_electrician_status"("p_electrician_id" "uuid", "p_status" "public"."electrician_status", "p_reason" "text"); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."admin_set_electrician_status"("p_electrician_id" "uuid", "p_status" "public"."electrician_status", "p_reason" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."admin_set_electrician_status"("p_electrician_id" "uuid", "p_status" "public"."electrician_status", "p_reason" "text") TO "service_role";
GRANT ALL ON FUNCTION "public"."admin_set_electrician_status"("p_electrician_id" "uuid", "p_status" "public"."electrician_status", "p_reason" "text") TO "authenticated";


--
-- Name: FUNCTION "admin_set_electrician_watchlist"("p_electrician_id" "uuid", "p_watchlist" boolean, "p_reason" "text"); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."admin_set_electrician_watchlist"("p_electrician_id" "uuid", "p_watchlist" boolean, "p_reason" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."admin_set_electrician_watchlist"("p_electrician_id" "uuid", "p_watchlist" boolean, "p_reason" "text") TO "service_role";
GRANT ALL ON FUNCTION "public"."admin_set_electrician_watchlist"("p_electrician_id" "uuid", "p_watchlist" boolean, "p_reason" "text") TO "authenticated";


--
-- Name: FUNCTION "append_job_timeline"("p_job_id" "uuid", "p_status" "public"."job_status", "p_note" "text", "p_actor_profile_id" "uuid"); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."append_job_timeline"("p_job_id" "uuid", "p_status" "public"."job_status", "p_note" "text", "p_actor_profile_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."append_job_timeline"("p_job_id" "uuid", "p_status" "public"."job_status", "p_note" "text", "p_actor_profile_id" "uuid") TO "service_role";


--
-- Name: FUNCTION "apply_electrician_reliability_cooldowns"("p_limit" integer); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."apply_electrician_reliability_cooldowns"("p_limit" integer) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."apply_electrician_reliability_cooldowns"("p_limit" integer) TO "service_role";


--
-- Name: FUNCTION "apply_operational_escalations"(); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."apply_operational_escalations"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."apply_operational_escalations"() TO "service_role";


--
-- Name: FUNCTION "attach_guest_job_photos"("p_job_id" "uuid", "p_access_token" "text", "p_photo_paths" "text"[]); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."attach_guest_job_photos"("p_job_id" "uuid", "p_access_token" "text", "p_photo_paths" "text"[]) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."attach_guest_job_photos"("p_job_id" "uuid", "p_access_token" "text", "p_photo_paths" "text"[]) TO "service_role";


--
-- Name: FUNCTION "audit_direct_job_status_write"(); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."audit_direct_job_status_write"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."audit_direct_job_status_write"() TO "service_role";


--
-- Name: FUNCTION "calculate_electrician_level"("p_completed_jobs" integer, "p_average_rating" numeric, "p_total_ratings" integer, "p_response_rate" numeric, "p_watchlist" boolean); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."calculate_electrician_level"("p_completed_jobs" integer, "p_average_rating" numeric, "p_total_ratings" integer, "p_response_rate" numeric, "p_watchlist" boolean) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."calculate_electrician_level"("p_completed_jobs" integer, "p_average_rating" numeric, "p_total_ratings" integer, "p_response_rate" numeric, "p_watchlist" boolean) TO "service_role";


--
-- Name: TABLE "system_health_snapshots"; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE "public"."system_health_snapshots" TO "service_role";
GRANT SELECT ON TABLE "public"."system_health_snapshots" TO "authenticated";


--
-- Name: FUNCTION "capture_system_health_snapshot"("p_source" "text"); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."capture_system_health_snapshot"("p_source" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."capture_system_health_snapshot"("p_source" "text") TO "service_role";


--
-- Name: FUNCTION "claim_operation_request"("p_request_id" "text", "p_operation_name" "text", "p_request_hash" "text"); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."claim_operation_request"("p_request_id" "text", "p_operation_name" "text", "p_request_hash" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."claim_operation_request"("p_request_id" "text", "p_operation_name" "text", "p_request_hash" "text") TO "service_role";


--
-- Name: FUNCTION "complete_operation_request"("p_request_id" "text", "p_status" "text", "p_response_payload" "jsonb", "p_error_message" "text"); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."complete_operation_request"("p_request_id" "text", "p_status" "text", "p_response_payload" "jsonb", "p_error_message" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."complete_operation_request"("p_request_id" "text", "p_status" "text", "p_response_payload" "jsonb", "p_error_message" "text") TO "service_role";


--
-- Name: FUNCTION "consume_guest_action_token"("p_job_id" "uuid", "p_action_type" "text", "p_action_token" "text"); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."consume_guest_action_token"("p_job_id" "uuid", "p_action_type" "text", "p_action_token" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."consume_guest_action_token"("p_job_id" "uuid", "p_action_type" "text", "p_action_token" "text") TO "service_role";


--
-- Name: FUNCTION "create_customer_job"("p_service_area" "text", "p_location_label" "text", "p_latitude" double precision, "p_longitude" double precision, "p_issue_category" "text", "p_urgency" "public"."job_urgency", "p_customer_note" "text", "p_requires_assessment" boolean, "p_material_handling" "text", "p_photo_paths" "text"[]); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."create_customer_job"("p_service_area" "text", "p_location_label" "text", "p_latitude" double precision, "p_longitude" double precision, "p_issue_category" "text", "p_urgency" "public"."job_urgency", "p_customer_note" "text", "p_requires_assessment" boolean, "p_material_handling" "text", "p_photo_paths" "text"[]) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."create_customer_job"("p_service_area" "text", "p_location_label" "text", "p_latitude" double precision, "p_longitude" double precision, "p_issue_category" "text", "p_urgency" "public"."job_urgency", "p_customer_note" "text", "p_requires_assessment" boolean, "p_material_handling" "text", "p_photo_paths" "text"[]) TO "service_role";
GRANT ALL ON FUNCTION "public"."create_customer_job"("p_service_area" "text", "p_location_label" "text", "p_latitude" double precision, "p_longitude" double precision, "p_issue_category" "text", "p_urgency" "public"."job_urgency", "p_customer_note" "text", "p_requires_assessment" boolean, "p_material_handling" "text", "p_photo_paths" "text"[]) TO "authenticated";


--
-- Name: TABLE "disputes"; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE "public"."disputes" TO "anon";
GRANT ALL ON TABLE "public"."disputes" TO "authenticated";
GRANT ALL ON TABLE "public"."disputes" TO "service_role";


--
-- Name: FUNCTION "create_dispute"("p_job_id" "uuid", "p_issue_type" "text", "p_details" "text"); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."create_dispute"("p_job_id" "uuid", "p_issue_type" "text", "p_details" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."create_dispute"("p_job_id" "uuid", "p_issue_type" "text", "p_details" "text") TO "service_role";
GRANT ALL ON FUNCTION "public"."create_dispute"("p_job_id" "uuid", "p_issue_type" "text", "p_details" "text") TO "authenticated";


--
-- Name: FUNCTION "create_guest_customer_job"("p_phone" "text", "p_service_area" "text", "p_location_label" "text", "p_latitude" double precision, "p_longitude" double precision, "p_issue_category" "text", "p_urgency" "public"."job_urgency", "p_customer_note" "text", "p_requires_assessment" boolean, "p_material_handling" "text", "p_photo_paths" "text"[], "p_client_fingerprint" "text"); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."create_guest_customer_job"("p_phone" "text", "p_service_area" "text", "p_location_label" "text", "p_latitude" double precision, "p_longitude" double precision, "p_issue_category" "text", "p_urgency" "public"."job_urgency", "p_customer_note" "text", "p_requires_assessment" boolean, "p_material_handling" "text", "p_photo_paths" "text"[], "p_client_fingerprint" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."create_guest_customer_job"("p_phone" "text", "p_service_area" "text", "p_location_label" "text", "p_latitude" double precision, "p_longitude" double precision, "p_issue_category" "text", "p_urgency" "public"."job_urgency", "p_customer_note" "text", "p_requires_assessment" boolean, "p_material_handling" "text", "p_photo_paths" "text"[], "p_client_fingerprint" "text") TO "service_role";
GRANT ALL ON FUNCTION "public"."create_guest_customer_job"("p_phone" "text", "p_service_area" "text", "p_location_label" "text", "p_latitude" double precision, "p_longitude" double precision, "p_issue_category" "text", "p_urgency" "public"."job_urgency", "p_customer_note" "text", "p_requires_assessment" boolean, "p_material_handling" "text", "p_photo_paths" "text"[], "p_client_fingerprint" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."create_guest_customer_job"("p_phone" "text", "p_service_area" "text", "p_location_label" "text", "p_latitude" double precision, "p_longitude" double precision, "p_issue_category" "text", "p_urgency" "public"."job_urgency", "p_customer_note" "text", "p_requires_assessment" boolean, "p_material_handling" "text", "p_photo_paths" "text"[], "p_client_fingerprint" "text") TO "authenticated";


--
-- Name: FUNCTION "create_guest_dispute"("p_job_id" "uuid", "p_access_token" "text", "p_issue_type" "text", "p_details" "text", "p_phone_confirmation" "text", "p_action_token" "text"); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."create_guest_dispute"("p_job_id" "uuid", "p_access_token" "text", "p_issue_type" "text", "p_details" "text", "p_phone_confirmation" "text", "p_action_token" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."create_guest_dispute"("p_job_id" "uuid", "p_access_token" "text", "p_issue_type" "text", "p_details" "text", "p_phone_confirmation" "text", "p_action_token" "text") TO "service_role";
GRANT ALL ON FUNCTION "public"."create_guest_dispute"("p_job_id" "uuid", "p_access_token" "text", "p_issue_type" "text", "p_details" "text", "p_phone_confirmation" "text", "p_action_token" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."create_guest_dispute"("p_job_id" "uuid", "p_access_token" "text", "p_issue_type" "text", "p_details" "text", "p_phone_confirmation" "text", "p_action_token" "text") TO "authenticated";


--
-- Name: FUNCTION "create_guest_otp_delivery"("p_job_id" "uuid", "p_access_token" "text", "p_action_type" "text", "p_phone_confirmation" "text", "p_client_fingerprint" "text"); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."create_guest_otp_delivery"("p_job_id" "uuid", "p_access_token" "text", "p_action_type" "text", "p_phone_confirmation" "text", "p_client_fingerprint" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."create_guest_otp_delivery"("p_job_id" "uuid", "p_access_token" "text", "p_action_type" "text", "p_phone_confirmation" "text", "p_client_fingerprint" "text") TO "service_role";


--
-- Name: FUNCTION "create_notification"("p_profile_id" "uuid", "p_job_id" "uuid", "p_event" "public"."notification_event", "p_title" "text", "p_body" "text", "p_metadata" "jsonb"); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."create_notification"("p_profile_id" "uuid", "p_job_id" "uuid", "p_event" "public"."notification_event", "p_title" "text", "p_body" "text", "p_metadata" "jsonb") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."create_notification"("p_profile_id" "uuid", "p_job_id" "uuid", "p_event" "public"."notification_event", "p_title" "text", "p_body" "text", "p_metadata" "jsonb") TO "service_role";


--
-- Name: FUNCTION "current_customer_id"(); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."current_customer_id"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."current_customer_id"() TO "service_role";
GRANT ALL ON FUNCTION "public"."current_customer_id"() TO "authenticated";


--
-- Name: FUNCTION "current_electrician_id"(); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."current_electrician_id"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."current_electrician_id"() TO "service_role";
GRANT ALL ON FUNCTION "public"."current_electrician_id"() TO "authenticated";


--
-- Name: FUNCTION "customer_job_payload"("p_job_id" "uuid"); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."customer_job_payload"("p_job_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."customer_job_payload"("p_job_id" "uuid") TO "service_role";
GRANT ALL ON FUNCTION "public"."customer_job_payload"("p_job_id" "uuid") TO "authenticated";


--
-- Name: FUNCTION "detect_predictive_operational_risks"(); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."detect_predictive_operational_risks"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."detect_predictive_operational_risks"() TO "service_role";


--
-- Name: FUNCTION "detect_snapshot_drift"(); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."detect_snapshot_drift"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."detect_snapshot_drift"() TO "service_role";


--
-- Name: FUNCTION "detect_stuck_jobs"(); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."detect_stuck_jobs"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."detect_stuck_jobs"() TO "service_role";


--
-- Name: FUNCTION "dispatch_job"("p_job_id" "uuid", "p_manual_electrician_id" "uuid"); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."dispatch_job"("p_job_id" "uuid", "p_manual_electrician_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."dispatch_job"("p_job_id" "uuid", "p_manual_electrician_id" "uuid") TO "service_role";
GRANT ALL ON FUNCTION "public"."dispatch_job"("p_job_id" "uuid", "p_manual_electrician_id" "uuid") TO "authenticated";


--
-- Name: FUNCTION "dispatch_job_internal"("p_job_id" "uuid", "p_manual_electrician_id" "uuid"); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."dispatch_job_internal"("p_job_id" "uuid", "p_manual_electrician_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."dispatch_job_internal"("p_job_id" "uuid", "p_manual_electrician_id" "uuid") TO "service_role";


--
-- Name: FUNCTION "electrician_accept_job"("p_job_id" "uuid"); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."electrician_accept_job"("p_job_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."electrician_accept_job"("p_job_id" "uuid") TO "service_role";
GRANT ALL ON FUNCTION "public"."electrician_accept_job"("p_job_id" "uuid") TO "authenticated";


--
-- Name: FUNCTION "electrician_job_payload"("p_job_id" "uuid"); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."electrician_job_payload"("p_job_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."electrician_job_payload"("p_job_id" "uuid") TO "service_role";
GRANT ALL ON FUNCTION "public"."electrician_job_payload"("p_job_id" "uuid") TO "authenticated";


--
-- Name: FUNCTION "electrician_level_rank"("p_level" "text"); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."electrician_level_rank"("p_level" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."electrician_level_rank"("p_level" "text") TO "service_role";


--
-- Name: FUNCTION "electrician_reject_job"("p_job_id" "uuid"); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."electrician_reject_job"("p_job_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."electrician_reject_job"("p_job_id" "uuid") TO "service_role";
GRANT ALL ON FUNCTION "public"."electrician_reject_job"("p_job_id" "uuid") TO "authenticated";


--
-- Name: FUNCTION "enforce_job_status_event"(); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."enforce_job_status_event"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."enforce_job_status_event"() TO "service_role";


--
-- Name: TABLE "profiles"; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE "public"."profiles" TO "anon";
GRANT ALL ON TABLE "public"."profiles" TO "authenticated";
GRANT ALL ON TABLE "public"."profiles" TO "service_role";


--
-- Name: FUNCTION "ensure_app_account_for_current_user"(); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."ensure_app_account_for_current_user"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."ensure_app_account_for_current_user"() TO "service_role";
GRANT ALL ON FUNCTION "public"."ensure_app_account_for_current_user"() TO "authenticated";


--
-- Name: FUNCTION "ensure_profile_for_current_user"(); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."ensure_profile_for_current_user"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."ensure_profile_for_current_user"() TO "service_role";
GRANT ALL ON FUNCTION "public"."ensure_profile_for_current_user"() TO "authenticated";


--
-- Name: TABLE "wallets"; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE "public"."wallets" TO "anon";
GRANT ALL ON TABLE "public"."wallets" TO "authenticated";
GRANT ALL ON TABLE "public"."wallets" TO "service_role";


--
-- Name: FUNCTION "ensure_wallet_for_profile"("p_profile_id" "uuid"); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."ensure_wallet_for_profile"("p_profile_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."ensure_wallet_for_profile"("p_profile_id" "uuid") TO "service_role";


--
-- Name: FUNCTION "find_matching_electricians"("p_service_area" "text", "p_issue_category" "text", "p_latitude" double precision, "p_longitude" double precision, "p_limit" integer); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."find_matching_electricians"("p_service_area" "text", "p_issue_category" "text", "p_latitude" double precision, "p_longitude" double precision, "p_limit" integer) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."find_matching_electricians"("p_service_area" "text", "p_issue_category" "text", "p_latitude" double precision, "p_longitude" double precision, "p_limit" integer) TO "service_role";
GRANT ALL ON FUNCTION "public"."find_matching_electricians"("p_service_area" "text", "p_issue_category" "text", "p_latitude" double precision, "p_longitude" double precision, "p_limit" integer) TO "authenticated";


--
-- Name: FUNCTION "generate_referral_code"(); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."generate_referral_code"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."generate_referral_code"() TO "service_role";


--
-- Name: FUNCTION "get_admin_job_events"("p_job_id" "uuid"); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."get_admin_job_events"("p_job_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."get_admin_job_events"("p_job_id" "uuid") TO "service_role";
GRANT ALL ON FUNCTION "public"."get_admin_job_events"("p_job_id" "uuid") TO "authenticated";


--
-- Name: FUNCTION "get_guest_job"("p_job_id" "uuid", "p_access_token" "text"); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."get_guest_job"("p_job_id" "uuid", "p_access_token" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."get_guest_job"("p_job_id" "uuid", "p_access_token" "text") TO "service_role";
GRANT ALL ON FUNCTION "public"."get_guest_job"("p_job_id" "uuid", "p_access_token" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."get_guest_job"("p_job_id" "uuid", "p_access_token" "text") TO "authenticated";


--
-- Name: FUNCTION "get_public_job_events"("p_job_id" "uuid", "p_access_token" "text"); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."get_public_job_events"("p_job_id" "uuid", "p_access_token" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."get_public_job_events"("p_job_id" "uuid", "p_access_token" "text") TO "service_role";
GRANT ALL ON FUNCTION "public"."get_public_job_events"("p_job_id" "uuid", "p_access_token" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."get_public_job_events"("p_job_id" "uuid", "p_access_token" "text") TO "authenticated";


--
-- Name: FUNCTION "guest_dispatch_otp_required"(); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."guest_dispatch_otp_required"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."guest_dispatch_otp_required"() TO "service_role";


--
-- Name: FUNCTION "guest_job_payload"("p_job_id" "uuid", "p_access_token" "text"); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."guest_job_payload"("p_job_id" "uuid", "p_access_token" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."guest_job_payload"("p_job_id" "uuid", "p_access_token" "text") TO "service_role";


--
-- Name: FUNCTION "guest_public_timeline_note"("p_status" "public"."job_status"); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."guest_public_timeline_note"("p_status" "public"."job_status") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."guest_public_timeline_note"("p_status" "public"."job_status") TO "service_role";


--
-- Name: FUNCTION "handle_job_status_notifications"(); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."handle_job_status_notifications"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."handle_job_status_notifications"() TO "service_role";


--
-- Name: FUNCTION "handle_new_user"(); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."handle_new_user"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."handle_new_user"() TO "service_role";


--
-- Name: FUNCTION "handle_profile_rewards_setup"(); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."handle_profile_rewards_setup"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."handle_profile_rewards_setup"() TO "service_role";


--
-- Name: FUNCTION "handle_profile_wallet_setup"(); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."handle_profile_wallet_setup"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."handle_profile_wallet_setup"() TO "service_role";


--
-- Name: FUNCTION "handle_wallets_touch_updated_at"(); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."handle_wallets_touch_updated_at"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."handle_wallets_touch_updated_at"() TO "service_role";


--
-- Name: FUNCTION "is_admin"(); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."is_admin"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."is_admin"() TO "service_role";
GRANT ALL ON FUNCTION "public"."is_admin"() TO "authenticated";


--
-- Name: FUNCTION "is_valid_job_transition"("p_current_status" "public"."job_status", "p_next_status" "public"."job_status", "p_actor_role" "text", "p_is_admin" boolean, "p_metadata" "jsonb"); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."is_valid_job_transition"("p_current_status" "public"."job_status", "p_next_status" "public"."job_status", "p_actor_role" "text", "p_is_admin" boolean, "p_metadata" "jsonb") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."is_valid_job_transition"("p_current_status" "public"."job_status", "p_next_status" "public"."job_status", "p_actor_role" "text", "p_is_admin" boolean, "p_metadata" "jsonb") TO "service_role";


--
-- Name: FUNCTION "issue_guest_action_token"("p_job_id" "uuid", "p_access_token" "text", "p_action_type" "text", "p_phone_confirmation" "text", "p_otp_challenge_id" "uuid", "p_otp_code" "text"); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."issue_guest_action_token"("p_job_id" "uuid", "p_access_token" "text", "p_action_type" "text", "p_phone_confirmation" "text", "p_otp_challenge_id" "uuid", "p_otp_code" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."issue_guest_action_token"("p_job_id" "uuid", "p_access_token" "text", "p_action_type" "text", "p_phone_confirmation" "text", "p_otp_challenge_id" "uuid", "p_otp_code" "text") TO "service_role";
GRANT ALL ON FUNCTION "public"."issue_guest_action_token"("p_job_id" "uuid", "p_access_token" "text", "p_action_type" "text", "p_phone_confirmation" "text", "p_otp_challenge_id" "uuid", "p_otp_code" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."issue_guest_action_token"("p_job_id" "uuid", "p_access_token" "text", "p_action_type" "text", "p_phone_confirmation" "text", "p_otp_challenge_id" "uuid", "p_otp_code" "text") TO "authenticated";


--
-- Name: FUNCTION "job_event_to_timeline"(); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."job_event_to_timeline"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."job_event_to_timeline"() TO "service_role";


--
-- Name: FUNCTION "job_event_type_for_status"("p_status" "public"."job_status"); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."job_event_type_for_status"("p_status" "public"."job_status") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."job_event_type_for_status"("p_status" "public"."job_status") TO "service_role";


--
-- Name: FUNCTION "job_payload_for_role"("p_job" "public"."jobs", "p_role" "text"); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."job_payload_for_role"("p_job" "public"."jobs", "p_role" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."job_payload_for_role"("p_job" "public"."jobs", "p_role" "text") TO "service_role";


--
-- Name: FUNCTION "job_status_for_event"("p_event_type" "text", "p_metadata" "jsonb"); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."job_status_for_event"("p_event_type" "text", "p_metadata" "jsonb") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."job_status_for_event"("p_event_type" "text", "p_metadata" "jsonb") TO "service_role";


--
-- Name: FUNCTION "job_timeline_to_event"(); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."job_timeline_to_event"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."job_timeline_to_event"() TO "service_role";


--
-- Name: TABLE "referrals"; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE "public"."referrals" TO "anon";
GRANT ALL ON TABLE "public"."referrals" TO "authenticated";
GRANT ALL ON TABLE "public"."referrals" TO "service_role";


--
-- Name: FUNCTION "link_referral_code"("p_referral_code" "text"); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."link_referral_code"("p_referral_code" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."link_referral_code"("p_referral_code" "text") TO "service_role";
GRANT ALL ON FUNCTION "public"."link_referral_code"("p_referral_code" "text") TO "authenticated";


--
-- Name: FUNCTION "log_job_event"("p_job_id" "uuid", "p_event_type" "text", "p_actor_role" "text", "p_actor_id" "uuid", "p_public_message" "text", "p_internal_note" "text", "p_metadata" "jsonb"); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."log_job_event"("p_job_id" "uuid", "p_event_type" "text", "p_actor_role" "text", "p_actor_id" "uuid", "p_public_message" "text", "p_internal_note" "text", "p_metadata" "jsonb") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."log_job_event"("p_job_id" "uuid", "p_event_type" "text", "p_actor_role" "text", "p_actor_id" "uuid", "p_public_message" "text", "p_internal_note" "text", "p_metadata" "jsonb") TO "service_role";


--
-- Name: FUNCTION "mark_guest_otp_delivery"("p_challenge_id" "uuid", "p_delivery_status" "text", "p_metadata" "jsonb"); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."mark_guest_otp_delivery"("p_challenge_id" "uuid", "p_delivery_status" "text", "p_metadata" "jsonb") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."mark_guest_otp_delivery"("p_challenge_id" "uuid", "p_delivery_status" "text", "p_metadata" "jsonb") TO "service_role";


--
-- Name: FUNCTION "operational_alert_dedupe_key"("p_alert_type" "text", "p_job_id" "uuid", "p_electrician_id" "uuid", "p_payment_id" "uuid", "p_dispute_id" "uuid"); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."operational_alert_dedupe_key"("p_alert_type" "text", "p_job_id" "uuid", "p_electrician_id" "uuid", "p_payment_id" "uuid", "p_dispute_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."operational_alert_dedupe_key"("p_alert_type" "text", "p_job_id" "uuid", "p_electrician_id" "uuid", "p_payment_id" "uuid", "p_dispute_id" "uuid") TO "service_role";


--
-- Name: FUNCTION "platform_health_snapshot"(); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."platform_health_snapshot"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."platform_health_snapshot"() TO "service_role";


--
-- Name: FUNCTION "prepare_guest_dispatch_otp"("p_job_id" "uuid", "p_access_token" "text", "p_phone_confirmation" "text", "p_client_fingerprint" "text"); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."prepare_guest_dispatch_otp"("p_job_id" "uuid", "p_access_token" "text", "p_phone_confirmation" "text", "p_client_fingerprint" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."prepare_guest_dispatch_otp"("p_job_id" "uuid", "p_access_token" "text", "p_phone_confirmation" "text", "p_client_fingerprint" "text") TO "service_role";


--
-- Name: FUNCTION "prepare_job_event_version"(); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."prepare_job_event_version"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."prepare_job_event_version"() TO "service_role";


--
-- Name: FUNCTION "prioritize_dispatch_queue"("p_limit" integer); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."prioritize_dispatch_queue"("p_limit" integer) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."prioritize_dispatch_queue"("p_limit" integer) TO "service_role";


--
-- Name: FUNCTION "process_dispatch_queue"(); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."process_dispatch_queue"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."process_dispatch_queue"() TO "service_role";


--
-- Name: FUNCTION "project_job_event_state"(); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."project_job_event_state"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."project_job_event_state"() TO "service_role";


--
-- Name: FUNCTION "public_message_for_job_event"("p_event_type" "text", "p_status" "public"."job_status", "p_note" "text"); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."public_message_for_job_event"("p_event_type" "text", "p_status" "public"."job_status", "p_note" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."public_message_for_job_event"("p_event_type" "text", "p_status" "public"."job_status", "p_note" "text") TO "service_role";


--
-- Name: FUNCTION "rebuild_all_job_projections"("p_limit" integer, "p_request_id" "text"); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."rebuild_all_job_projections"("p_limit" integer, "p_request_id" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."rebuild_all_job_projections"("p_limit" integer, "p_request_id" "text") TO "service_role";


--
-- Name: FUNCTION "rebuild_all_job_state_projections"("p_limit" integer); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."rebuild_all_job_state_projections"("p_limit" integer) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."rebuild_all_job_state_projections"("p_limit" integer) TO "service_role";


--
-- Name: FUNCTION "rebuild_all_projections"("p_limit" integer, "p_request_id" "text"); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."rebuild_all_projections"("p_limit" integer, "p_request_id" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."rebuild_all_projections"("p_limit" integer, "p_request_id" "text") TO "service_role";


--
-- Name: FUNCTION "rebuild_job_projection"("p_job_id" "uuid", "p_request_id" "text"); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."rebuild_job_projection"("p_job_id" "uuid", "p_request_id" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."rebuild_job_projection"("p_job_id" "uuid", "p_request_id" "text") TO "service_role";


--
-- Name: FUNCTION "rebuild_job_state_projection"("p_job_id" "uuid", "p_reason" "text"); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."rebuild_job_state_projection"("p_job_id" "uuid", "p_reason" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."rebuild_job_state_projection"("p_job_id" "uuid", "p_reason" "text") TO "service_role";


--
-- Name: FUNCTION "reconcile_active_job_snapshots"("p_limit" integer); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."reconcile_active_job_snapshots"("p_limit" integer) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."reconcile_active_job_snapshots"("p_limit" integer) TO "service_role";


--
-- Name: FUNCTION "reconcile_job_snapshot_from_events"("p_job_id" "uuid", "p_reason" "text"); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."reconcile_job_snapshot_from_events"("p_job_id" "uuid", "p_reason" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."reconcile_job_snapshot_from_events"("p_job_id" "uuid", "p_reason" "text") TO "service_role";


--
-- Name: TABLE "upload_failures"; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE "public"."upload_failures" TO "service_role";
GRANT SELECT ON TABLE "public"."upload_failures" TO "authenticated";


--
-- Name: FUNCTION "record_upload_failure"("p_job_id" "uuid", "p_uploader_role" "text", "p_bucket" "text", "p_file_name" "text", "p_content_type" "text", "p_file_size" integer, "p_failure_stage" "text", "p_error_message" "text", "p_metadata" "jsonb"); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."record_upload_failure"("p_job_id" "uuid", "p_uploader_role" "text", "p_bucket" "text", "p_file_name" "text", "p_content_type" "text", "p_file_size" integer, "p_failure_stage" "text", "p_error_message" "text", "p_metadata" "jsonb") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."record_upload_failure"("p_job_id" "uuid", "p_uploader_role" "text", "p_bucket" "text", "p_file_name" "text", "p_content_type" "text", "p_file_size" integer, "p_failure_stage" "text", "p_error_message" "text", "p_metadata" "jsonb") TO "service_role";


--
-- Name: TABLE "customers"; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE "public"."customers" TO "anon";
GRANT ALL ON TABLE "public"."customers" TO "authenticated";
GRANT ALL ON TABLE "public"."customers" TO "service_role";


--
-- Name: FUNCTION "refresh_customer_trust_metrics"("p_customer_id" "uuid"); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."refresh_customer_trust_metrics"("p_customer_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."refresh_customer_trust_metrics"("p_customer_id" "uuid") TO "service_role";


--
-- Name: TABLE "electrician_performance_snapshots"; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE "public"."electrician_performance_snapshots" TO "service_role";
GRANT SELECT ON TABLE "public"."electrician_performance_snapshots" TO "authenticated";


--
-- Name: FUNCTION "refresh_electrician_performance_snapshot"("p_electrician_id" "uuid"); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."refresh_electrician_performance_snapshot"("p_electrician_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."refresh_electrician_performance_snapshot"("p_electrician_id" "uuid") TO "service_role";


--
-- Name: FUNCTION "refresh_electrician_trust_metrics"("p_electrician_id" "uuid"); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."refresh_electrician_trust_metrics"("p_electrician_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."refresh_electrician_trust_metrics"("p_electrician_id" "uuid") TO "service_role";


--
-- Name: FUNCTION "refresh_operational_alerts"(); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."refresh_operational_alerts"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."refresh_operational_alerts"() TO "service_role";


--
-- Name: FUNCTION "refresh_predictive_operational_alerts"(); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."refresh_predictive_operational_alerts"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."refresh_predictive_operational_alerts"() TO "service_role";


--
-- Name: FUNCTION "replay_all_job_events"("p_limit" integer, "p_request_id" "text"); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."replay_all_job_events"("p_limit" integer, "p_request_id" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."replay_all_job_events"("p_limit" integer, "p_request_id" "text") TO "service_role";


--
-- Name: FUNCTION "replay_job_events"("p_job_id" "uuid", "p_request_id" "text"); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."replay_job_events"("p_job_id" "uuid", "p_request_id" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."replay_job_events"("p_job_id" "uuid", "p_request_id" "text") TO "service_role";


--
-- Name: FUNCTION "replay_job_events_internal"("p_job_id" "uuid", "p_replay_run_id" "uuid", "p_reason" "text"); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."replay_job_events_internal"("p_job_id" "uuid", "p_replay_run_id" "uuid", "p_reason" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."replay_job_events_internal"("p_job_id" "uuid", "p_replay_run_id" "uuid", "p_reason" "text") TO "service_role";


--
-- Name: FUNCTION "request_guest_otp"("p_job_id" "uuid", "p_access_token" "text", "p_action_type" "text", "p_phone_confirmation" "text", "p_client_fingerprint" "text"); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."request_guest_otp"("p_job_id" "uuid", "p_access_token" "text", "p_action_type" "text", "p_phone_confirmation" "text", "p_client_fingerprint" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."request_guest_otp"("p_job_id" "uuid", "p_access_token" "text", "p_action_type" "text", "p_phone_confirmation" "text", "p_client_fingerprint" "text") TO "service_role";
GRANT ALL ON FUNCTION "public"."request_guest_otp"("p_job_id" "uuid", "p_access_token" "text", "p_action_type" "text", "p_phone_confirmation" "text", "p_client_fingerprint" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."request_guest_otp"("p_job_id" "uuid", "p_access_token" "text", "p_action_type" "text", "p_phone_confirmation" "text", "p_client_fingerprint" "text") TO "authenticated";


--
-- Name: FUNCTION "resolve_dispute"("p_dispute_id" "uuid", "p_status" "text", "p_resolution_action" "text", "p_resolution_note" "text"); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."resolve_dispute"("p_dispute_id" "uuid", "p_status" "text", "p_resolution_action" "text", "p_resolution_note" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."resolve_dispute"("p_dispute_id" "uuid", "p_status" "text", "p_resolution_action" "text", "p_resolution_note" "text") TO "service_role";
GRANT ALL ON FUNCTION "public"."resolve_dispute"("p_dispute_id" "uuid", "p_status" "text", "p_resolution_action" "text", "p_resolution_note" "text") TO "authenticated";


--
-- Name: TABLE "electrician_appeals"; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE "public"."electrician_appeals" TO "anon";
GRANT ALL ON TABLE "public"."electrician_appeals" TO "authenticated";
GRANT ALL ON TABLE "public"."electrician_appeals" TO "service_role";


--
-- Name: FUNCTION "resolve_electrician_appeal"("p_appeal_id" "uuid", "p_approved" boolean, "p_admin_note" "text"); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."resolve_electrician_appeal"("p_appeal_id" "uuid", "p_approved" boolean, "p_admin_note" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."resolve_electrician_appeal"("p_appeal_id" "uuid", "p_approved" boolean, "p_admin_note" "text") TO "service_role";
GRANT ALL ON FUNCTION "public"."resolve_electrician_appeal"("p_appeal_id" "uuid", "p_approved" boolean, "p_admin_note" "text") TO "authenticated";


--
-- Name: FUNCTION "reward_completed_referral"("p_referred_profile_id" "uuid", "p_job_id" "uuid"); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."reward_completed_referral"("p_referred_profile_id" "uuid", "p_job_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."reward_completed_referral"("p_referred_profile_id" "uuid", "p_job_id" "uuid") TO "service_role";


--
-- Name: FUNCTION "run_operational_automation"("p_limit" integer, "p_request_id" "text"); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."run_operational_automation"("p_limit" integer, "p_request_id" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."run_operational_automation"("p_limit" integer, "p_request_id" "text") TO "service_role";


--
-- Name: FUNCTION "run_operational_recovery"("p_limit" integer, "p_request_id" "text"); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."run_operational_recovery"("p_limit" integer, "p_request_id" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."run_operational_recovery"("p_limit" integer, "p_request_id" "text") TO "service_role";


--
-- Name: FUNCTION "sanitize_request_id"("p_request_id" "text"); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."sanitize_request_id"("p_request_id" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."sanitize_request_id"("p_request_id" "text") TO "service_role";


--
-- Name: FUNCTION "set_job_status"("p_job_id" "uuid", "p_next_status" "public"."job_status", "p_note" "text", "p_metadata" "jsonb"); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."set_job_status"("p_job_id" "uuid", "p_next_status" "public"."job_status", "p_note" "text", "p_metadata" "jsonb") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."set_job_status"("p_job_id" "uuid", "p_next_status" "public"."job_status", "p_note" "text", "p_metadata" "jsonb") TO "service_role";
GRANT ALL ON FUNCTION "public"."set_job_status"("p_job_id" "uuid", "p_next_status" "public"."job_status", "p_note" "text", "p_metadata" "jsonb") TO "authenticated";


--
-- Name: TABLE "ratings"; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE "public"."ratings" TO "anon";
GRANT ALL ON TABLE "public"."ratings" TO "authenticated";
GRANT ALL ON TABLE "public"."ratings" TO "service_role";


--
-- Name: FUNCTION "submit_customer_review"("p_job_id" "uuid", "p_score" integer, "p_comment" "text", "p_behavior_tags" "text"[]); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."submit_customer_review"("p_job_id" "uuid", "p_score" integer, "p_comment" "text", "p_behavior_tags" "text"[]) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."submit_customer_review"("p_job_id" "uuid", "p_score" integer, "p_comment" "text", "p_behavior_tags" "text"[]) TO "service_role";
GRANT ALL ON FUNCTION "public"."submit_customer_review"("p_job_id" "uuid", "p_score" integer, "p_comment" "text", "p_behavior_tags" "text"[]) TO "authenticated";


--
-- Name: FUNCTION "submit_electrician_appeal"("p_appeal_note" "text", "p_supporting_file_path" "text"); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."submit_electrician_appeal"("p_appeal_note" "text", "p_supporting_file_path" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."submit_electrician_appeal"("p_appeal_note" "text", "p_supporting_file_path" "text") TO "service_role";
GRANT ALL ON FUNCTION "public"."submit_electrician_appeal"("p_appeal_note" "text", "p_supporting_file_path" "text") TO "authenticated";


--
-- Name: TABLE "job_payments"; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE "public"."job_payments" TO "anon";
GRANT ALL ON TABLE "public"."job_payments" TO "authenticated";
GRANT ALL ON TABLE "public"."job_payments" TO "service_role";


--
-- Name: FUNCTION "submit_guest_payment_proof"("p_job_id" "uuid", "p_access_token" "text", "p_payment_type" "public"."payment_type", "p_amount" numeric, "p_reference" "text", "p_proof_path" "text", "p_phone_confirmation" "text", "p_action_token" "text"); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."submit_guest_payment_proof"("p_job_id" "uuid", "p_access_token" "text", "p_payment_type" "public"."payment_type", "p_amount" numeric, "p_reference" "text", "p_proof_path" "text", "p_phone_confirmation" "text", "p_action_token" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."submit_guest_payment_proof"("p_job_id" "uuid", "p_access_token" "text", "p_payment_type" "public"."payment_type", "p_amount" numeric, "p_reference" "text", "p_proof_path" "text", "p_phone_confirmation" "text", "p_action_token" "text") TO "service_role";
GRANT ALL ON FUNCTION "public"."submit_guest_payment_proof"("p_job_id" "uuid", "p_access_token" "text", "p_payment_type" "public"."payment_type", "p_amount" numeric, "p_reference" "text", "p_proof_path" "text", "p_phone_confirmation" "text", "p_action_token" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."submit_guest_payment_proof"("p_job_id" "uuid", "p_access_token" "text", "p_payment_type" "public"."payment_type", "p_amount" numeric, "p_reference" "text", "p_proof_path" "text", "p_phone_confirmation" "text", "p_action_token" "text") TO "authenticated";


--
-- Name: TABLE "job_quotes"; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE "public"."job_quotes" TO "anon";
GRANT ALL ON TABLE "public"."job_quotes" TO "authenticated";
GRANT ALL ON TABLE "public"."job_quotes" TO "service_role";


--
-- Name: FUNCTION "submit_job_quote"("p_job_id" "uuid", "p_findings" "text", "p_measurements" "text", "p_items" "jsonb"); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."submit_job_quote"("p_job_id" "uuid", "p_findings" "text", "p_measurements" "text", "p_items" "jsonb") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."submit_job_quote"("p_job_id" "uuid", "p_findings" "text", "p_measurements" "text", "p_items" "jsonb") TO "service_role";
GRANT ALL ON FUNCTION "public"."submit_job_quote"("p_job_id" "uuid", "p_findings" "text", "p_measurements" "text", "p_items" "jsonb") TO "authenticated";


--
-- Name: FUNCTION "submit_payment_proof"("p_job_id" "uuid", "p_payment_type" "public"."payment_type", "p_amount" numeric, "p_reference" "text", "p_proof_path" "text"); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."submit_payment_proof"("p_job_id" "uuid", "p_payment_type" "public"."payment_type", "p_amount" numeric, "p_reference" "text", "p_proof_path" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."submit_payment_proof"("p_job_id" "uuid", "p_payment_type" "public"."payment_type", "p_amount" numeric, "p_reference" "text", "p_proof_path" "text") TO "service_role";
GRANT ALL ON FUNCTION "public"."submit_payment_proof"("p_job_id" "uuid", "p_payment_type" "public"."payment_type", "p_amount" numeric, "p_reference" "text", "p_proof_path" "text") TO "authenticated";


--
-- Name: FUNCTION "submit_rating"("p_job_id" "uuid", "p_score" integer, "p_comment" "text", "p_behavior_tags" "text"[]); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."submit_rating"("p_job_id" "uuid", "p_score" integer, "p_comment" "text", "p_behavior_tags" "text"[]) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."submit_rating"("p_job_id" "uuid", "p_score" integer, "p_comment" "text", "p_behavior_tags" "text"[]) TO "service_role";
GRANT ALL ON FUNCTION "public"."submit_rating"("p_job_id" "uuid", "p_score" integer, "p_comment" "text", "p_behavior_tags" "text"[]) TO "authenticated";


--
-- Name: FUNCTION "sync_all_job_state_projections"("p_limit" integer); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."sync_all_job_state_projections"("p_limit" integer) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."sync_all_job_state_projections"("p_limit" integer) TO "service_role";


--
-- Name: FUNCTION "sync_app_account_for_auth_user"("p_user_id" "uuid"); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."sync_app_account_for_auth_user"("p_user_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."sync_app_account_for_auth_user"("p_user_id" "uuid") TO "service_role";


--
-- Name: FUNCTION "sync_electrician_reliability_aliases"(); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."sync_electrician_reliability_aliases"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."sync_electrician_reliability_aliases"() TO "service_role";


--
-- Name: FUNCTION "sync_electrician_snapshot_reliability_aliases"(); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."sync_electrician_snapshot_reliability_aliases"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."sync_electrician_snapshot_reliability_aliases"() TO "service_role";


--
-- Name: FUNCTION "sync_job_event_payload"(); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."sync_job_event_payload"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."sync_job_event_payload"() TO "service_role";


--
-- Name: FUNCTION "sync_job_state_projection"("p_job_id" "uuid", "p_reason" "text"); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."sync_job_state_projection"("p_job_id" "uuid", "p_reason" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."sync_job_state_projection"("p_job_id" "uuid", "p_reason" "text") TO "service_role";


--
-- Name: FUNCTION "touch_updated_at"(); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."touch_updated_at"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."touch_updated_at"() TO "service_role";


--
-- Name: FUNCTION "transition_job_state"("p_job_id" "uuid", "p_next_status" "public"."job_status", "p_actor_role" "text", "p_actor_id" "uuid", "p_public_note" "text", "p_internal_note" "text", "p_metadata" "jsonb", "p_expected_status" "public"."job_status", "p_idempotency_key" "text"); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."transition_job_state"("p_job_id" "uuid", "p_next_status" "public"."job_status", "p_actor_role" "text", "p_actor_id" "uuid", "p_public_note" "text", "p_internal_note" "text", "p_metadata" "jsonb", "p_expected_status" "public"."job_status", "p_idempotency_key" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."transition_job_state"("p_job_id" "uuid", "p_next_status" "public"."job_status", "p_actor_role" "text", "p_actor_id" "uuid", "p_public_note" "text", "p_internal_note" "text", "p_metadata" "jsonb", "p_expected_status" "public"."job_status", "p_idempotency_key" "text") TO "service_role";


--
-- Name: FUNCTION "update_guest_job_status"("p_job_id" "uuid", "p_access_token" "text", "p_next_status" "public"."job_status", "p_note" "text", "p_metadata" "jsonb", "p_action_token" "text"); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."update_guest_job_status"("p_job_id" "uuid", "p_access_token" "text", "p_next_status" "public"."job_status", "p_note" "text", "p_metadata" "jsonb", "p_action_token" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."update_guest_job_status"("p_job_id" "uuid", "p_access_token" "text", "p_next_status" "public"."job_status", "p_note" "text", "p_metadata" "jsonb", "p_action_token" "text") TO "service_role";
GRANT ALL ON FUNCTION "public"."update_guest_job_status"("p_job_id" "uuid", "p_access_token" "text", "p_next_status" "public"."job_status", "p_note" "text", "p_metadata" "jsonb", "p_action_token" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."update_guest_job_status"("p_job_id" "uuid", "p_access_token" "text", "p_next_status" "public"."job_status", "p_note" "text", "p_metadata" "jsonb", "p_action_token" "text") TO "authenticated";


--
-- Name: FUNCTION "upsert_operational_alert"("p_alert_type" "text", "p_severity" "text", "p_message" "text", "p_job_id" "uuid", "p_electrician_id" "uuid", "p_payment_id" "uuid", "p_dispute_id" "uuid", "p_event_id" "uuid", "p_metadata" "jsonb"); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."upsert_operational_alert"("p_alert_type" "text", "p_severity" "text", "p_message" "text", "p_job_id" "uuid", "p_electrician_id" "uuid", "p_payment_id" "uuid", "p_dispute_id" "uuid", "p_event_id" "uuid", "p_metadata" "jsonb") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."upsert_operational_alert"("p_alert_type" "text", "p_severity" "text", "p_message" "text", "p_job_id" "uuid", "p_electrician_id" "uuid", "p_payment_id" "uuid", "p_dispute_id" "uuid", "p_event_id" "uuid", "p_metadata" "jsonb") TO "service_role";


--
-- Name: FUNCTION "verify_guest_otp"("p_job_id" "uuid", "p_access_token" "text", "p_action_type" "text", "p_challenge_id" "uuid", "p_otp_code" "text"); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."verify_guest_otp"("p_job_id" "uuid", "p_access_token" "text", "p_action_type" "text", "p_challenge_id" "uuid", "p_otp_code" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."verify_guest_otp"("p_job_id" "uuid", "p_access_token" "text", "p_action_type" "text", "p_challenge_id" "uuid", "p_otp_code" "text") TO "service_role";
GRANT ALL ON FUNCTION "public"."verify_guest_otp"("p_job_id" "uuid", "p_access_token" "text", "p_action_type" "text", "p_challenge_id" "uuid", "p_otp_code" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."verify_guest_otp"("p_job_id" "uuid", "p_access_token" "text", "p_action_type" "text", "p_challenge_id" "uuid", "p_otp_code" "text") TO "authenticated";


--
-- Name: FUNCTION "verify_job_payment"("p_payment_id" "uuid", "p_approved" boolean, "p_admin_note" "text"); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."verify_job_payment"("p_payment_id" "uuid", "p_approved" boolean, "p_admin_note" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."verify_job_payment"("p_payment_id" "uuid", "p_approved" boolean, "p_admin_note" "text") TO "service_role";
GRANT ALL ON FUNCTION "public"."verify_job_payment"("p_payment_id" "uuid", "p_approved" boolean, "p_admin_note" "text") TO "authenticated";


--
-- Name: TABLE "admin_settings"; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE "public"."admin_settings" TO "anon";
GRANT ALL ON TABLE "public"."admin_settings" TO "authenticated";
GRANT ALL ON TABLE "public"."admin_settings" TO "service_role";


--
-- Name: TABLE "customer_addresses"; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE "public"."customer_addresses" TO "anon";
GRANT ALL ON TABLE "public"."customer_addresses" TO "authenticated";
GRANT ALL ON TABLE "public"."customer_addresses" TO "service_role";


--
-- Name: TABLE "electrician_certifications"; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE "public"."electrician_certifications" TO "anon";
GRANT ALL ON TABLE "public"."electrician_certifications" TO "authenticated";
GRANT ALL ON TABLE "public"."electrician_certifications" TO "service_role";


--
-- Name: TABLE "electrician_documents"; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE "public"."electrician_documents" TO "anon";
GRANT ALL ON TABLE "public"."electrician_documents" TO "authenticated";
GRANT ALL ON TABLE "public"."electrician_documents" TO "service_role";


--
-- Name: TABLE "electrician_skills"; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE "public"."electrician_skills" TO "anon";
GRANT ALL ON TABLE "public"."electrician_skills" TO "authenticated";
GRANT ALL ON TABLE "public"."electrician_skills" TO "service_role";


--
-- Name: TABLE "event_replay_runs"; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE "public"."event_replay_runs" TO "service_role";
GRANT SELECT ON TABLE "public"."event_replay_runs" TO "authenticated";


--
-- Name: TABLE "expertise_categories"; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE "public"."expertise_categories" TO "anon";
GRANT ALL ON TABLE "public"."expertise_categories" TO "authenticated";
GRANT ALL ON TABLE "public"."expertise_categories" TO "service_role";


--
-- Name: TABLE "guest_action_tokens"; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE "public"."guest_action_tokens" TO "service_role";


--
-- Name: TABLE "guest_booking_attempts"; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE "public"."guest_booking_attempts" TO "service_role";


--
-- Name: TABLE "guest_customers"; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE "public"."guest_customers" TO "anon";
GRANT ALL ON TABLE "public"."guest_customers" TO "authenticated";
GRANT ALL ON TABLE "public"."guest_customers" TO "service_role";


--
-- Name: TABLE "guest_otps"; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE "public"."guest_otps" TO "service_role";


--
-- Name: TABLE "job_events"; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE "public"."job_events" TO "service_role";
GRANT SELECT ON TABLE "public"."job_events" TO "authenticated";


--
-- Name: TABLE "job_state_projections"; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE "public"."job_state_projections" TO "service_role";
GRANT SELECT ON TABLE "public"."job_state_projections" TO "authenticated";


--
-- Name: TABLE "job_current_state_from_events"; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE "public"."job_current_state_from_events" TO "service_role";


--
-- Name: SEQUENCE "job_events_event_sequence_seq"; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON SEQUENCE "public"."job_events_event_sequence_seq" TO "service_role";


--
-- Name: TABLE "job_messages"; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE "public"."job_messages" TO "anon";
GRANT ALL ON TABLE "public"."job_messages" TO "authenticated";
GRANT ALL ON TABLE "public"."job_messages" TO "service_role";


--
-- Name: TABLE "job_photos"; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE "public"."job_photos" TO "anon";
GRANT ALL ON TABLE "public"."job_photos" TO "authenticated";
GRANT ALL ON TABLE "public"."job_photos" TO "service_role";


--
-- Name: TABLE "job_timeline"; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE "public"."job_timeline" TO "anon";
GRANT ALL ON TABLE "public"."job_timeline" TO "authenticated";
GRANT ALL ON TABLE "public"."job_timeline" TO "service_role";


--
-- Name: TABLE "job_timeline_from_events"; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE "public"."job_timeline_from_events" TO "service_role";


--
-- Name: TABLE "notifications"; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE "public"."notifications" TO "anon";
GRANT ALL ON TABLE "public"."notifications" TO "authenticated";
GRANT ALL ON TABLE "public"."notifications" TO "service_role";


--
-- Name: TABLE "operation_requests"; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE "public"."operation_requests" TO "service_role";
GRANT SELECT ON TABLE "public"."operation_requests" TO "authenticated";


--
-- Name: TABLE "operational_automation_runs"; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE "public"."operational_automation_runs" TO "service_role";
GRANT SELECT ON TABLE "public"."operational_automation_runs" TO "authenticated";


--
-- Name: TABLE "operational_metrics"; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE "public"."operational_metrics" TO "service_role";
GRANT SELECT ON TABLE "public"."operational_metrics" TO "authenticated";


--
-- Name: TABLE "quote_items"; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE "public"."quote_items" TO "anon";
GRANT ALL ON TABLE "public"."quote_items" TO "authenticated";
GRANT ALL ON TABLE "public"."quote_items" TO "service_role";


--
-- Name: TABLE "wallet_transactions"; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE "public"."wallet_transactions" TO "anon";
GRANT ALL ON TABLE "public"."wallet_transactions" TO "authenticated";
GRANT ALL ON TABLE "public"."wallet_transactions" TO "service_role";


--
-- Name: TABLE "buckets"; Type: ACL; Schema: storage; Owner: supabase_storage_admin
--

REVOKE ALL ON TABLE "storage"."buckets" FROM "supabase_storage_admin";
GRANT ALL ON TABLE "storage"."buckets" TO "supabase_storage_admin" WITH GRANT OPTION;
GRANT ALL ON TABLE "storage"."buckets" TO "service_role";
GRANT ALL ON TABLE "storage"."buckets" TO "authenticated";
GRANT ALL ON TABLE "storage"."buckets" TO "anon";
GRANT ALL ON TABLE "storage"."buckets" TO "postgres" WITH GRANT OPTION;


--
-- Name: TABLE "buckets_analytics"; Type: ACL; Schema: storage; Owner: supabase_storage_admin
--

GRANT ALL ON TABLE "storage"."buckets_analytics" TO "service_role";
GRANT ALL ON TABLE "storage"."buckets_analytics" TO "authenticated";
GRANT ALL ON TABLE "storage"."buckets_analytics" TO "anon";


--
-- Name: TABLE "buckets_vectors"; Type: ACL; Schema: storage; Owner: supabase_storage_admin
--

GRANT SELECT ON TABLE "storage"."buckets_vectors" TO "service_role";
GRANT SELECT ON TABLE "storage"."buckets_vectors" TO "authenticated";
GRANT SELECT ON TABLE "storage"."buckets_vectors" TO "anon";


--
-- Name: TABLE "objects"; Type: ACL; Schema: storage; Owner: supabase_storage_admin
--

REVOKE ALL ON TABLE "storage"."objects" FROM "supabase_storage_admin";
GRANT ALL ON TABLE "storage"."objects" TO "supabase_storage_admin" WITH GRANT OPTION;
GRANT ALL ON TABLE "storage"."objects" TO "service_role";
GRANT ALL ON TABLE "storage"."objects" TO "authenticated";
GRANT ALL ON TABLE "storage"."objects" TO "anon";
GRANT ALL ON TABLE "storage"."objects" TO "postgres" WITH GRANT OPTION;


--
-- Name: TABLE "s3_multipart_uploads"; Type: ACL; Schema: storage; Owner: supabase_storage_admin
--

GRANT ALL ON TABLE "storage"."s3_multipart_uploads" TO "service_role";
GRANT SELECT ON TABLE "storage"."s3_multipart_uploads" TO "authenticated";
GRANT SELECT ON TABLE "storage"."s3_multipart_uploads" TO "anon";


--
-- Name: TABLE "s3_multipart_uploads_parts"; Type: ACL; Schema: storage; Owner: supabase_storage_admin
--

GRANT ALL ON TABLE "storage"."s3_multipart_uploads_parts" TO "service_role";
GRANT SELECT ON TABLE "storage"."s3_multipart_uploads_parts" TO "authenticated";
GRANT SELECT ON TABLE "storage"."s3_multipart_uploads_parts" TO "anon";


--
-- Name: TABLE "vector_indexes"; Type: ACL; Schema: storage; Owner: supabase_storage_admin
--

GRANT SELECT ON TABLE "storage"."vector_indexes" TO "service_role";
GRANT SELECT ON TABLE "storage"."vector_indexes" TO "authenticated";
GRANT SELECT ON TABLE "storage"."vector_indexes" TO "anon";


--
-- Name: DEFAULT PRIVILEGES FOR SEQUENCES; Type: DEFAULT ACL; Schema: public; Owner: postgres
--

ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "service_role";


--
-- Name: DEFAULT PRIVILEGES FOR SEQUENCES; Type: DEFAULT ACL; Schema: public; Owner: supabase_admin
--

ALTER DEFAULT PRIVILEGES FOR ROLE "supabase_admin" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "supabase_admin" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "supabase_admin" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "supabase_admin" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "service_role";


--
-- Name: DEFAULT PRIVILEGES FOR FUNCTIONS; Type: DEFAULT ACL; Schema: public; Owner: postgres
--

ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "service_role";


--
-- Name: DEFAULT PRIVILEGES FOR FUNCTIONS; Type: DEFAULT ACL; Schema: public; Owner: supabase_admin
--

ALTER DEFAULT PRIVILEGES FOR ROLE "supabase_admin" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "supabase_admin" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "supabase_admin" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "supabase_admin" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "service_role";


--
-- Name: DEFAULT PRIVILEGES FOR TABLES; Type: DEFAULT ACL; Schema: public; Owner: postgres
--

ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "service_role";


--
-- Name: DEFAULT PRIVILEGES FOR TABLES; Type: DEFAULT ACL; Schema: public; Owner: supabase_admin
--

ALTER DEFAULT PRIVILEGES FOR ROLE "supabase_admin" IN SCHEMA "public" GRANT ALL ON TABLES TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "supabase_admin" IN SCHEMA "public" GRANT ALL ON TABLES TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "supabase_admin" IN SCHEMA "public" GRANT ALL ON TABLES TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "supabase_admin" IN SCHEMA "public" GRANT ALL ON TABLES TO "service_role";


--
-- Name: DEFAULT PRIVILEGES FOR SEQUENCES; Type: DEFAULT ACL; Schema: storage; Owner: postgres
--

ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "storage" GRANT ALL ON SEQUENCES TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "storage" GRANT ALL ON SEQUENCES TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "storage" GRANT ALL ON SEQUENCES TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "storage" GRANT ALL ON SEQUENCES TO "service_role";


--
-- Name: DEFAULT PRIVILEGES FOR FUNCTIONS; Type: DEFAULT ACL; Schema: storage; Owner: postgres
--

ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "storage" GRANT ALL ON FUNCTIONS TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "storage" GRANT ALL ON FUNCTIONS TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "storage" GRANT ALL ON FUNCTIONS TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "storage" GRANT ALL ON FUNCTIONS TO "service_role";


--
-- Name: DEFAULT PRIVILEGES FOR TABLES; Type: DEFAULT ACL; Schema: storage; Owner: postgres
--

ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "storage" GRANT ALL ON TABLES TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "storage" GRANT ALL ON TABLES TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "storage" GRANT ALL ON TABLES TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "storage" GRANT ALL ON TABLES TO "service_role";


--
-- PostgreSQL database dump complete
--

\unrestrict axraMLCcBVkKhyrZKMQWFDUZX45QRDe8xJNLhYQ7sA2hl8jJ5b2g6eNtduj9a0Z
