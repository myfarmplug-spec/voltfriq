-- Guest tracking payloads must include the job id so the browser can save
-- the access token and continue to tracking immediately after booking.

create or replace function public.guest_job_payload(
  p_job_id uuid,
  p_access_token text
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  payload jsonb;
begin
  select jsonb_strip_nulls(jsonb_build_object(
    'id', j.id,
    'ticket', j.ticket,
    'is_guest', true,
    'service_area', j.service_area,
    'location_label', j.location_label,
    'issue_category', j.issue_category,
    'urgency', j.urgency,
    'status', j.status,
    'created_at', j.created_at,
    'updated_at', j.updated_at,
    'assigned_electrician', case when e.id is null then null else jsonb_build_object(
      'profile', jsonb_build_object(
        'full_name', coalesce(nullif(p.full_name, ''), 'VoltFriq'),
        'avatar_url', p.avatar_url
      ),
      'average_rating', e.average_rating
    ) end,
    'job_timeline', coalesce((
      select jsonb_agg(jsonb_build_object(
        'status', timeline.status,
        'note', public.guest_public_timeline_note(timeline.status),
        'created_at', timeline.created_at
      ) order by timeline.created_at)
      from public.job_timeline timeline
      where timeline.job_id = j.id
    ), '[]'::jsonb),
    'job_quotes', coalesce((
      select jsonb_agg(jsonb_build_object(
        'labor_total', q.labor_total,
        'material_total', q.material_total,
        'grand_total', q.grand_total,
        'created_at', q.created_at
      ) order by q.created_at)
      from public.job_quotes q
      where q.job_id = j.id
    ), '[]'::jsonb),
    'job_payments', coalesce((
      select jsonb_agg(jsonb_build_object(
        'payment_type', payment.payment_type,
        'status', payment.status,
        'created_at', payment.created_at
      ) order by payment.created_at)
      from public.job_payments payment
      where payment.job_id = j.id
    ), '[]'::jsonb)
  ))
  into payload
  from public.jobs j
  left join public.electricians e on e.id = j.assigned_electrician_id
  left join public.profiles p on p.id = e.profile_id
  where j.id = p_job_id
    and j.customer_access_token = p_access_token;

  if payload is null then
    raise exception 'Guest job not found';
  end if;

  return payload;
end;
$$;

revoke all on function public.guest_job_payload(uuid,text) from public, anon, authenticated;
grant execute on function public.guest_job_payload(uuid,text) to service_role;

notify pgrst, 'reload schema';
