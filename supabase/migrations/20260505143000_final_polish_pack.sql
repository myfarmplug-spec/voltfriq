create unique index if not exists job_payments_one_submitted_per_job_idx
on public.job_payments (job_id)
where status = 'submitted';

create or replace function public.electrician_accept_job(p_job_id uuid)
returns public.jobs
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  job_row public.jobs;
  electrician_row public.electricians;
  customer_profile uuid;
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
    raise exception 'Only assigned jobs can be accepted';
  end if;

  update public.jobs
  set status = case
        when job_row.requires_assessment then 'assessment_fee_pending'::job_status
        else 'accepted'::job_status
      end,
      accepted_at = now(),
      assignment_expires_at = null
  where id = p_job_id
  returning * into job_row;

  select c.profile_id into customer_profile from public.customers c where c.id = job_row.customer_id;
  perform public.append_job_timeline(p_job_id, job_row.status, 'VoltFriq accepted the booking.', auth.uid());
  perform public.create_notification(customer_profile, p_job_id, 'electrician_accepted', 'VoltFriq accepted', 'Your assigned VoltFriq accepted the booking.', '{}'::jsonb);
  return job_row;
end;
$$;

create or replace function public.submit_job_quote(
  p_job_id uuid,
  p_findings text,
  p_measurements text,
  p_items jsonb
)
returns public.job_quotes
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  electrician_row public.electricians;
  job_row public.jobs;
  quote_row public.job_quotes;
  item jsonb;
  labor_total_value numeric := 0;
  material_total_value numeric := 0;
  line_total numeric := 0;
  customer_profile uuid;
begin
  select * into electrician_row from public.electricians where profile_id = auth.uid();
  if not found then
    raise exception 'Electrician profile not found';
  end if;

  select * into job_row
  from public.jobs
  where id = p_job_id
  for update;

  if not found then
    raise exception 'Job not found';
  end if;

  if job_row.assigned_electrician_id is distinct from electrician_row.id then
    raise exception 'You can only quote jobs assigned to you';
  end if;

  if not (
    job_row.status = 'on_site'
    or (job_row.status = 'accepted' and not job_row.requires_assessment)
  ) then
    raise exception 'Quotes can only be submitted after arrival on site or after remote acceptance for non-assessment jobs';
  end if;

  insert into public.job_quotes (job_id, electrician_id, findings, measurements)
  values (p_job_id, electrician_row.id, p_findings, p_measurements)
  returning * into quote_row;

  for item in select * from jsonb_array_elements(coalesce(p_items, '[]'::jsonb))
  loop
    line_total := coalesce((item ->> 'quantity')::numeric, 1) * coalesce((item ->> 'unit_price')::numeric, 0);
    insert into public.quote_items (quote_id, item_type, description, quantity, unit_price, line_total)
    values (
      quote_row.id,
      coalesce(item ->> 'item_type', 'labor'),
      coalesce(item ->> 'description', 'Item'),
      coalesce((item ->> 'quantity')::numeric, 1),
      coalesce((item ->> 'unit_price')::numeric, 0),
      line_total
    );
    if coalesce(item ->> 'item_type', 'labor') = 'material' then
      material_total_value := material_total_value + line_total;
    else
      labor_total_value := labor_total_value + line_total;
    end if;
  end loop;

  update public.job_quotes
  set labor_total = labor_total_value,
      material_total = material_total_value,
      grand_total = labor_total_value + material_total_value
  where id = quote_row.id
  returning * into quote_row;

  update public.jobs
  set status = 'quoted',
      current_quote_id = quote_row.id
  where id = p_job_id;

  select c.profile_id into customer_profile
  from public.jobs j
  join public.customers c on c.id = j.customer_id
  where j.id = p_job_id;

  perform public.append_job_timeline(p_job_id, 'quoted', 'VoltFriq submitted a quote.', auth.uid());
  perform public.create_notification(customer_profile, p_job_id, 'quote_submitted', 'Quote ready', 'A new quote is ready for review.', jsonb_build_object('quote_id', quote_row.id));
  return quote_row;
end;
$$;

