-- Keep admin order lists responsive by using a lightweight payload for list reads.
-- Single-job admin reads still use job_payload_for_role() so detail views keep full history.

create index if not exists jobs_created_at_desc_idx
  on public.jobs (created_at desc);

create index if not exists job_photos_job_created_desc_idx
  on public.job_photos (job_id, created_at desc);

create index if not exists job_quotes_job_created_desc_idx
  on public.job_quotes (job_id, created_at desc);

create index if not exists quote_items_quote_created_idx
  on public.quote_items (quote_id, created_at);

create index if not exists job_payments_job_created_desc_idx
  on public.job_payments (job_id, created_at desc);

create index if not exists job_timeline_job_created_desc_idx
  on public.job_timeline (job_id, created_at desc);

create index if not exists ratings_job_created_desc_idx
  on public.ratings (job_id, created_at desc);

create index if not exists job_events_job_created_desc_idx
  on public.job_events (job_id, created_at desc);

create or replace function public.admin_job_payload(p_job_id uuid default null)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  job_row public.jobs;
begin
  if not public.is_admin() then
    raise exception 'Admin access required';
  end if;

  if p_job_id is not null then
    select * into job_row
    from public.jobs
    where id = p_job_id;

    if not found then
      raise exception 'Job not found';
    end if;

    return public.job_payload_for_role(job_row, 'admin');
  end if;

  return coalesce((
    select jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
      'id', j.id,
      'ticket', j.ticket,
      'customer_id', j.customer_id,
      'guest_customer_id', j.guest_customer_id,
      'assigned_electrician_id', j.assigned_electrician_id,
      'service_area', j.service_area,
      'location_label', j.location_label,
      'latitude', j.latitude,
      'longitude', j.longitude,
      'issue_category', j.issue_category,
      'urgency', j.urgency,
      'customer_note', j.customer_note,
      'requires_assessment', j.requires_assessment,
      'material_handling', j.material_handling,
      'status', j.status,
      'state_version', j.state_version,
      'candidate_queue', j.candidate_queue,
      'attempted_electrician_ids', j.attempted_electrician_ids,
      'dispatch_attempts', j.dispatch_attempts,
      'last_dispatch_at', j.last_dispatch_at,
      'dispatch_priority_score', j.dispatch_priority_score,
      'dispatch_priority_reason', j.dispatch_priority_reason,
      'assignment_expires_at', j.assignment_expires_at,
      'accepted_at', j.accepted_at,
      'customer_confirmed_at', j.customer_confirmed_at,
      'electrician_completed_at', j.electrician_completed_at,
      'payout_released_at', j.payout_released_at,
      'created_at', j.created_at,
      'updated_at', j.updated_at,
      'guest_dispatch_verified_at', j.guest_dispatch_verified_at,
      'customer', customer_payload.data,
      'guest_customer', guest_payload.data,
      'assigned_electrician', electrician_payload.data,
      'job_photos', coalesce(photo_payload.data, '[]'::jsonb),
      'job_quotes', coalesce(quote_payload.data, '[]'::jsonb),
      'job_payments', coalesce(payment_payload.data, '[]'::jsonb),
      'progress_timeline', coalesce(timeline_payload.data, '[]'::jsonb),
      'job_events', coalesce(event_payload.data, '[]'::jsonb),
      'ratings', coalesce(rating_payload.data, '[]'::jsonb)
    )) order by j.created_at desc)
    from public.jobs j
    left join lateral (
      select jsonb_strip_nulls(jsonb_build_object(
        'id', c.id,
        'profile_id', c.profile_id,
        'primary_service_area', c.primary_service_area,
        'location_label', c.location_label,
        'phone', coalesce(c.phone, p.phone),
        'average_behavior_rating', c.average_behavior_rating,
        'total_behavior_ratings', c.total_behavior_ratings,
        'completed_requests', c.completed_requests,
        'cancellation_count', c.cancellation_count,
        'no_show_reports', c.no_show_reports,
        'dispute_count', c.dispute_count,
        'payment_issue_count', c.payment_issue_count,
        'trust_status', c.trust_status,
        'trust_notes', c.trust_notes,
        'profile', jsonb_strip_nulls(jsonb_build_object(
          'full_name', p.full_name,
          'phone', coalesce(p.phone, c.phone)
        ))
      )) as data
      from public.customers c
      left join public.profiles p on p.id = c.profile_id
      where c.id = j.customer_id
    ) customer_payload on true
    left join lateral (
      select jsonb_build_object(
        'id', g.id,
        'phone', g.phone,
        'location_label', g.location_label,
        'created_at', g.created_at
      ) as data
      from public.guest_customers g
      where g.id = j.guest_customer_id
    ) guest_payload on true
    left join lateral (
      select jsonb_strip_nulls(jsonb_build_object(
        'id', e.id,
        'profile_id', e.profile_id,
        'display_name', coalesce(p.full_name, 'VoltFriq'),
        'name', coalesce(p.full_name, 'VoltFriq'),
        'avatar_url', p.avatar_url,
        'status', e.status,
        'years_experience', e.years_experience,
        'service_areas', e.service_areas,
        'location_label', e.location_label,
        'latitude', e.latitude,
        'longitude', e.longitude,
        'average_rating', e.average_rating,
        'total_ratings', e.total_ratings,
        'completed_jobs', e.completed_jobs,
        'availability_status', e.availability_status,
        'response_rate', e.response_rate,
        'level_badge', e.level_badge,
        'watchlist', e.watchlist,
        'watchlist_reason', e.watchlist_reason,
        'negative_rating_count', e.negative_rating_count,
        'suspended_reason', e.suspended_reason,
        'acceptance_score', e.acceptance_score,
        'response_score', e.response_score,
        'completion_score', e.completion_score,
        'dispute_score', e.dispute_score,
        'reliability_score', e.reliability_score,
        'tier', e.tier,
        'profile', jsonb_strip_nulls(jsonb_build_object(
          'full_name', p.full_name,
          'phone', p.phone,
          'avatar_url', p.avatar_url
        )),
        'electrician_skills', coalesce((
          select jsonb_agg(jsonb_build_object('category', s.category) order by s.category)
          from public.electrician_skills s
          where s.electrician_id = e.id
        ), '[]'::jsonb)
      )) as data
      from public.electricians e
      left join public.profiles p on p.id = e.profile_id
      where e.id = j.assigned_electrician_id
    ) electrician_payload on true
    left join lateral (
      select coalesce(jsonb_agg(jsonb_build_object(
        'id', ph.id,
        'job_id', ph.job_id,
        'file_path', ph.file_path,
        'created_at', ph.created_at
      ) order by ph.created_at desc), '[]'::jsonb) as data
      from (
        select ph.id, ph.job_id, ph.file_path, ph.created_at
        from public.job_photos ph
        where ph.job_id = j.id
        order by ph.created_at desc
        limit 6
      ) ph
    ) photo_payload on true
    left join lateral (
      select coalesce(jsonb_agg(jsonb_build_object(
        'id', q.id,
        'job_id', q.job_id,
        'electrician_id', q.electrician_id,
        'findings', q.findings,
        'measurements', q.measurements,
        'labor_total', q.labor_total,
        'material_total', q.material_total,
        'grand_total', q.grand_total,
        'created_at', q.created_at,
        'quote_items', coalesce((
          select jsonb_agg(jsonb_build_object(
            'id', qi.id,
            'quote_id', qi.quote_id,
            'item_type', qi.item_type,
            'description', qi.description,
            'quantity', qi.quantity,
            'unit_price', qi.unit_price,
            'line_total', qi.line_total,
            'created_at', qi.created_at
          ) order by qi.created_at)
          from public.quote_items qi
          where qi.quote_id = q.id
        ), '[]'::jsonb)
      ) order by q.created_at), '[]'::jsonb) as data
      from (
        select q.id, q.job_id, q.electrician_id, q.findings, q.measurements,
               q.labor_total, q.material_total, q.grand_total, q.created_at
        from public.job_quotes q
        where q.job_id = j.id
        order by q.created_at desc
        limit 1
      ) q
    ) quote_payload on true
    left join lateral (
      select coalesce(jsonb_agg(jsonb_build_object(
        'id', pay.id,
        'job_id', pay.job_id,
        'submitted_by', pay.submitted_by,
        'payment_type', pay.payment_type,
        'amount', pay.amount,
        'proof_path', pay.proof_path,
        'reference', pay.reference,
        'status', pay.status,
        'admin_note', pay.admin_note,
        'verified_by', pay.verified_by,
        'verified_at', pay.verified_at,
        'created_at', pay.created_at,
        'guest_customer_id', pay.guest_customer_id
      ) order by pay.created_at desc), '[]'::jsonb) as data
      from (
        select pay.id, pay.job_id, pay.submitted_by, pay.payment_type, pay.amount,
               pay.proof_path, pay.reference, pay.status, pay.admin_note,
               pay.verified_by, pay.verified_at, pay.created_at, pay.guest_customer_id
        from public.job_payments pay
        where pay.job_id = j.id
        order by pay.created_at desc
        limit 3
      ) pay
    ) payment_payload on true
    left join lateral (
      select coalesce(jsonb_agg(jsonb_build_object(
        'id', e.id,
        'job_id', e.job_id,
        'event_type', e.event_type,
        'public_message', public.public_message_for_job_event(e.event_type, coalesce(e.projected_status, j.status), e.public_message),
        'metadata', e.metadata,
        'created_at', e.created_at
      ) order by e.created_at), '[]'::jsonb) as data
      from (
        select e.id, e.job_id, e.event_type, e.projected_status, e.public_message, e.metadata, e.created_at
        from public.job_events e
        where e.job_id = j.id
          and nullif(btrim(coalesce(e.public_message, '')), '') is not null
        order by e.created_at desc
        limit 25
      ) e
    ) timeline_payload on true
    left join lateral (
      select coalesce(jsonb_agg(jsonb_build_object(
        'id', e.id,
        'job_id', e.job_id,
        'event_type', e.event_type,
        'actor_role', e.actor_role,
        'actor_id', e.actor_id,
        'request_id', e.request_id,
        'event_version', e.event_version,
        'transition_id', e.transition_id,
        'public_message', public.public_message_for_job_event(e.event_type, coalesce(e.projected_status, j.status), e.public_message),
        'internal_note', e.internal_note,
        'metadata', e.metadata,
        'created_at', e.created_at
      ) order by e.created_at), '[]'::jsonb) as data
      from (
        select e.id, e.job_id, e.event_type, e.actor_role, e.actor_id, e.request_id,
               e.event_version, e.transition_id, e.projected_status, e.public_message,
               e.internal_note, e.metadata, e.created_at
        from public.job_events e
        where e.job_id = j.id
        order by e.created_at desc
        limit 25
      ) e
    ) event_payload on true
    left join lateral (
      select coalesce(jsonb_agg(jsonb_build_object(
        'id', r.id,
        'job_id', r.job_id,
        'customer_id', r.customer_id,
        'electrician_id', r.electrician_id,
        'score', r.score,
        'comment', r.comment,
        'review_direction', r.review_direction,
        'behavior_tags', r.behavior_tags,
        'created_at', r.created_at
      ) order by r.created_at), '[]'::jsonb) as data
      from public.ratings r
      where r.job_id = j.id
    ) rating_payload on true
  ), '[]'::jsonb);
end;
$$;

revoke all on function public.admin_job_payload(uuid) from public, anon;
grant execute on function public.admin_job_payload(uuid) to authenticated, service_role;
