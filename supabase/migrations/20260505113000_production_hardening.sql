create or replace function public.dispatch_job(p_job_id uuid, p_manual_electrician_id uuid default null)
returns public.jobs
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  target_electrician uuid;
  candidate_list uuid[];
  remaining_candidates uuid[];
  customer_profile uuid;
  assigned_profile uuid;
  admin_profile uuid;
  job_row public.jobs;
begin
  if not (public.is_admin() or auth.role() = 'service_role') then
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
      select array_agg(
        electrician_id
        order by
          (distance_km + case when watchlist then 8 else 0 end) asc,
          average_rating desc nulls last,
          completed_jobs desc,
          level_rank desc,
          average_response_seconds asc nulls last,
          coalesce(last_assigned_at, to_timestamp(0)) asc
      )
      into candidate_list
      from public.find_matching_electricians(
        job_row.service_area,
        job_row.issue_category,
        job_row.latitude,
        job_row.longitude,
        10
      )
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
      perform public.create_notification(
        admin_profile,
        p_job_id,
        'job_stuck',
        'Manual assignment required',
        'No approved available VoltFriq accepted this job. Admin follow-up is needed.',
        '{}'::jsonb
      );
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
    jsonb_build_object('job_id', p_job_id)
  );
  return job_row;
end;
$$;

revoke all on function public.dispatch_job(uuid, uuid) from public;
revoke all on function public.dispatch_job(uuid, uuid) from anon;
grant execute on function public.dispatch_job(uuid, uuid) to authenticated;
grant execute on function public.dispatch_job(uuid, uuid) to service_role;

create or replace function public.set_job_status(
  p_job_id uuid,
  p_next_status public.job_status,
  p_note text default null,
  p_metadata jsonb default '{}'::jsonb
)
returns public.jobs
language plpgsql
security definer
set search_path to 'public'
as $$
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
      customer_confirmed_at = case
        when p_next_status = 'customer_confirmed' then coalesce(customer_confirmed_at, now())
        else customer_confirmed_at
      end,
      electrician_completed_at = case
        when p_next_status = 'electrician_completed' then coalesce(electrician_completed_at, now())
        else electrician_completed_at
      end,
      payout_released_at = case
        when p_next_status = 'payout_complete' then coalesce(payout_released_at, now())
        else payout_released_at
      end
  where id = p_job_id
  returning * into job_row;

  insert into public.job_timeline (job_id, status, note, actor_profile_id, metadata)
  values (p_job_id, p_next_status, p_note, auth.uid(), actor_metadata);

  return job_row;
end;
$$;

create or replace function public.submit_guest_payment_proof(
  p_job_id uuid,
  p_access_token text,
  p_payment_type public.payment_type,
  p_amount numeric,
  p_reference text,
  p_proof_path text
)
returns public.job_payments
language plpgsql
security definer
set search_path to 'public'
as $$
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

  insert into public.job_payments (
    job_id,
    guest_customer_id,
    submitted_by,
    payment_type,
    amount,
    proof_path,
    reference
  )
  values (
    p_job_id,
    job_row.guest_customer_id,
    null,
    p_payment_type,
    coalesce(p_amount, 0),
    p_proof_path,
    p_reference
  )
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

create or replace function public.submit_payment_proof(
  p_job_id uuid,
  p_payment_type public.payment_type,
  p_amount numeric,
  p_reference text,
  p_proof_path text
)
returns public.job_payments
language plpgsql
security definer
set search_path to 'public'
as $$
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

create or replace function public.update_guest_job_status(
  p_job_id uuid,
  p_access_token text,
  p_next_status public.job_status,
  p_note text default null,
  p_metadata jsonb default '{}'::jsonb
)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $$
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
      customer_confirmed_at = case
        when p_next_status = 'customer_confirmed' then coalesce(customer_confirmed_at, now())
        else customer_confirmed_at
      end
  where id = p_job_id;

  insert into public.job_timeline (job_id, status, note, actor_profile_id, metadata)
  values (p_job_id, p_next_status, p_note, null, coalesce(p_metadata, '{}'::jsonb));

  return public.guest_job_payload(p_job_id, p_access_token);
end;
$$;
