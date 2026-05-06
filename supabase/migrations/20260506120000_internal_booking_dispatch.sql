create or replace function public.dispatch_job_internal(p_job_id uuid, p_manual_electrician_id uuid default null)
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

revoke all on function public.dispatch_job_internal(uuid, uuid) from public;
revoke all on function public.dispatch_job_internal(uuid, uuid) from anon;
revoke all on function public.dispatch_job_internal(uuid, uuid) from authenticated;
grant execute on function public.dispatch_job_internal(uuid, uuid) to service_role;

create or replace function public.create_customer_job(
  p_service_area text,
  p_location_label text,
  p_latitude double precision,
  p_longitude double precision,
  p_issue_category text,
  p_urgency public.job_urgency,
  p_customer_note text,
  p_requires_assessment boolean,
  p_material_handling text,
  p_photo_paths text[] default '{}'::text[]
)
returns public.jobs
language plpgsql
security definer
set search_path to 'public'
as $$
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

  select * into created_job from public.dispatch_job_internal(created_job.id, null);
  return created_job;
end;
$$;

create or replace function public.create_guest_customer_job(
  p_phone text,
  p_service_area text,
  p_location_label text,
  p_latitude double precision,
  p_longitude double precision,
  p_issue_category text,
  p_urgency public.job_urgency,
  p_customer_note text,
  p_requires_assessment boolean,
  p_material_handling text,
  p_photo_paths text[] default '{}'::text[]
)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $$
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

  select * into created_job from public.dispatch_job_internal(created_job.id, null);

  return jsonb_build_object(
    'access_token', access_token,
    'job', public.guest_job_payload(created_job.id, access_token)
  );
end;
$$;

create or replace function public.electrician_reject_job(p_job_id uuid)
returns public.jobs
language plpgsql
security definer
set search_path to 'public'
as $$
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
  select * into job_row from public.dispatch_job_internal(p_job_id, null);
  return job_row;
end;
$$;

create or replace function public.process_dispatch_queue()
returns integer
language plpgsql
security definer
set search_path to 'public'
as $$
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
    perform public.dispatch_job_internal(expired_job.id, null);
    processed_count := processed_count + 1;
  end loop;

  for matching_job in
    select id
    from public.jobs
    where status = 'matching'
      and assigned_electrician_id is null
      and coalesce(array_length(candidate_queue, 1), 0) > 0
  loop
    perform public.dispatch_job_internal(matching_job.id, null);
    processed_count := processed_count + 1;
  end loop;

  return processed_count;
end;
$$;