create or replace function public.submit_guest_payment_proof(
  p_job_id uuid,
  p_access_token text,
  p_payment_type public.payment_type,
  p_amount numeric,
  p_reference text,
  p_proof_path text
)
returns public.job_payments
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  job_row public.jobs;
  payment_row public.job_payments;
  next_status job_status;
begin
  select * into job_row
  from public.jobs
  where id = p_job_id
    and customer_access_token = p_access_token
    and guest_customer_id is not null
  for update;

  if not found then
    raise exception 'Guest job not found';
  end if;

  if job_row.status in ('electrician_completed', 'customer_confirmed', 'payout_pending', 'payout_complete', 'rated', 'cancelled') then
    raise exception 'Payment proof cannot be submitted after the job has moved past payment stages';
  end if;

  if exists (
    select 1 from public.job_payments
    where job_id = p_job_id
      and status = 'submitted'
  ) then
    raise exception 'A payment proof is already waiting for manual verification for this job';
  end if;

  if p_payment_type = 'assessment_fee' then
    if job_row.status <> 'assessment_fee_pending' then
      raise exception 'Assessment fee proof can only be submitted when the job is awaiting the assessment fee';
    end if;
    next_status := 'assessment_payment_pending_verification';
  elsif p_payment_type in ('quote_payment', 'material_payment') then
    if job_row.status <> 'quote_accepted' then
      raise exception 'Work payment proof can only be submitted after the quote is accepted';
    end if;
    next_status := 'work_payment_pending_verification';
  else
    raise exception 'Unsupported payment type for guest submission';
  end if;

  if exists (
    select 1
    from public.job_payments
    where job_id = p_job_id
      and payment_type = p_payment_type
      and status in ('submitted', 'verified')
  ) then
    raise exception 'Payment proof for this step has already been submitted';
  end if;

  insert into public.job_payments (
    job_id,
    guest_customer_id,
    submitted_by,
    payment_type,
    amount,
    proof_path,
    reference
  )
  values (
    p_job_id,
    job_row.guest_customer_id,
    null,
    p_payment_type,
    coalesce(p_amount, 0),
    p_proof_path,
    p_reference
  )
  returning * into payment_row;

  update public.jobs
  set status = next_status
  where id = p_job_id;

  insert into public.job_timeline (job_id, status, note, actor_profile_id, metadata)
  values (
    p_job_id,
    next_status,
    'Guest payment proof submitted for manual verification.',
    null,
    jsonb_build_object('payment_id', payment_row.id, 'payment_type', p_payment_type)
  );

  perform public.create_notification(
    (select id from public.profiles where role = 'admin' order by created_at asc limit 1),
    p_job_id,
    'payment_proof_submitted',
    'Payment proof submitted',
    'A guest customer submitted payment proof for manual verification.',
    jsonb_build_object('payment_id', payment_row.id, 'payment_type', p_payment_type)
  );

  return payment_row;
end;
$$;

create or replace function public.submit_payment_proof(
  p_job_id uuid,
  p_payment_type public.payment_type,
  p_amount numeric,
  p_reference text,
  p_proof_path text
)
returns public.job_payments
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  customer_row public.customers;
  job_row public.jobs;
  payment_row public.job_payments;
  next_status job_status;
