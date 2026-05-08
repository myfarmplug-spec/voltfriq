-- Fix replay counter writes so PL/pgSQL variables cannot be confused with table columns.

create or replace function public.replay_all_job_events(
  p_limit integer default 100,
  p_request_id text default null
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
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

revoke all on function public.replay_all_job_events(integer,text) from public, anon, authenticated;
grant execute on function public.replay_all_job_events(integer,text) to service_role;

select pg_notify('pgrst', 'reload schema');
