-- Final security cleanup:
-- - remove unsafe future default grants
-- - add short-lived guest action tokens for sensitive guest actions
-- - keep internal/service-role RPCs locked down

alter default privileges in schema public revoke all on functions from public, anon, authenticated;
alter default privileges in schema public revoke all on tables from public, anon, authenticated;
alter default privileges in schema public revoke all on sequences from public, anon, authenticated;
alter default privileges in schema public grant all on functions to service_role;
alter default privileges in schema public grant all on tables to service_role;
alter default privileges in schema public grant all on sequences to service_role;

alter default privileges for role postgres in schema public revoke all on functions from public, anon, authenticated;
alter default privileges for role postgres in schema public revoke all on tables from public, anon, authenticated;
alter default privileges for role postgres in schema public revoke all on sequences from public, anon, authenticated;
alter default privileges for role postgres in schema public grant all on functions to service_role;
alter default privileges for role postgres in schema public grant all on tables to service_role;
alter default privileges for role postgres in schema public grant all on sequences to service_role;

create table if not exists public.guest_action_tokens (
  id uuid primary key default gen_random_uuid(),
  job_id uuid not null references public.jobs(id) on delete cascade,
  action_type text not null check (action_type in ('cancel_job', 'payment_proof', 'dispute', 'customer_confirmed')),
  token_hash text not null unique,
  expires_at timestamptz not null default (now() + interval '10 minutes'),
  consumed_at timestamptz,
  created_at timestamptz not null default now()
);

create index if not exists guest_action_tokens_job_action_idx
  on public.guest_action_tokens(job_id, action_type, expires_at desc);

alter table public.guest_action_tokens enable row level security;

drop policy if exists "guest action tokens service role only" on public.guest_action_tokens;
create policy "guest action tokens service role only"
  on public.guest_action_tokens
  using (auth.role() = 'service_role')
  with check (auth.role() = 'service_role');

create or replace function public.issue_guest_action_token(
  p_job_id uuid,
  p_access_token text,
  p_action_type text,
  p_phone_confirmation text
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

  select phone into guest_phone
  from public.guest_customers
  where id = job_row.guest_customer_id;

  expected_last4 := right(regexp_replace(coalesce(guest_phone, ''), '\D', '', 'g'), 4);
  provided_last4 := right(regexp_replace(coalesce(p_phone_confirmation, ''), '\D', '', 'g'), 4);

  if expected_last4 = '' or expected_last4 <> provided_last4 then
    raise exception 'Confirm the phone number used for this booking.';
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

create or replace function public.consume_guest_action_token(
  p_job_id uuid,
  p_action_type text,
  p_action_token text
) returns void
language plpgsql
security definer
set search_path = public
as $$
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

drop function if exists public.submit_guest_payment_proof(uuid,text,public.payment_type,numeric,text,text);
drop function if exists public.submit_guest_payment_proof(uuid,text,public.payment_type,numeric,text,text,text);

create or replace function public.submit_guest_payment_proof(
  p_job_id uuid,
  p_access_token text,
  p_payment_type public.payment_type,
  p_amount numeric,
  p_reference text,
  p_proof_path text,
  p_phone_confirmation text default null,
  p_action_token text default null
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

drop function if exists public.update_guest_job_status(uuid,text,public.job_status,text,jsonb);

create or replace function public.update_guest_job_status(
  p_job_id uuid,
  p_access_token text,
  p_next_status public.job_status,
  p_note text default null,
  p_metadata jsonb default '{}'::jsonb,
  p_action_token text default null
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  job_row public.jobs;
  safe_metadata jsonb;
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

  if p_next_status = 'cancelled' then
    perform public.consume_guest_action_token(p_job_id, 'cancel_job', p_action_token);
  elsif p_next_status = 'customer_confirmed' then
    perform public.consume_guest_action_token(p_job_id, 'customer_confirmed', p_action_token);
  end if;

  safe_metadata := coalesce(p_metadata, '{}'::jsonb) - 'phone_confirmation';

  update public.jobs
  set status = p_next_status,
      customer_confirmed_at = case when p_next_status = 'customer_confirmed' then coalesce(customer_confirmed_at, now()) else customer_confirmed_at end
  where id = p_job_id;

  insert into public.job_timeline (job_id, status, note, actor_profile_id, metadata)
  values (p_job_id, p_next_status, p_note, null, safe_metadata);

  return public.guest_job_payload(p_job_id, p_access_token);
end;
$$;

drop function if exists public.create_guest_dispute(uuid,text,text,text,text);

create or replace function public.create_guest_dispute(
  p_job_id uuid,
  p_access_token text,
  p_issue_type text,
  p_details text default null,
  p_phone_confirmation text default null,
  p_action_token text default null
) returns public.disputes
language plpgsql
security definer
set search_path = public
as $$
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

revoke all on table public.guest_action_tokens from public, anon, authenticated;
grant all on table public.guest_action_tokens to service_role;

revoke all on function public.issue_guest_action_token(uuid,text,text,text) from public, anon, authenticated, service_role;
grant execute on function public.issue_guest_action_token(uuid,text,text,text) to anon, authenticated, service_role;

revoke all on function public.consume_guest_action_token(uuid,text,text) from public, anon, authenticated, service_role;
grant execute on function public.consume_guest_action_token(uuid,text,text) to service_role;

revoke all on function public.submit_guest_payment_proof(uuid,text,public.payment_type,numeric,text,text,text,text) from public, anon, authenticated, service_role;
grant execute on function public.submit_guest_payment_proof(uuid,text,public.payment_type,numeric,text,text,text,text) to anon, authenticated, service_role;

revoke all on function public.update_guest_job_status(uuid,text,public.job_status,text,jsonb,text) from public, anon, authenticated, service_role;
grant execute on function public.update_guest_job_status(uuid,text,public.job_status,text,jsonb,text) to anon, authenticated, service_role;

revoke all on function public.create_guest_dispute(uuid,text,text,text,text,text) from public, anon, authenticated, service_role;
grant execute on function public.create_guest_dispute(uuid,text,text,text,text,text) to anon, authenticated, service_role;

revoke all on function public.process_dispatch_queue() from public, anon, authenticated;
grant execute on function public.process_dispatch_queue() to service_role;

revoke all on function public.append_job_timeline(uuid,public.job_status,text,uuid) from public, anon, authenticated;
grant execute on function public.append_job_timeline(uuid,public.job_status,text,uuid) to service_role;

revoke all on function public.create_notification(uuid,uuid,public.notification_event,text,text,jsonb) from public, anon, authenticated;
grant execute on function public.create_notification(uuid,uuid,public.notification_event,text,text,jsonb) to service_role;

revoke all on function public.guest_job_payload(uuid,text) from public, anon, authenticated;
grant execute on function public.guest_job_payload(uuid,text) to service_role;

notify pgrst, 'reload schema';
