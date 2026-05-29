-- Make electrician intake repairable and give admins a dedicated manual assignment RPC.

create or replace function public.ensure_pending_electrician_for_profile()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.role = 'electrician' then
    insert into public.electricians (
      profile_id,
      status,
      onboarding_completed,
      years_experience,
      service_areas,
      availability_status
    )
    values (
      new.id,
      'pending'::public.electrician_status,
      false,
      0,
      '{}'::text[],
      'available'
    )
    on conflict (profile_id) do nothing;
  end if;

  return new;
end;
$$;

drop trigger if exists ensure_pending_electrician_for_profile_trigger on public.profiles;
create trigger ensure_pending_electrician_for_profile_trigger
after insert or update of role on public.profiles
for each row
execute function public.ensure_pending_electrician_for_profile();

insert into public.electricians (
  profile_id,
  status,
  onboarding_completed,
  years_experience,
  service_areas,
  availability_status
)
select
  p.id,
  'pending'::public.electrician_status,
  false,
  0,
  '{}'::text[],
  'available'
from public.profiles p
where p.role = 'electrician'
  and not exists (
    select 1
    from public.electricians e
    where e.profile_id = p.id
  );

create index if not exists profiles_role_id_idx
  on public.profiles(role, id);

create index if not exists electricians_profile_status_idx
  on public.electricians(profile_id, status);

create index if not exists jobs_admin_assignable_idx
  on public.jobs(status, updated_at desc)
  where status in ('requested', 'matching', 'assigned');

create index if not exists jobs_assigned_electrician_status_idx
  on public.jobs(assigned_electrician_id, status, assignment_expires_at)
  where assigned_electrician_id is not null;

create or replace function public.admin_assign_electrician_to_job(
  p_job_id uuid,
  p_electrician_id uuid,
  p_force boolean default true
) returns public.jobs
language plpgsql
security definer
set search_path = public
as $$
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

revoke all on function public.ensure_pending_electrician_for_profile() from public, anon, authenticated;
grant execute on function public.ensure_pending_electrician_for_profile() to service_role;

revoke all on function public.admin_assign_electrician_to_job(uuid, uuid, boolean) from public, anon, authenticated, service_role;
grant execute on function public.admin_assign_electrician_to_job(uuid, uuid, boolean) to authenticated, service_role;
