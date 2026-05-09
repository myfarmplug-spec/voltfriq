-- VoltFriq v22 final hardening: reassert future privilege defaults and
-- keep RPC exposure explicit after operational-intelligence migrations.

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
    raise notice 'Could not change postgres default privileges from this migration role.';
end
$$;

do $$
begin
  execute 'alter default privileges for role supabase_admin in schema public revoke all on tables from anon';
  execute 'alter default privileges for role supabase_admin in schema public revoke all on tables from authenticated';
  execute 'alter default privileges for role supabase_admin in schema public revoke all on functions from anon';
  execute 'alter default privileges for role supabase_admin in schema public revoke all on functions from authenticated';
  execute 'alter default privileges for role supabase_admin in schema public revoke all on sequences from anon';
  execute 'alter default privileges for role supabase_admin in schema public revoke all on sequences from authenticated';
  execute 'alter default privileges for role supabase_admin in schema public grant all on tables to service_role';
  execute 'alter default privileges for role supabase_admin in schema public grant all on functions to service_role';
  execute 'alter default privileges for role supabase_admin in schema public grant all on sequences to service_role';
exception
  when insufficient_privilege then
    raise notice 'Supabase reserved role supabase_admin rejected default-privilege edits; current public RPC grants are still re-applied below.';
end
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

revoke all on table public.jobs from anon, authenticated;
grant select on table public.jobs to authenticated;
grant all on table public.jobs to service_role;

revoke all on function public.job_payload_for_role(public.jobs, text) from public, anon, authenticated;
grant execute on function public.job_payload_for_role(public.jobs, text) to service_role;
