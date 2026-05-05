-- Canonical schema snapshot for VoltFriq.
-- Rebuild with ./scripts/rebuild-schema.sh

--
-- PostgreSQL database dump
--

\restrict TtFFXOux5TxedzkAASB8ayF6wpMvPfR2Rvt8eFyAuw2MC75rim6iiJ6Fhil76Bw

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

SET default_tablespace = '';

SET default_table_access_method = "heap";

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
    "onboarding_answers" "jsonb" DEFAULT '[]'::"jsonb" NOT NULL
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
begin
  insert into public.job_timeline (job_id, status, note, actor_profile_id)
  values (p_job_id, p_status, p_note, p_actor_profile_id);
end;
$$;


ALTER FUNCTION "public"."append_job_timeline"("p_job_id" "uuid", "p_status" "public"."job_status", "p_note" "text", "p_actor_profile_id" "uuid") OWNER TO "postgres";

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
    "customer_access_token" "text"
);


ALTER TABLE "public"."jobs" OWNER TO "postgres";

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


ALTER FUNCTION "public"."create_customer_job"("p_service_area" "text", "p_location_label" "text", "p_latitude" double precision, "p_longitude" double precision, "p_issue_category" "text", "p_urgency" "public"."job_urgency", "p_customer_note" "text", "p_requires_assessment" boolean, "p_material_handling" "text", "p_photo_paths" "text"[]) OWNER TO "postgres";

--
-- Name: disputes; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE "public"."disputes" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "job_id" "uuid" NOT NULL,
    "customer_id" "uuid" NOT NULL,
    "electrician_id" "uuid",
    "issue_type" "text" NOT NULL,
    "details" "text",
    "status" "text" DEFAULT 'open'::"text" NOT NULL,
    "resolution_action" "text",
    "resolution_note" "text",
    "resolved_by" "uuid",
    "resolved_at" timestamp with time zone,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
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


ALTER FUNCTION "public"."create_dispute"("p_job_id" "uuid", "p_issue_type" "text", "p_details" "text") OWNER TO "postgres";

--
-- Name: create_guest_customer_job("text", "text", "text", double precision, double precision, "text", "public"."job_urgency", "text", boolean, "text", "text"[]); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."create_guest_customer_job"("p_phone" "text", "p_service_area" "text", "p_location_label" "text", "p_latitude" double precision, "p_longitude" double precision, "p_issue_category" "text", "p_urgency" "public"."job_urgency", "p_customer_note" "text", "p_requires_assessment" boolean, "p_material_handling" "text", "p_photo_paths" "text"[] DEFAULT '{}'::"text"[]) RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
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


ALTER FUNCTION "public"."create_guest_customer_job"("p_phone" "text", "p_service_area" "text", "p_location_label" "text", "p_latitude" double precision, "p_longitude" double precision, "p_issue_category" "text", "p_urgency" "public"."job_urgency", "p_customer_note" "text", "p_requires_assessment" boolean, "p_material_handling" "text", "p_photo_paths" "text"[]) OWNER TO "postgres";

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
    LANGUAGE "sql" STABLE
    AS $$
  select id from public.customers where profile_id = auth.uid() limit 1;
$$;


ALTER FUNCTION "public"."current_customer_id"() OWNER TO "postgres";

--
-- Name: current_electrician_id(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."current_electrician_id"() RETURNS "uuid"
    LANGUAGE "sql" STABLE
    AS $$
  select id from public.electricians where profile_id = auth.uid() limit 1;
$$;


ALTER FUNCTION "public"."current_electrician_id"() OWNER TO "postgres";

--
-- Name: dispatch_job("uuid", "uuid"); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."dispatch_job"("p_job_id" "uuid", "p_manual_electrician_id" "uuid" DEFAULT NULL::"uuid") RETURNS "public"."jobs"
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
  job_row public.jobs;
begin
  if not ("public"."is_admin"() or "auth"."role"() = 'service_role') then
    raise exception 'Admin or service role required';
  end if;

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


ALTER FUNCTION "public"."dispatch_job"("p_job_id" "uuid", "p_manual_electrician_id" "uuid") OWNER TO "postgres";

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


ALTER FUNCTION "public"."electrician_accept_job"("p_job_id" "uuid") OWNER TO "postgres";

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


ALTER FUNCTION "public"."electrician_reject_job"("p_job_id" "uuid") OWNER TO "postgres";

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
    "referral_code" "text"
);


ALTER TABLE "public"."profiles" OWNER TO "postgres";

