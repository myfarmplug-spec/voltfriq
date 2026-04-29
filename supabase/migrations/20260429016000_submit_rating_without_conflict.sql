create or replace function public.submit_rating(
  p_job_id uuid,
  p_score integer,
  p_comment text default null,
  p_behavior_tags text[] default '{}'::text[]
)
returns public.ratings
language plpgsql
security definer
set search_path = public
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
