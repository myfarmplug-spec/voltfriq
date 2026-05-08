-- Backfill active assignment tokens so in-flight pre-token jobs remain actionable.

do $$
declare
  item record;
  assignment_event public.job_events;
  token_value text;
begin
  for item in
    select id, assigned_electrician_id, assignment_expires_at
    from public.jobs
    where status = 'assigned'
      and assigned_electrician_id is not null
      and current_assignment_event_id is null
  loop
    select *
    into assignment_event
    from public.job_events
    where job_id = item.id
      and event_type = 'ELECTRICIAN_ASSIGNED'
      and (
        metadata ->> 'electrician_id' = item.assigned_electrician_id::text
        or metadata ->> 'electrician_id' is null
      )
    order by created_at desc, id desc
    limit 1;

    if assignment_event.id is not null then
      token_value := coalesce(nullif(assignment_event.metadata ->> 'assignment_token', ''), replace(gen_random_uuid()::text, '-', '') || replace(gen_random_uuid()::text, '-', ''));

      update public.job_events
      set metadata = coalesce(metadata, '{}'::jsonb) || jsonb_build_object(
        'electrician_id', item.assigned_electrician_id,
        'assignment_token', token_value,
        'assignment_expires_at', item.assignment_expires_at,
        'source', coalesce(nullif(metadata ->> 'source', ''), 'assignment_backfill')
      )
      where id = assignment_event.id;

      update public.jobs
      set current_assignment_event_id = assignment_event.id,
          current_assignment_token = token_value
      where id = item.id;
    end if;
  end loop;
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
    and (
      current_assignment_event_id = assignment_event.id
      or current_assignment_event_id is null
    )
  returning * into job_row;

  if job_row.id is null then
    raise exception 'This assignment is no longer available.';
  end if;

  perform public.refresh_electrician_performance_snapshot(electrician_row.id);
  select * into job_row from public.dispatch_job_internal(p_job_id, null);
  return job_row;
end;
$$;

revoke all on function public.electrician_reject_job(uuid) from public, anon, authenticated, service_role;
grant execute on function public.electrician_reject_job(uuid) to authenticated, service_role;

notify pgrst, 'reload schema';
