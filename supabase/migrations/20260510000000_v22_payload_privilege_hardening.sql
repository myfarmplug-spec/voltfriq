-- VoltFriq v22: tighten future grants, keep job state writes behind RPCs,
-- and expose role-specific job payloads instead of broad client-side joins.

alter default privileges in schema public revoke all on tables from public, anon, authenticated;
alter default privileges in schema public revoke all on functions from public, anon, authenticated;
alter default privileges in schema public revoke all on sequences from public, anon, authenticated;
alter default privileges in schema public grant all on tables to service_role;
alter default privileges in schema public grant all on functions to service_role;
alter default privileges in schema public grant all on sequences to service_role;

do $$
begin
  execute 'alter default privileges for role postgres in schema public revoke all on tables from public, anon, authenticated';
  execute 'alter default privileges for role postgres in schema public revoke all on functions from public, anon, authenticated';
  execute 'alter default privileges for role postgres in schema public revoke all on sequences from public, anon, authenticated';
  execute 'alter default privileges for role postgres in schema public grant all on tables to service_role';
  execute 'alter default privileges for role postgres in schema public grant all on functions to service_role';
  execute 'alter default privileges for role postgres in schema public grant all on sequences to service_role';
exception
  when insufficient_privilege then
    raise notice 'Supabase denied changing default privileges for role postgres; active migration-role defaults were still locked down.';
end
$$;

do $$
begin
  execute 'alter default privileges for role supabase_admin in schema public revoke all on tables from public, anon, authenticated';
  execute 'alter default privileges for role supabase_admin in schema public revoke all on functions from public, anon, authenticated';
  execute 'alter default privileges for role supabase_admin in schema public revoke all on sequences from public, anon, authenticated';
  execute 'alter default privileges for role supabase_admin in schema public grant all on tables to service_role';
  execute 'alter default privileges for role supabase_admin in schema public grant all on functions to service_role';
  execute 'alter default privileges for role supabase_admin in schema public grant all on sequences to service_role';
exception
  when insufficient_privilege then
    raise notice 'Supabase denied changing default privileges for reserved role supabase_admin; active migration-role defaults were still locked down.';
end
$$;

revoke all on table public.jobs from anon, authenticated;
grant select on table public.jobs to authenticated;
grant all on table public.jobs to service_role;

create or replace function public.job_payload_for_role(
  p_job public.jobs,
  p_role text
) returns jsonb
language sql
stable
security definer
set search_path = public
as $$
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

create or replace function public.customer_job_payload(p_job_id uuid default null)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
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

create or replace function public.electrician_job_payload(p_job_id uuid default null)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
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

create or replace function public.admin_job_payload(p_job_id uuid default null)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
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

revoke execute on all functions in schema public from public, anon, authenticated;

do $$
declare
  rpc_name text;
  rpc_signature regprocedure;
  anon_rpcs text[] := array[
    'create_guest_customer_job',
    'create_guest_dispute',
    'get_public_job_events',
    'get_guest_job',
    'issue_guest_action_token',
    'request_guest_otp',
    'submit_guest_payment_proof',
    'update_guest_job_status',
    'verify_guest_otp'
  ];
  authenticated_rpcs text[] := array[
    'admin_job_payload',
    'admin_operational_queues',
    'admin_operational_summary',
    'admin_reconcile_job_state',
    'admin_resolve_operational_alert',
    'admin_retry_dispatch_job',
    'admin_set_electrician_status',
    'admin_set_electrician_watchlist',
    'create_customer_job',
    'create_dispute',
    'create_guest_customer_job',
    'create_guest_dispute',
    'current_customer_id',
    'current_electrician_id',
    'customer_job_payload',
    'dispatch_job',
    'electrician_accept_job',
    'electrician_job_payload',
    'electrician_reject_job',
    'ensure_app_account_for_current_user',
    'ensure_profile_for_current_user',
    'find_matching_electricians',
    'get_admin_job_events',
    'get_guest_job',
    'get_public_job_events',
    'is_admin',
    'issue_guest_action_token',
    'link_referral_code',
    'request_guest_otp',
    'resolve_dispute',
    'resolve_electrician_appeal',
    'set_job_status',
    'submit_customer_review',
    'submit_electrician_appeal',
    'submit_guest_payment_proof',
    'submit_job_quote',
    'submit_payment_proof',
    'submit_rating',
    'update_guest_job_status',
    'verify_guest_otp',
    'verify_job_payment'
  ];
begin
  for rpc_signature in
    select p.oid::regprocedure
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public'
  loop
    execute format('grant execute on function %s to service_role', rpc_signature);
  end loop;

  foreach rpc_name in array anon_rpcs loop
    for rpc_signature in
      select p.oid::regprocedure
      from pg_proc p
      join pg_namespace n on n.oid = p.pronamespace
      where n.nspname = 'public'
        and p.proname = rpc_name
    loop
      execute format('grant execute on function %s to anon', rpc_signature);
    end loop;
  end loop;

  foreach rpc_name in array authenticated_rpcs loop
    for rpc_signature in
      select p.oid::regprocedure
      from pg_proc p
      join pg_namespace n on n.oid = p.pronamespace
      where n.nspname = 'public'
        and p.proname = rpc_name
    loop
      execute format('grant execute on function %s to authenticated', rpc_signature);
    end loop;
  end loop;
end;
$$;

revoke all on function public.job_payload_for_role(public.jobs, text) from public, anon, authenticated;
grant execute on function public.job_payload_for_role(public.jobs, text) to service_role;
