drop function if exists public.submit_rating(uuid, integer, text);

create or replace function public.update_guest_job_status(
  p_job_id uuid,
  p_access_token text,
  p_next_status job_status,
  p_note text default null,
  p_metadata jsonb default '{}'::jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
begin
  perform 1
  from public.jobs
  where id = p_job_id
    and customer_access_token = p_access_token
    and guest_customer_id is not null
  for update;

  if not found then
    raise exception 'Guest job not found';
  end if;

  if p_next_status not in ('quote_accepted', 'customer_confirmed', 'payout_pending', 'cancelled') then
    raise exception 'Guest customers cannot set this job status';
  end if;

  update public.jobs
  set status = p_next_status,
      customer_confirmed_at = case when p_next_status in ('customer_confirmed', 'payout_pending') then coalesce(customer_confirmed_at, now()) else customer_confirmed_at end
  where id = p_job_id;

  insert into public.job_timeline (job_id, status, note, actor_profile_id, metadata)
  values (p_job_id, p_next_status, p_note, null, coalesce(p_metadata, '{}'::jsonb));

  return public.guest_job_payload(p_job_id, p_access_token);
end;
$$;
