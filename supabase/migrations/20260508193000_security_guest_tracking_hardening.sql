-- Final security hardening:
-- - keep dispatch processing behind the service-role cron endpoint only
-- - return a public, minimal guest tracking payload

revoke all on function public.process_dispatch_queue() from anon;
revoke all on function public.process_dispatch_queue() from authenticated;
grant execute on function public.process_dispatch_queue() to service_role;

create or replace function public.guest_public_timeline_note(p_status public.job_status)
returns text
language sql
stable
set search_path = public
as $$
  select case p_status::text
    when 'requested' then 'Booking confirmed.'
    when 'matching' then 'Finding the best VoltFriq near you.'
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
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  payload jsonb;
begin
  select jsonb_strip_nulls(jsonb_build_object(
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
      'average_rating', e.average_rating,
      'total_ratings', e.total_ratings,
      'completed_jobs', e.completed_jobs,
      'level_badge', e.level_badge,
      'service_areas', e.service_areas
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
        'id', q.id,
        'findings', q.findings,
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
        'amount', payment.amount,
        'status', payment.status,
        'created_at', payment.created_at
      ) order by payment.created_at)
      from public.job_payments payment
      where payment.job_id = j.id
    ), '[]'::jsonb),
    'ratings', '[]'::jsonb
  ))
  into payload
  from public.jobs j
  left join public.electricians e on e.id = j.assigned_electrician_id
  left join public.profiles p on p.id = e.profile_id
  where j.id = p_job_id
    and j.customer_access_token = p_access_token
    and j.guest_customer_id is not null;

  if payload is null then
    raise exception 'Guest job not found';
  end if;

  return payload;
end;
$$;

create or replace function public.get_guest_job(
  p_job_id uuid,
  p_access_token text
)
returns jsonb
language sql
security definer
set search_path = public
as $$
  select public.guest_job_payload(p_job_id, p_access_token);
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
  p_photo_paths text[] default '{}'
)
returns jsonb
language plpgsql
security definer
set search_path = public
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
    'job_id', created_job.id,
    'job', public.guest_job_payload(created_job.id, access_token)
  );
end;
$$;
