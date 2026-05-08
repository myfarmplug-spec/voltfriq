-- Final manual patch from the production audit:
-- - public guest tracking returns only safe summaries
-- - internal writer RPCs remain service-role only
-- - future public schema tables/functions/sequences do not default-grant to anon/authenticated

create or replace function public.guest_public_timeline_note(p_status public.job_status)
returns text
language sql
stable
set search_path = public
as $$
  select case p_status::text
    when 'requested' then 'Booking confirmed.'
    when 'matching' then 'Pairing you with a VoltFriq.'
    when 'assigned' then 'A verified VoltFriq has been assigned.'
    when 'accepted' then 'Your VoltFriq has accepted the booking.'
    when 'assessment_fee_pending' then 'Assessment payment is ready.'
    when 'assessment_payment_pending_verification' then 'Payment proof received for review.'
    when 'assessment_confirmed' then 'Assessment payment confirmed.'
    when 'en_route' then 'Your VoltFriq is on the way.'
    when 'on_site' then 'Your VoltFriq is on site.'
    when 'quoted' then 'Your quote is ready.'
    when 'quote_accepted' then 'Quote accepted.'
    when 'work_payment_pending_verification' then 'Work payment proof received for review.'
    when 'payment_confirmed' then 'Payment confirmed.'
    when 'work_in_progress' then 'Work is in progress.'
    when 'electrician_completed' then 'Work marked complete.'
    when 'customer_confirmed' then 'Completion confirmed.'
    when 'payout_pending' then 'Final processing is underway.'
    when 'payout_complete' then 'Job complete.'
    when 'rated' then 'Job complete.'
    when 'cancelled' then 'Booking cancelled.'
    else 'Status updated.'
  end;
$$;

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
    'status', j.status,
    'issue_category', j.issue_category,
    'urgency', j.urgency,
    'location_label', j.location_label,
    'created_at', j.created_at,
    'assigned_electrician', case when e.id is null then null else jsonb_build_object(
      'display_name', coalesce(nullif(p.full_name, ''), 'VoltFriq'),
      'avatar_url', p.avatar_url,
      'rating', e.average_rating
    ) end,
    'progress_timeline', coalesce((
      select jsonb_agg(jsonb_build_object(
        'status', timeline.status,
        'note', case
          when lower(coalesce(timeline.note, '')) like any (array[
            '%manual assignment required%',
            '%admin assignment%',
            '%admin manually assigned%',
            '%no electrician available%',
            '%dispatch failed%'
          ]) then 'VoltFriq support is helping route your request.'
          when timeline.status = 'matching' and timeline.created_at < now() - interval '10 minutes' then 'Still finding a verified VoltFriq near you.'
          else public.guest_public_timeline_note(timeline.status)
        end,
        'created_at', timeline.created_at
      ) order by timeline.created_at)
      from public.job_timeline timeline
      where timeline.job_id = j.id
    ), '[]'::jsonb),
    'quote_summary', (
      select jsonb_build_object(
        'total', q.grand_total,
        'created_at', q.created_at
      )
      from public.job_quotes q
      where q.job_id = j.id
      order by q.created_at desc
      limit 1
    ),
    'payment_status', (
      select payment.status
      from public.job_payments payment
      where payment.job_id = j.id
      order by payment.created_at desc
      limit 1
    )
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

alter default privileges for role postgres in schema public revoke all on functions from public, anon, authenticated;
alter default privileges for role postgres in schema public revoke all on tables from public, anon, authenticated;
alter default privileges for role postgres in schema public revoke all on sequences from public, anon, authenticated;
alter default privileges for role postgres in schema public grant all on functions to service_role;
alter default privileges for role postgres in schema public grant all on tables to service_role;
alter default privileges for role postgres in schema public grant all on sequences to service_role;

revoke all on function public.process_dispatch_queue() from public, anon, authenticated;
revoke all on function public.append_job_timeline(uuid,public.job_status,text,uuid) from public, anon, authenticated;
revoke all on function public.create_notification(uuid,uuid,public.notification_event,text,text,jsonb) from public, anon, authenticated;
grant execute on function public.process_dispatch_queue() to service_role;
grant execute on function public.append_job_timeline(uuid,public.job_status,text,uuid) to service_role;
grant execute on function public.create_notification(uuid,uuid,public.notification_event,text,text,jsonb) to service_role;

notify pgrst, 'reload schema';
