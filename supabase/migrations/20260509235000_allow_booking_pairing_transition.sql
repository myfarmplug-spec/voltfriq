-- Allow the booking-created flow to start pairing without weakening
-- customer-controlled state changes generally.
create or replace function public.is_valid_job_transition(
  p_current_status public.job_status,
  p_next_status public.job_status,
  p_actor_role text,
  p_is_admin boolean default false,
  p_metadata jsonb default '{}'::jsonb
) returns boolean
language plpgsql
stable
set search_path = public
as $$
declare
  actor_role_value text := lower(coalesce(p_actor_role, 'system'));
  admin_override boolean := lower(coalesce(p_metadata ->> 'admin_override', 'false')) in ('true', '1', 'yes');
  source_value text := coalesce(nullif(btrim(coalesce(p_metadata ->> 'source', '')), ''), 'app');
begin
  if p_current_status is null or p_next_status is null then
    return false;
  end if;

  if p_current_status = p_next_status then
    return true;
  end if;

  if p_current_status in ('payout_complete', 'rated', 'cancelled') then
    return false;
  end if;

  if p_is_admin and admin_override then
    return p_next_status not in ('requested', 'matching', 'assigned')
      or p_current_status in ('requested', 'matching', 'assigned');
  end if;

  if actor_role_value in ('customer', 'guest') then
    return (
        p_current_status = 'requested'
        and p_next_status = 'matching'
        and source_value in ('create_customer_job', 'create_guest_customer_job')
      )
      or (p_current_status = 'quoted' and p_next_status = 'quote_accepted')
      or (p_current_status = 'electrician_completed' and p_next_status = 'customer_confirmed')
      or (
        p_next_status = 'cancelled'
        and p_current_status in ('requested', 'matching', 'assigned', 'accepted', 'assessment_fee_pending', 'quoted')
      );
  end if;

  if actor_role_value = 'electrician' then
    return (p_current_status = 'assigned' and p_next_status in ('accepted', 'assessment_fee_pending'))
      or (p_current_status = 'assessment_confirmed' and p_next_status = 'en_route')
      or (p_current_status = 'en_route' and p_next_status = 'on_site')
      or (p_current_status = 'payment_confirmed' and p_next_status = 'work_in_progress')
      or (p_current_status = 'work_in_progress' and p_next_status = 'electrician_completed');
  end if;

  if actor_role_value in ('admin', 'system') then
    return (p_current_status = 'requested' and p_next_status in ('matching', 'assigned', 'cancelled'))
      or (p_current_status = 'matching' and p_next_status in ('assigned', 'cancelled'))
      or (p_current_status = 'assigned' and p_next_status in ('matching', 'accepted', 'assessment_fee_pending', 'cancelled'))
      or (p_current_status = 'accepted' and p_next_status in ('assessment_fee_pending', 'quoted', 'cancelled'))
      or (p_current_status = 'assessment_fee_pending' and p_next_status in ('assessment_payment_pending_verification', 'cancelled'))
      or (p_current_status = 'assessment_payment_pending_verification' and p_next_status in ('assessment_confirmed', 'assessment_fee_pending', 'cancelled'))
      or (p_current_status = 'assessment_confirmed' and p_next_status in ('en_route', 'on_site', 'quoted', 'cancelled'))
      or (p_current_status = 'en_route' and p_next_status in ('on_site', 'cancelled'))
      or (p_current_status = 'on_site' and p_next_status in ('quoted', 'cancelled'))
      or (p_current_status = 'quoted' and p_next_status in ('quote_accepted', 'cancelled'))
      or (p_current_status = 'quote_accepted' and p_next_status in ('work_payment_pending_verification', 'cancelled'))
      or (p_current_status = 'work_payment_pending_verification' and p_next_status in ('payment_confirmed', 'quote_accepted', 'cancelled'))
      or (p_current_status = 'payment_confirmed' and p_next_status in ('work_in_progress', 'cancelled'))
      or (p_current_status = 'work_in_progress' and p_next_status in ('electrician_completed', 'cancelled'))
      or (p_current_status = 'electrician_completed' and p_next_status in ('customer_confirmed', 'cancelled'))
      or (p_current_status = 'customer_confirmed' and p_next_status in ('payout_pending', 'payout_complete'))
      or (p_current_status = 'payout_pending' and p_next_status = 'payout_complete')
      or (p_current_status = 'payout_complete' and p_next_status = 'rated');
  end if;

  return false;
end;
$$;
