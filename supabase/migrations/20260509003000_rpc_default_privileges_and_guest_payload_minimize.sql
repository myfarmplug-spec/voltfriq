-- Close the remaining static-audit gaps:
-- - future functions do not default-grant EXECUTE to anon/authenticated
-- - guest job-photo attachment is no longer an anon RPC
-- - guest tracking returns only public-safe summaries

create or replace function public.guest_public_timeline_note(p_status public.job_status)
returns text
language sql
stable
set search_path = public
as $$
  select case p_status::text
    when 'requested' then 'Booking confirmed.'
    when 'matching' then 'Finding a verified electrician near you.'
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

alter default privileges for role postgres in schema public revoke all on functions from public;
alter default privileges for role postgres in schema public revoke all on functions from anon;
alter default privileges for role postgres in schema public revoke all on functions from authenticated;

revoke all on all functions in schema public from public;
revoke all on all functions in schema public from anon;
revoke all on all functions in schema public from authenticated;
grant execute on all functions in schema public to service_role;

grant execute on function public.create_guest_customer_job(text,text,text,double precision,double precision,text,public.job_urgency,text,boolean,text,text[],text) to anon, authenticated;
grant execute on function public.get_guest_job(uuid,text) to anon, authenticated;
grant execute on function public.update_guest_job_status(uuid,text,public.job_status,text,jsonb) to anon, authenticated;
grant execute on function public.submit_guest_payment_proof(uuid,text,public.payment_type,numeric,text,text) to anon, authenticated;

grant execute on function public.admin_set_electrician_status(uuid,public.electrician_status,text) to authenticated;
grant execute on function public.admin_set_electrician_watchlist(uuid,boolean,text) to authenticated;
grant execute on function public.calculate_electrician_level(integer,numeric,integer,numeric,boolean) to authenticated;
grant execute on function public.create_customer_job(text,text,double precision,double precision,text,public.job_urgency,text,boolean,text,text[]) to authenticated;
grant execute on function public.create_dispute(uuid,text,text) to authenticated;
grant execute on function public.current_customer_id() to authenticated;
grant execute on function public.current_electrician_id() to authenticated;
grant execute on function public.dispatch_job(uuid,uuid) to authenticated;
grant execute on function public.electrician_accept_job(uuid) to authenticated;
grant execute on function public.electrician_level_rank(text) to authenticated;
grant execute on function public.electrician_reject_job(uuid) to authenticated;
grant execute on function public.ensure_app_account_for_current_user() to authenticated;
grant execute on function public.ensure_profile_for_current_user() to authenticated;
grant execute on function public.ensure_wallet_for_profile(uuid) to authenticated;
grant execute on function public.find_matching_electricians(text,text,double precision,double precision,integer) to authenticated;
grant execute on function public.is_admin() to authenticated;
grant execute on function public.link_referral_code(text) to authenticated;
grant execute on function public.resolve_dispute(uuid,text,text,text) to authenticated;
grant execute on function public.resolve_electrician_appeal(uuid,boolean,text) to authenticated;
grant execute on function public.set_job_status(uuid,public.job_status,text,jsonb) to authenticated;
grant execute on function public.submit_customer_review(uuid,integer,text,text[]) to authenticated;
grant execute on function public.submit_electrician_appeal(text,text) to authenticated;
grant execute on function public.submit_job_quote(uuid,text,text,jsonb) to authenticated;
grant execute on function public.submit_payment_proof(uuid,public.payment_type,numeric,text,text) to authenticated;
grant execute on function public.submit_rating(uuid,integer,text,text[]) to authenticated;
grant execute on function public.verify_job_payment(uuid,boolean,text) to authenticated;

revoke all on function public.append_job_timeline(uuid,public.job_status,text,uuid) from public, anon, authenticated;
revoke all on function public.create_notification(uuid,uuid,public.notification_event,text,text,jsonb) from public, anon, authenticated;
revoke all on function public.attach_guest_job_photos(uuid,text,text[]) from public, anon, authenticated;

notify pgrst, 'reload schema';
