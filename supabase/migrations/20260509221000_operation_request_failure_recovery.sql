-- Keep operation request failure handling from masking the original automation error.

create or replace function public.complete_operation_request(
  p_request_id text,
  p_status text,
  p_response_payload jsonb default null,
  p_error_message text default null
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  clean_request_id text := public.sanitize_request_id(p_request_id);
  request_row public.operation_requests;
begin
  if auth.role() <> 'service_role' then
    raise exception 'Service role required';
  end if;

  if p_status not in ('completed', 'failed') then
    raise exception 'Unsupported operation request status';
  end if;

  update public.operation_requests
  set status = p_status,
      response_payload = p_response_payload,
      error_message = p_error_message,
      updated_at = now(),
      completed_at = case when p_status = 'completed' then now() else completed_at end
  where request_id = clean_request_id
  returning * into request_row;

  if not found then
    return jsonb_build_object(
      'request_id', clean_request_id,
      'status', p_status,
      'missing', true,
      'response_payload', p_response_payload,
      'error_message', p_error_message
    );
  end if;

  return jsonb_build_object(
    'request_id', request_row.request_id,
    'status', request_row.status,
    'response_payload', request_row.response_payload
  );
end;
$$;

revoke all on function public.complete_operation_request(text,text,jsonb,text) from public, anon, authenticated;
grant execute on function public.complete_operation_request(text,text,jsonb,text) to service_role;

select pg_notify('pgrst', 'reload schema');
