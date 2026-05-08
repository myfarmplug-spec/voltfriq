create or replace function public.dispatch_job_internal(p_job_id uuid, p_manual_electrician_id uuid default null)
returns public.jobs
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  job_row public.jobs;
  target_electrician uuid;
  candidate_list uuid[];
  remaining_candidates uuid[] := array[]::uuid[];
  customer_profile uuid;
  assigned_profile uuid;
  admin_profile uuid;
  actor_profile_id uuid;
begin
  select * into job_row from public.jobs where id = p_job_id for update;
  if not found then
    raise exception 'Job not found';
  end if;

  select c.profile_id into customer_profile
  from public.customers c
  where c.id = job_row.customer_id;

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

  select e.profile_id into assigned_profile
  from public.electricians e
  where e.id = target_electrician;

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