begin
  select * into customer_row
  from public.customers
  where profile_id = auth.uid();

  if not found then
    raise exception 'Customer profile not found';
  end if;

  select * into job_row
  from public.jobs
  where id = p_job_id
  for update;

  if not found then
    raise exception 'Job not found';
  end if;

  if job_row.customer_id is distinct from customer_row.id then
    raise exception 'You can only submit payment proof for your own job';
  end if;

  if job_row.status in ('electrician_completed', 'customer_confirmed', 'payout_pending', 'payout_complete', 'rated', 'cancelled') then
    raise exception 'Payment proof cannot be submitted after the job has moved past payment stages';
  end if;

  if exists (
    select 1 from public.job_payments
    where job_id = p_job_id
      and status = 'submitted'
  ) then
    raise exception 'A payment proof is already waiting for manual verification for this job';
  end if;

  if p_payment_type = 'assessment_fee' then
    if job_row.status <> 'assessment_fee_pending' then
      raise exception 'Assessment fee proof can only be submitted when the job is awaiting the assessment fee';
    end if;
    next_status := 'assessment_payment_pending_verification';
  elsif p_payment_type in ('quote_payment', 'material_payment') then
    if job_row.status <> 'quote_accepted' then
      raise exception 'Work payment proof can only be submitted after the quote is accepted';
    end if;
    next_status := 'work_payment_pending_verification';
  else
    raise exception 'Unsupported payment type for customer submission';
  end if;

  if exists (
    select 1
    from public.job_payments
    where job_id = p_job_id
      and payment_type = p_payment_type
      and status in ('submitted', 'verified')
  ) then
    raise exception 'Payment proof for this step has already been submitted';
  end if;

  insert into public.job_payments (job_id, submitted_by, payment_type, amount, proof_path, reference)
  values (p_job_id, auth.uid(), p_payment_type, coalesce(p_amount, 0), p_proof_path, p_reference)
  returning * into payment_row;

  update public.jobs
  set status = next_status
  where id = p_job_id;

  perform public.append_job_timeline(p_job_id, next_status, 'Payment proof submitted for manual verification.', auth.uid());
  perform public.create_notification(
    (select id from public.profiles where role = 'admin' order by created_at asc limit 1),
    p_job_id,
    'payment_proof_submitted',
    'Payment verification needed',
    'A customer submitted payment proof that needs review.',
    jsonb_build_object('payment_id', payment_row.id, 'payment_type', p_payment_type)
  );
  return payment_row;
end;
$$;

create or replace function public.submit_rating(
  p_job_id uuid,
  p_score integer,
  p_comment text default null,
  p_behavior_tags text[] default '{}'::text[]
)
returns public.ratings
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  customer_row public.customers;
  job_row public.jobs;
  electrician_profile uuid;
  rating_row public.ratings;
begin
  if p_score < 1 or p_score > 5 then
    raise exception 'Rating must be between 1 and 5';
  end if;

  select * into customer_row from public.customers where profile_id = auth.uid();
  if not found then
    raise exception 'Customer profile not found';
  end if;

  select * into job_row from public.jobs where id = p_job_id;
  if not found then
    raise exception 'Job not found';
  end if;

  if job_row.customer_id is distinct from customer_row.id then
    raise exception 'You can only rate your own job';
  end if;

  if job_row.status <> 'payout_complete' then
    raise exception 'Ratings open after admin closeout is complete';
  end if;

  if job_row.assigned_electrician_id is null then
    raise exception 'No VoltFriq was assigned to this job';
  end if;

  select profile_id into electrician_profile
  from public.electricians
  where id = job_row.assigned_electrician_id;

  select * into rating_row
  from public.ratings
  where job_id = p_job_id
    and review_direction = 'customer_to_electrician'
  limit 1;

  if found then
    update public.ratings
    set score = p_score,
        comment = p_comment,
        reviewer_profile_id = auth.uid(),
        reviewee_profile_id = electrician_profile,
        reviewee_role = 'electrician',
        behavior_tags = coalesce(p_behavior_tags, '{}'::text[])
    where id = rating_row.id
    returning * into rating_row;
  else
    insert into public.ratings (
      job_id,
      customer_id,
      electrician_id,
      score,
      comment,
      review_direction,
      reviewer_profile_id,
      reviewee_profile_id,
      reviewee_role,
      behavior_tags
    )
    values (
      p_job_id,
      customer_row.id,
      job_row.assigned_electrician_id,
      p_score,
      p_comment,
      'customer_to_electrician',
      auth.uid(),
      electrician_profile,
      'electrician',
      coalesce(p_behavior_tags, '{}'::text[])
    )
    returning * into rating_row;
  end if;

  update public.jobs set status = 'rated' where id = p_job_id;
  perform public.refresh_electrician_trust_metrics(job_row.assigned_electrician_id);
  perform public.reward_completed_referral(auth.uid(), p_job_id);
  perform public.append_job_timeline(p_job_id, 'rated', 'Customer submitted a VoltFriq rating.', auth.uid());
  perform public.create_notification(electrician_profile, p_job_id, 'review_submitted', 'Customer review received', 'A customer submitted feedback for your completed job.', jsonb_build_object('score', p_score));
  return rating_row;
end;
$$;