--
-- Name: ensure_profile_for_current_user(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."ensure_profile_for_current_user"() RETURNS "public"."profiles"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
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
-- Name: guest_job_payload("uuid", "text"); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."guest_job_payload"("p_job_id" "uuid", "p_access_token" "text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
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


ALTER FUNCTION "public"."guest_job_payload"("p_job_id" "uuid", "p_access_token" "text") OWNER TO "postgres";

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
    LANGUAGE "sql" STABLE
    AS $$
  select exists (
    select 1
    from public.profiles
    where id = auth.uid() and role = 'admin'
  );
$$;


ALTER FUNCTION "public"."is_admin"() OWNER TO "postgres";

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


ALTER FUNCTION "public"."process_dispatch_queue"() OWNER TO "postgres";

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
    "trust_notes" "text"
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
begin
  select * into job_row from public.jobs where id = p_job_id for update;
  if not found then
    raise exception 'Job not found';
  end if;

  if is_admin_actor then
    actor_metadata := actor_metadata || jsonb_build_object('admin_override', true);
  elsif job_row.customer_id = actor_customer_id then
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
      raise exception 'Customers cannot move a job from % to %', job_row.status, p_next_status;
    end if;
  elsif job_row.assigned_electrician_id = actor_electrician_id then
    if not (
      (job_row.status = 'assessment_confirmed' and p_next_status = 'en_route')
      or (job_row.status = 'en_route' and p_next_status = 'on_site')
      or (job_row.status = 'payment_confirmed' and p_next_status = 'work_in_progress')
      or (job_row.status = 'work_in_progress' and p_next_status = 'electrician_completed')
    ) then
      raise exception 'Electricians cannot move a job from % to %', job_row.status, p_next_status;
    end if;
  else
    raise exception 'You do not have permission to update this job';
  end if;

  update public.jobs
  set status = p_next_status,
      customer_confirmed_at = case when p_next_status = 'customer_confirmed' then coalesce(customer_confirmed_at, now()) else customer_confirmed_at end,
      electrician_completed_at = case when p_next_status = 'electrician_completed' then coalesce(electrician_completed_at, now()) else electrician_completed_at end,
      payout_released_at = case when p_next_status = 'payout_complete' then coalesce(payout_released_at, now()) else payout_released_at end
  where id = p_job_id
  returning * into job_row;

  insert into public.job_timeline (job_id, status, note, actor_profile_id, metadata)
  values (p_job_id, p_next_status, p_note, auth.uid(), actor_metadata);

  return job_row;
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
-- Name: submit_guest_payment_proof("uuid", "text", "public"."payment_type", numeric, "text", "text"); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."submit_guest_payment_proof"("p_job_id" "uuid", "p_access_token" "text", "p_payment_type" "public"."payment_type", "p_amount" numeric, "p_reference" "text", "p_proof_path" "text") RETURNS "public"."job_payments"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
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


ALTER FUNCTION "public"."submit_guest_payment_proof"("p_job_id" "uuid", "p_access_token" "text", "p_payment_type" "public"."payment_type", "p_amount" numeric, "p_reference" "text", "p_proof_path" "text") OWNER TO "postgres";

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
-- Name: update_guest_job_status("uuid", "text", "public"."job_status", "text", "jsonb"); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."update_guest_job_status"("p_job_id" "uuid", "p_access_token" "text", "p_next_status" "public"."job_status", "p_note" "text" DEFAULT NULL::"text", "p_metadata" "jsonb" DEFAULT '{}'::"jsonb") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
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


ALTER FUNCTION "public"."update_guest_job_status"("p_job_id" "uuid", "p_access_token" "text", "p_next_status" "public"."job_status", "p_note" "text", "p_metadata" "jsonb") OWNER TO "postgres";

--
-- Name: verify_job_payment("uuid", boolean, "text"); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."verify_job_payment"("p_payment_id" "uuid", "p_approved" boolean, "p_admin_note" "text" DEFAULT NULL::"text") RETURNS "public"."job_payments"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
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
    LANGUAGE "plpgsql"
    AS $$
DECLARE
_parts text[];
_filename text;
BEGIN
	select string_to_array(name, '/') into _parts;
	select _parts[array_length(_parts,1)] into _filename;
	-- @todo return the last part instead of 2
	return reverse(split_part(reverse(_filename), '.', 1));
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
    LANGUAGE "plpgsql"
    AS $$
DECLARE
_parts text[];
BEGIN
	select string_to_array(name, '/') into _parts;
	return _parts[1:array_length(_parts,1)-1];
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
    LANGUAGE "plpgsql"
    AS $$
BEGIN
    return query
        select sum((metadata->>'size')::int) as size, obj.bucket_id
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
    "trust_settings" "jsonb" DEFAULT '{"elite_jobs": 60, "rising_jobs": 3, "trusted_jobs": 10, "top_rated_jobs": 25, "negative_rating_limit": 3, "negative_rating_max_score": 2, "watchlist_rank_penalty_km": 8}'::"jsonb" NOT NULL
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
-- Name: jobs_customer_access_token_key; Type: INDEX; Schema: public; Owner: postgres
--

CREATE UNIQUE INDEX "jobs_customer_access_token_key" ON "public"."jobs" USING "btree" ("customer_access_token") WHERE ("customer_access_token" IS NOT NULL);


--
-- Name: profiles_referral_code_key; Type: INDEX; Schema: public; Owner: postgres
--

CREATE UNIQUE INDEX "profiles_referral_code_key" ON "public"."profiles" USING "btree" ("referral_code") WHERE ("referral_code" IS NOT NULL);


--
-- Name: ratings_review_direction_idx; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX "ratings_review_direction_idx" ON "public"."ratings" USING "btree" ("review_direction");


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
-- Name: jobs jobs_status_notifications; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER "jobs_status_notifications" AFTER UPDATE ON "public"."jobs" FOR EACH ROW EXECUTE FUNCTION "public"."handle_job_status_notifications"();


--
-- Name: jobs jobs_touch_updated_at; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER "jobs_touch_updated_at" BEFORE UPDATE ON "public"."jobs" FOR EACH ROW EXECUTE FUNCTION "public"."touch_updated_at"();


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
-- Name: guest_customers guest customers admin or assigned electrician read; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY "guest customers admin or assigned electrician read" ON "public"."guest_customers" FOR SELECT USING (("public"."is_admin"() OR (EXISTS ( SELECT 1
   FROM "public"."jobs" "j"
  WHERE (("j"."guest_customer_id" = "guest_customers"."id") AND ("j"."assigned_electrician_id" = "public"."current_electrician_id"()))))));


--
-- Name: guest_customers; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE "public"."guest_customers" ENABLE ROW LEVEL SECURITY;

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
-- Name: job_timeline job timeline customer electrician or admin; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY "job timeline customer electrician or admin" ON "public"."job_timeline" FOR SELECT USING (("public"."is_admin"() OR (EXISTS ( SELECT 1
   FROM "public"."jobs" "j"
  WHERE (("j"."id" = "job_timeline"."job_id") AND (("j"."customer_id" = "public"."current_customer_id"()) OR ("j"."assigned_electrician_id" = "public"."current_electrician_id"())))))));


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

CREATE POLICY "voltfriq electrician docs write" ON "storage"."objects" FOR INSERT TO "authenticated" WITH CHECK ((("bucket_id" = 'electrician-documents'::"text") AND ("public"."is_admin"() OR (EXISTS ( SELECT 1
   FROM "public"."electricians" "e"
  WHERE (("e"."profile_id" = "auth"."uid"()) AND (("split_part"("objects"."name", '/'::"text", 1) = ("e"."id")::"text") OR ("split_part"("objects"."name", '/'::"text", 1) = 'appeals'::"text"))))))));


--
-- Name: objects voltfriq guest upload write; Type: POLICY; Schema: storage; Owner: supabase_storage_admin
--

CREATE POLICY "voltfriq guest upload write" ON "storage"."objects" FOR INSERT TO "anon" WITH CHECK ((("bucket_id" = ANY (ARRAY['job-photos'::"text", 'payment-proofs'::"text"])) AND ("split_part"("name", '/'::"text", 1) = 'guest'::"text")));


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
-- Name: TABLE "electricians"; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE "public"."electricians" TO "anon";
GRANT ALL ON TABLE "public"."electricians" TO "authenticated";
GRANT ALL ON TABLE "public"."electricians" TO "service_role";


--
-- Name: FUNCTION "admin_set_electrician_status"("p_electrician_id" "uuid", "p_status" "public"."electrician_status", "p_reason" "text"); Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON FUNCTION "public"."admin_set_electrician_status"("p_electrician_id" "uuid", "p_status" "public"."electrician_status", "p_reason" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."admin_set_electrician_status"("p_electrician_id" "uuid", "p_status" "public"."electrician_status", "p_reason" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."admin_set_electrician_status"("p_electrician_id" "uuid", "p_status" "public"."electrician_status", "p_reason" "text") TO "service_role";


--
-- Name: FUNCTION "admin_set_electrician_watchlist"("p_electrician_id" "uuid", "p_watchlist" boolean, "p_reason" "text"); Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON FUNCTION "public"."admin_set_electrician_watchlist"("p_electrician_id" "uuid", "p_watchlist" boolean, "p_reason" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."admin_set_electrician_watchlist"("p_electrician_id" "uuid", "p_watchlist" boolean, "p_reason" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."admin_set_electrician_watchlist"("p_electrician_id" "uuid", "p_watchlist" boolean, "p_reason" "text") TO "service_role";


--
-- Name: FUNCTION "append_job_timeline"("p_job_id" "uuid", "p_status" "public"."job_status", "p_note" "text", "p_actor_profile_id" "uuid"); Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON FUNCTION "public"."append_job_timeline"("p_job_id" "uuid", "p_status" "public"."job_status", "p_note" "text", "p_actor_profile_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."append_job_timeline"("p_job_id" "uuid", "p_status" "public"."job_status", "p_note" "text", "p_actor_profile_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."append_job_timeline"("p_job_id" "uuid", "p_status" "public"."job_status", "p_note" "text", "p_actor_profile_id" "uuid") TO "service_role";


--
-- Name: FUNCTION "calculate_electrician_level"("p_completed_jobs" integer, "p_average_rating" numeric, "p_total_ratings" integer, "p_response_rate" numeric, "p_watchlist" boolean); Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON FUNCTION "public"."calculate_electrician_level"("p_completed_jobs" integer, "p_average_rating" numeric, "p_total_ratings" integer, "p_response_rate" numeric, "p_watchlist" boolean) TO "anon";
GRANT ALL ON FUNCTION "public"."calculate_electrician_level"("p_completed_jobs" integer, "p_average_rating" numeric, "p_total_ratings" integer, "p_response_rate" numeric, "p_watchlist" boolean) TO "authenticated";
GRANT ALL ON FUNCTION "public"."calculate_electrician_level"("p_completed_jobs" integer, "p_average_rating" numeric, "p_total_ratings" integer, "p_response_rate" numeric, "p_watchlist" boolean) TO "service_role";


--
-- Name: TABLE "jobs"; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE "public"."jobs" TO "anon";
GRANT ALL ON TABLE "public"."jobs" TO "authenticated";
GRANT ALL ON TABLE "public"."jobs" TO "service_role";


--
-- Name: FUNCTION "create_customer_job"("p_service_area" "text", "p_location_label" "text", "p_latitude" double precision, "p_longitude" double precision, "p_issue_category" "text", "p_urgency" "public"."job_urgency", "p_customer_note" "text", "p_requires_assessment" boolean, "p_material_handling" "text", "p_photo_paths" "text"[]); Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON FUNCTION "public"."create_customer_job"("p_service_area" "text", "p_location_label" "text", "p_latitude" double precision, "p_longitude" double precision, "p_issue_category" "text", "p_urgency" "public"."job_urgency", "p_customer_note" "text", "p_requires_assessment" boolean, "p_material_handling" "text", "p_photo_paths" "text"[]) TO "anon";
GRANT ALL ON FUNCTION "public"."create_customer_job"("p_service_area" "text", "p_location_label" "text", "p_latitude" double precision, "p_longitude" double precision, "p_issue_category" "text", "p_urgency" "public"."job_urgency", "p_customer_note" "text", "p_requires_assessment" boolean, "p_material_handling" "text", "p_photo_paths" "text"[]) TO "authenticated";
GRANT ALL ON FUNCTION "public"."create_customer_job"("p_service_area" "text", "p_location_label" "text", "p_latitude" double precision, "p_longitude" double precision, "p_issue_category" "text", "p_urgency" "public"."job_urgency", "p_customer_note" "text", "p_requires_assessment" boolean, "p_material_handling" "text", "p_photo_paths" "text"[]) TO "service_role";


--
-- Name: TABLE "disputes"; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE "public"."disputes" TO "anon";
GRANT ALL ON TABLE "public"."disputes" TO "authenticated";
GRANT ALL ON TABLE "public"."disputes" TO "service_role";


--
-- Name: FUNCTION "create_dispute"("p_job_id" "uuid", "p_issue_type" "text", "p_details" "text"); Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON FUNCTION "public"."create_dispute"("p_job_id" "uuid", "p_issue_type" "text", "p_details" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."create_dispute"("p_job_id" "uuid", "p_issue_type" "text", "p_details" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."create_dispute"("p_job_id" "uuid", "p_issue_type" "text", "p_details" "text") TO "service_role";


--
-- Name: FUNCTION "create_guest_customer_job"("p_phone" "text", "p_service_area" "text", "p_location_label" "text", "p_latitude" double precision, "p_longitude" double precision, "p_issue_category" "text", "p_urgency" "public"."job_urgency", "p_customer_note" "text", "p_requires_assessment" boolean, "p_material_handling" "text", "p_photo_paths" "text"[]); Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON FUNCTION "public"."create_guest_customer_job"("p_phone" "text", "p_service_area" "text", "p_location_label" "text", "p_latitude" double precision, "p_longitude" double precision, "p_issue_category" "text", "p_urgency" "public"."job_urgency", "p_customer_note" "text", "p_requires_assessment" boolean, "p_material_handling" "text", "p_photo_paths" "text"[]) TO "anon";
GRANT ALL ON FUNCTION "public"."create_guest_customer_job"("p_phone" "text", "p_service_area" "text", "p_location_label" "text", "p_latitude" double precision, "p_longitude" double precision, "p_issue_category" "text", "p_urgency" "public"."job_urgency", "p_customer_note" "text", "p_requires_assessment" boolean, "p_material_handling" "text", "p_photo_paths" "text"[]) TO "authenticated";
GRANT ALL ON FUNCTION "public"."create_guest_customer_job"("p_phone" "text", "p_service_area" "text", "p_location_label" "text", "p_latitude" double precision, "p_longitude" double precision, "p_issue_category" "text", "p_urgency" "public"."job_urgency", "p_customer_note" "text", "p_requires_assessment" boolean, "p_material_handling" "text", "p_photo_paths" "text"[]) TO "service_role";


--
-- Name: FUNCTION "create_notification"("p_profile_id" "uuid", "p_job_id" "uuid", "p_event" "public"."notification_event", "p_title" "text", "p_body" "text", "p_metadata" "jsonb"); Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON FUNCTION "public"."create_notification"("p_profile_id" "uuid", "p_job_id" "uuid", "p_event" "public"."notification_event", "p_title" "text", "p_body" "text", "p_metadata" "jsonb") TO "anon";
GRANT ALL ON FUNCTION "public"."create_notification"("p_profile_id" "uuid", "p_job_id" "uuid", "p_event" "public"."notification_event", "p_title" "text", "p_body" "text", "p_metadata" "jsonb") TO "authenticated";
GRANT ALL ON FUNCTION "public"."create_notification"("p_profile_id" "uuid", "p_job_id" "uuid", "p_event" "public"."notification_event", "p_title" "text", "p_body" "text", "p_metadata" "jsonb") TO "service_role";


--
-- Name: FUNCTION "current_customer_id"(); Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON FUNCTION "public"."current_customer_id"() TO "anon";
GRANT ALL ON FUNCTION "public"."current_customer_id"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."current_customer_id"() TO "service_role";


--
-- Name: FUNCTION "current_electrician_id"(); Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON FUNCTION "public"."current_electrician_id"() TO "anon";
GRANT ALL ON FUNCTION "public"."current_electrician_id"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."current_electrician_id"() TO "service_role";


--
-- Name: FUNCTION "dispatch_job"("p_job_id" "uuid", "p_manual_electrician_id" "uuid"); Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON FUNCTION "public"."dispatch_job"("p_job_id" "uuid", "p_manual_electrician_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."dispatch_job"("p_job_id" "uuid", "p_manual_electrician_id" "uuid") TO "service_role";


--
-- Name: FUNCTION "electrician_accept_job"("p_job_id" "uuid"); Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON FUNCTION "public"."electrician_accept_job"("p_job_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."electrician_accept_job"("p_job_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."electrician_accept_job"("p_job_id" "uuid") TO "service_role";


--
-- Name: FUNCTION "electrician_level_rank"("p_level" "text"); Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON FUNCTION "public"."electrician_level_rank"("p_level" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."electrician_level_rank"("p_level" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."electrician_level_rank"("p_level" "text") TO "service_role";


--
-- Name: FUNCTION "electrician_reject_job"("p_job_id" "uuid"); Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON FUNCTION "public"."electrician_reject_job"("p_job_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."electrician_reject_job"("p_job_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."electrician_reject_job"("p_job_id" "uuid") TO "service_role";


--
-- Name: TABLE "profiles"; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE "public"."profiles" TO "anon";
GRANT ALL ON TABLE "public"."profiles" TO "authenticated";
GRANT ALL ON TABLE "public"."profiles" TO "service_role";


--
-- Name: FUNCTION "ensure_profile_for_current_user"(); Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON FUNCTION "public"."ensure_profile_for_current_user"() TO "anon";
GRANT ALL ON FUNCTION "public"."ensure_profile_for_current_user"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."ensure_profile_for_current_user"() TO "service_role";


--
-- Name: TABLE "wallets"; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE "public"."wallets" TO "anon";
GRANT ALL ON TABLE "public"."wallets" TO "authenticated";
GRANT ALL ON TABLE "public"."wallets" TO "service_role";


--
-- Name: FUNCTION "ensure_wallet_for_profile"("p_profile_id" "uuid"); Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON FUNCTION "public"."ensure_wallet_for_profile"("p_profile_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."ensure_wallet_for_profile"("p_profile_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."ensure_wallet_for_profile"("p_profile_id" "uuid") TO "service_role";


--
-- Name: FUNCTION "find_matching_electricians"("p_service_area" "text", "p_issue_category" "text", "p_latitude" double precision, "p_longitude" double precision, "p_limit" integer); Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON FUNCTION "public"."find_matching_electricians"("p_service_area" "text", "p_issue_category" "text", "p_latitude" double precision, "p_longitude" double precision, "p_limit" integer) TO "anon";
GRANT ALL ON FUNCTION "public"."find_matching_electricians"("p_service_area" "text", "p_issue_category" "text", "p_latitude" double precision, "p_longitude" double precision, "p_limit" integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."find_matching_electricians"("p_service_area" "text", "p_issue_category" "text", "p_latitude" double precision, "p_longitude" double precision, "p_limit" integer) TO "service_role";


--
-- Name: FUNCTION "generate_referral_code"(); Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON FUNCTION "public"."generate_referral_code"() TO "anon";
GRANT ALL ON FUNCTION "public"."generate_referral_code"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."generate_referral_code"() TO "service_role";


--
-- Name: FUNCTION "get_guest_job"("p_job_id" "uuid", "p_access_token" "text"); Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON FUNCTION "public"."get_guest_job"("p_job_id" "uuid", "p_access_token" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."get_guest_job"("p_job_id" "uuid", "p_access_token" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_guest_job"("p_job_id" "uuid", "p_access_token" "text") TO "service_role";


--
-- Name: FUNCTION "guest_job_payload"("p_job_id" "uuid", "p_access_token" "text"); Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON FUNCTION "public"."guest_job_payload"("p_job_id" "uuid", "p_access_token" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."guest_job_payload"("p_job_id" "uuid", "p_access_token" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."guest_job_payload"("p_job_id" "uuid", "p_access_token" "text") TO "service_role";


--
-- Name: FUNCTION "handle_job_status_notifications"(); Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON FUNCTION "public"."handle_job_status_notifications"() TO "anon";
GRANT ALL ON FUNCTION "public"."handle_job_status_notifications"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."handle_job_status_notifications"() TO "service_role";


--
-- Name: FUNCTION "handle_new_user"(); Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON FUNCTION "public"."handle_new_user"() TO "anon";
GRANT ALL ON FUNCTION "public"."handle_new_user"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."handle_new_user"() TO "service_role";


--
-- Name: FUNCTION "handle_profile_rewards_setup"(); Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON FUNCTION "public"."handle_profile_rewards_setup"() TO "anon";
GRANT ALL ON FUNCTION "public"."handle_profile_rewards_setup"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."handle_profile_rewards_setup"() TO "service_role";


--
-- Name: FUNCTION "handle_profile_wallet_setup"(); Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON FUNCTION "public"."handle_profile_wallet_setup"() TO "anon";
GRANT ALL ON FUNCTION "public"."handle_profile_wallet_setup"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."handle_profile_wallet_setup"() TO "service_role";


--
-- Name: FUNCTION "handle_wallets_touch_updated_at"(); Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON FUNCTION "public"."handle_wallets_touch_updated_at"() TO "anon";
GRANT ALL ON FUNCTION "public"."handle_wallets_touch_updated_at"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."handle_wallets_touch_updated_at"() TO "service_role";


--
-- Name: FUNCTION "is_admin"(); Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON FUNCTION "public"."is_admin"() TO "anon";
GRANT ALL ON FUNCTION "public"."is_admin"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."is_admin"() TO "service_role";


--
-- Name: TABLE "referrals"; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE "public"."referrals" TO "anon";
GRANT ALL ON TABLE "public"."referrals" TO "authenticated";
GRANT ALL ON TABLE "public"."referrals" TO "service_role";


--
-- Name: FUNCTION "link_referral_code"("p_referral_code" "text"); Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON FUNCTION "public"."link_referral_code"("p_referral_code" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."link_referral_code"("p_referral_code" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."link_referral_code"("p_referral_code" "text") TO "service_role";


--
-- Name: FUNCTION "process_dispatch_queue"(); Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON FUNCTION "public"."process_dispatch_queue"() TO "anon";
GRANT ALL ON FUNCTION "public"."process_dispatch_queue"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."process_dispatch_queue"() TO "service_role";


--
-- Name: TABLE "customers"; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE "public"."customers" TO "anon";
GRANT ALL ON TABLE "public"."customers" TO "authenticated";
GRANT ALL ON TABLE "public"."customers" TO "service_role";


--
-- Name: FUNCTION "refresh_customer_trust_metrics"("p_customer_id" "uuid"); Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON FUNCTION "public"."refresh_customer_trust_metrics"("p_customer_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."refresh_customer_trust_metrics"("p_customer_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."refresh_customer_trust_metrics"("p_customer_id" "uuid") TO "service_role";


--
-- Name: FUNCTION "refresh_electrician_trust_metrics"("p_electrician_id" "uuid"); Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON FUNCTION "public"."refresh_electrician_trust_metrics"("p_electrician_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."refresh_electrician_trust_metrics"("p_electrician_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."refresh_electrician_trust_metrics"("p_electrician_id" "uuid") TO "service_role";


--
-- Name: FUNCTION "resolve_dispute"("p_dispute_id" "uuid", "p_status" "text", "p_resolution_action" "text", "p_resolution_note" "text"); Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON FUNCTION "public"."resolve_dispute"("p_dispute_id" "uuid", "p_status" "text", "p_resolution_action" "text", "p_resolution_note" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."resolve_dispute"("p_dispute_id" "uuid", "p_status" "text", "p_resolution_action" "text", "p_resolution_note" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."resolve_dispute"("p_dispute_id" "uuid", "p_status" "text", "p_resolution_action" "text", "p_resolution_note" "text") TO "service_role";


--
-- Name: TABLE "electrician_appeals"; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE "public"."electrician_appeals" TO "anon";
GRANT ALL ON TABLE "public"."electrician_appeals" TO "authenticated";
GRANT ALL ON TABLE "public"."electrician_appeals" TO "service_role";


--
-- Name: FUNCTION "resolve_electrician_appeal"("p_appeal_id" "uuid", "p_approved" boolean, "p_admin_note" "text"); Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON FUNCTION "public"."resolve_electrician_appeal"("p_appeal_id" "uuid", "p_approved" boolean, "p_admin_note" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."resolve_electrician_appeal"("p_appeal_id" "uuid", "p_approved" boolean, "p_admin_note" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."resolve_electrician_appeal"("p_appeal_id" "uuid", "p_approved" boolean, "p_admin_note" "text") TO "service_role";


--
-- Name: FUNCTION "reward_completed_referral"("p_referred_profile_id" "uuid", "p_job_id" "uuid"); Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON FUNCTION "public"."reward_completed_referral"("p_referred_profile_id" "uuid", "p_job_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."reward_completed_referral"("p_referred_profile_id" "uuid", "p_job_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."reward_completed_referral"("p_referred_profile_id" "uuid", "p_job_id" "uuid") TO "service_role";


--
-- Name: FUNCTION "set_job_status"("p_job_id" "uuid", "p_next_status" "public"."job_status", "p_note" "text", "p_metadata" "jsonb"); Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON FUNCTION "public"."set_job_status"("p_job_id" "uuid", "p_next_status" "public"."job_status", "p_note" "text", "p_metadata" "jsonb") TO "anon";
GRANT ALL ON FUNCTION "public"."set_job_status"("p_job_id" "uuid", "p_next_status" "public"."job_status", "p_note" "text", "p_metadata" "jsonb") TO "authenticated";
GRANT ALL ON FUNCTION "public"."set_job_status"("p_job_id" "uuid", "p_next_status" "public"."job_status", "p_note" "text", "p_metadata" "jsonb") TO "service_role";


--
-- Name: TABLE "ratings"; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE "public"."ratings" TO "anon";
GRANT ALL ON TABLE "public"."ratings" TO "authenticated";
GRANT ALL ON TABLE "public"."ratings" TO "service_role";


--
-- Name: FUNCTION "submit_customer_review"("p_job_id" "uuid", "p_score" integer, "p_comment" "text", "p_behavior_tags" "text"[]); Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON FUNCTION "public"."submit_customer_review"("p_job_id" "uuid", "p_score" integer, "p_comment" "text", "p_behavior_tags" "text"[]) TO "anon";
GRANT ALL ON FUNCTION "public"."submit_customer_review"("p_job_id" "uuid", "p_score" integer, "p_comment" "text", "p_behavior_tags" "text"[]) TO "authenticated";
GRANT ALL ON FUNCTION "public"."submit_customer_review"("p_job_id" "uuid", "p_score" integer, "p_comment" "text", "p_behavior_tags" "text"[]) TO "service_role";


--
-- Name: FUNCTION "submit_electrician_appeal"("p_appeal_note" "text", "p_supporting_file_path" "text"); Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON FUNCTION "public"."submit_electrician_appeal"("p_appeal_note" "text", "p_supporting_file_path" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."submit_electrician_appeal"("p_appeal_note" "text", "p_supporting_file_path" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."submit_electrician_appeal"("p_appeal_note" "text", "p_supporting_file_path" "text") TO "service_role";


--
-- Name: TABLE "job_payments"; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE "public"."job_payments" TO "anon";
GRANT ALL ON TABLE "public"."job_payments" TO "authenticated";
GRANT ALL ON TABLE "public"."job_payments" TO "service_role";


--
-- Name: FUNCTION "submit_guest_payment_proof"("p_job_id" "uuid", "p_access_token" "text", "p_payment_type" "public"."payment_type", "p_amount" numeric, "p_reference" "text", "p_proof_path" "text"); Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON FUNCTION "public"."submit_guest_payment_proof"("p_job_id" "uuid", "p_access_token" "text", "p_payment_type" "public"."payment_type", "p_amount" numeric, "p_reference" "text", "p_proof_path" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."submit_guest_payment_proof"("p_job_id" "uuid", "p_access_token" "text", "p_payment_type" "public"."payment_type", "p_amount" numeric, "p_reference" "text", "p_proof_path" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."submit_guest_payment_proof"("p_job_id" "uuid", "p_access_token" "text", "p_payment_type" "public"."payment_type", "p_amount" numeric, "p_reference" "text", "p_proof_path" "text") TO "service_role";


--
-- Name: TABLE "job_quotes"; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE "public"."job_quotes" TO "anon";
GRANT ALL ON TABLE "public"."job_quotes" TO "authenticated";
GRANT ALL ON TABLE "public"."job_quotes" TO "service_role";


--
-- Name: FUNCTION "submit_job_quote"("p_job_id" "uuid", "p_findings" "text", "p_measurements" "text", "p_items" "jsonb"); Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON FUNCTION "public"."submit_job_quote"("p_job_id" "uuid", "p_findings" "text", "p_measurements" "text", "p_items" "jsonb") TO "anon";
GRANT ALL ON FUNCTION "public"."submit_job_quote"("p_job_id" "uuid", "p_findings" "text", "p_measurements" "text", "p_items" "jsonb") TO "authenticated";
GRANT ALL ON FUNCTION "public"."submit_job_quote"("p_job_id" "uuid", "p_findings" "text", "p_measurements" "text", "p_items" "jsonb") TO "service_role";


--
-- Name: FUNCTION "submit_payment_proof"("p_job_id" "uuid", "p_payment_type" "public"."payment_type", "p_amount" numeric, "p_reference" "text", "p_proof_path" "text"); Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON FUNCTION "public"."submit_payment_proof"("p_job_id" "uuid", "p_payment_type" "public"."payment_type", "p_amount" numeric, "p_reference" "text", "p_proof_path" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."submit_payment_proof"("p_job_id" "uuid", "p_payment_type" "public"."payment_type", "p_amount" numeric, "p_reference" "text", "p_proof_path" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."submit_payment_proof"("p_job_id" "uuid", "p_payment_type" "public"."payment_type", "p_amount" numeric, "p_reference" "text", "p_proof_path" "text") TO "service_role";


--
-- Name: FUNCTION "submit_rating"("p_job_id" "uuid", "p_score" integer, "p_comment" "text", "p_behavior_tags" "text"[]); Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON FUNCTION "public"."submit_rating"("p_job_id" "uuid", "p_score" integer, "p_comment" "text", "p_behavior_tags" "text"[]) TO "anon";
GRANT ALL ON FUNCTION "public"."submit_rating"("p_job_id" "uuid", "p_score" integer, "p_comment" "text", "p_behavior_tags" "text"[]) TO "authenticated";
GRANT ALL ON FUNCTION "public"."submit_rating"("p_job_id" "uuid", "p_score" integer, "p_comment" "text", "p_behavior_tags" "text"[]) TO "service_role";


--
-- Name: FUNCTION "touch_updated_at"(); Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON FUNCTION "public"."touch_updated_at"() TO "anon";
GRANT ALL ON FUNCTION "public"."touch_updated_at"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."touch_updated_at"() TO "service_role";


--
-- Name: FUNCTION "update_guest_job_status"("p_job_id" "uuid", "p_access_token" "text", "p_next_status" "public"."job_status", "p_note" "text", "p_metadata" "jsonb"); Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON FUNCTION "public"."update_guest_job_status"("p_job_id" "uuid", "p_access_token" "text", "p_next_status" "public"."job_status", "p_note" "text", "p_metadata" "jsonb") TO "anon";
GRANT ALL ON FUNCTION "public"."update_guest_job_status"("p_job_id" "uuid", "p_access_token" "text", "p_next_status" "public"."job_status", "p_note" "text", "p_metadata" "jsonb") TO "authenticated";
GRANT ALL ON FUNCTION "public"."update_guest_job_status"("p_job_id" "uuid", "p_access_token" "text", "p_next_status" "public"."job_status", "p_note" "text", "p_metadata" "jsonb") TO "service_role";


--
-- Name: FUNCTION "verify_job_payment"("p_payment_id" "uuid", "p_approved" boolean, "p_admin_note" "text"); Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON FUNCTION "public"."verify_job_payment"("p_payment_id" "uuid", "p_approved" boolean, "p_admin_note" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."verify_job_payment"("p_payment_id" "uuid", "p_approved" boolean, "p_admin_note" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."verify_job_payment"("p_payment_id" "uuid", "p_approved" boolean, "p_admin_note" "text") TO "service_role";


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
-- Name: TABLE "expertise_categories"; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE "public"."expertise_categories" TO "anon";
GRANT ALL ON TABLE "public"."expertise_categories" TO "authenticated";
GRANT ALL ON TABLE "public"."expertise_categories" TO "service_role";


--
-- Name: TABLE "guest_customers"; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE "public"."guest_customers" TO "anon";
GRANT ALL ON TABLE "public"."guest_customers" TO "authenticated";
GRANT ALL ON TABLE "public"."guest_customers" TO "service_role";


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
-- Name: TABLE "notifications"; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE "public"."notifications" TO "anon";
GRANT ALL ON TABLE "public"."notifications" TO "authenticated";
GRANT ALL ON TABLE "public"."notifications" TO "service_role";


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
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "authenticated";
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
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "authenticated";
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
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "authenticated";
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

\unrestrict TtFFXOux5TxedzkAASB8ayF6wpMvPfR2Rvt8eFyAuw2MC75rim6iiJ6Fhil76Bw
