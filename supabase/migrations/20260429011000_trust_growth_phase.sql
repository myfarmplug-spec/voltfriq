do $$
begin
  if not exists (
    select 1
    from pg_enum
    where enumtypid = 'notification_event'::regtype
      and enumlabel = 'payment_pending_verification'
  ) then
    alter type notification_event add value 'payment_pending_verification';
  end if;
  if not exists (
    select 1
    from pg_enum
    where enumtypid = 'notification_event'::regtype
      and enumlabel = 'dispute_raised'
  ) then
    alter type notification_event add value 'dispute_raised';
  end if;
  if not exists (
    select 1
    from pg_enum
    where enumtypid = 'notification_event'::regtype
      and enumlabel = 'payout_ready'
  ) then
    alter type notification_event add value 'payout_ready';
  end if;
  if not exists (
    select 1
    from pg_enum
    where enumtypid = 'notification_event'::regtype
      and enumlabel = 'job_stuck'
  ) then
    alter type notification_event add value 'job_stuck';
  end if;
  if not exists (
    select 1
    from pg_enum
    where enumtypid = 'notification_event'::regtype
      and enumlabel = 'reward_issued'
  ) then
    alter type notification_event add value 'reward_issued';
  end if;
end $$;

alter table public.profiles
  add column if not exists referral_code text;

alter table public.electricians
  add column if not exists response_rate numeric(5,2) not null default 0;

create unique index if not exists profiles_referral_code_key
on public.profiles (referral_code)
where referral_code is not null;

create table if not exists public.wallets (
  id uuid primary key default gen_random_uuid(),
  profile_id uuid not null unique references public.profiles(id) on delete cascade,
  balance numeric(12,2) not null default 0,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.wallet_transactions (
  id uuid primary key default gen_random_uuid(),
  wallet_id uuid not null references public.wallets(id) on delete cascade,
  profile_id uuid not null references public.profiles(id) on delete cascade,
  job_id uuid references public.jobs(id) on delete set null,
  transaction_type text not null,
  amount numeric(12,2) not null,
  note text,
  created_at timestamptz not null default now()
);

create table if not exists public.referrals (
  id uuid primary key default gen_random_uuid(),
  referrer_profile_id uuid not null references public.profiles(id) on delete cascade,
  referred_profile_id uuid not null unique references public.profiles(id) on delete cascade,
  referral_code text not null,
  status text not null default 'pending',
  reward_amount numeric(12,2) not null default 0,
  completed_at timestamptz,
  rewarded_at timestamptz,
  created_at timestamptz not null default now()
);

create table if not exists public.disputes (
  id uuid primary key default gen_random_uuid(),
  job_id uuid not null references public.jobs(id) on delete cascade,
  customer_id uuid not null references public.customers(id) on delete cascade,
  electrician_id uuid references public.electricians(id) on delete set null,
  issue_type text not null,
  details text,
  status text not null default 'open',
  resolution_action text,
  resolution_note text,
  resolved_by uuid references public.profiles(id) on delete set null,
  resolved_at timestamptz,
  created_at timestamptz not null default now()
);

create or replace function public.ensure_wallet_for_profile(p_profile_id uuid)
returns public.wallets
language plpgsql
security definer
set search_path = public
as $$
declare
  wallet_row public.wallets;
begin
  insert into public.wallets (profile_id)
  values (p_profile_id)
  on conflict (profile_id) do nothing;

  select * into wallet_row
  from public.wallets
  where profile_id = p_profile_id;

  return wallet_row;
end;
$$;

create or replace function public.generate_referral_code()
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  next_code text;
begin
  loop
    next_code := 'VFQ' || upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 8));
    exit when not exists (select 1 from public.profiles where referral_code = next_code);
  end loop;
  return next_code;
end;
$$;

create or replace function public.handle_profile_rewards_setup()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.referral_code is null then
    new.referral_code := public.generate_referral_code();
  end if;
  return new;
end;
$$;

drop trigger if exists profiles_rewards_setup on public.profiles;
create trigger profiles_rewards_setup
before insert on public.profiles
for each row execute function public.handle_profile_rewards_setup();

create or replace function public.handle_profile_wallet_setup()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  perform public.ensure_wallet_for_profile(new.id);
  return new;
end;
$$;

drop trigger if exists profiles_wallet_setup on public.profiles;
create trigger profiles_wallet_setup
after insert on public.profiles
for each row execute function public.handle_profile_wallet_setup();

update public.profiles
set referral_code = public.generate_referral_code()
where referral_code is null;

insert into public.wallets (profile_id)
select id
from public.profiles
where not exists (
  select 1 from public.wallets w where w.profile_id = public.profiles.id
);

create or replace function public.refresh_electrician_trust_metrics(p_electrician_id uuid)
returns public.electricians
language plpgsql
security definer
set search_path = public
as $$
declare
  updated_row public.electricians;
begin
  update public.electricians e
  set total_ratings = coalesce(stats.total_ratings, 0),
      average_rating = coalesce(stats.average_rating, 0),
      completed_jobs = coalesce(stats.completed_jobs, 0),
      response_rate = coalesce(stats.response_rate, 0)
  from (
    select
      e2.id as electrician_id,
      (
        select count(*)::integer
        from public.ratings r
        where r.electrician_id = e2.id
      ) as total_ratings,
      (
        select round(avg(r.score)::numeric, 2)
        from public.ratings r
        where r.electrician_id = e2.id
      ) as average_rating,
      (
        select count(*)::integer
        from public.jobs j
        where j.assigned_electrician_id = e2.id
          and j.status in ('customer_confirmed', 'payout_pending', 'payout_complete', 'rated')
      ) as completed_jobs,
      (
        case
          when (
            select count(*)
            from public.jobs j
            where e2.id = any(coalesce(j.attempted_electrician_ids, '{}'::uuid[]))
          ) = 0 then 0
          else round(
            (
              (
                select count(*)
                from public.jobs j
                where j.assigned_electrician_id = e2.id
                  and j.accepted_at is not null
              )::numeric
              /
              (
                select count(*)
                from public.jobs j
                where e2.id = any(coalesce(j.attempted_electrician_ids, '{}'::uuid[]))
              )::numeric
            ) * 100,
            2
          )
        end
      ) as response_rate
    from public.electricians e2
    where e2.id = p_electrician_id
  ) stats
  where e.id = stats.electrician_id
  returning e.* into updated_row;

  return updated_row;
end;
$$;

create or replace function public.link_referral_code(p_referral_code text)
returns public.referrals
language plpgsql
security definer
set search_path = public
as $$
declare
  referrer_row public.profiles;
  referral_row public.referrals;
begin
  if auth.uid() is null then
    raise exception 'Authentication required';
  end if;

  if p_referral_code is null or btrim(p_referral_code) = '' then
    raise exception 'Referral code is required';
  end if;

  select * into referrer_row
  from public.profiles
  where referral_code = upper(btrim(p_referral_code));

  if not found then
    raise exception 'Referral code not found';
  end if;

  if referrer_row.id = auth.uid() then
    raise exception 'You cannot use your own referral code';
  end if;

  insert into public.referrals (referrer_profile_id, referred_profile_id, referral_code)
  values (referrer_row.id, auth.uid(), referrer_row.referral_code)
  on conflict (referred_profile_id) do update
  set referral_code = excluded.referral_code
  returning * into referral_row;

  return referral_row;
end;
$$;

create or replace function public.create_dispute(
  p_job_id uuid,
  p_issue_type text,
  p_details text default null
)
returns public.disputes
language plpgsql
security definer
set search_path = public
as $$
declare
  customer_row public.customers;
  job_row public.jobs;
  dispute_row public.disputes;
  admin_profile uuid;
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
    and customer_id = customer_row.id;

  if not found then
    raise exception 'Job not found';
  end if;

  insert into public.disputes (job_id, customer_id, electrician_id, issue_type, details)
  values (p_job_id, customer_row.id, job_row.assigned_electrician_id, p_issue_type, p_details)
  returning * into dispute_row;

  perform public.append_job_timeline(p_job_id, job_row.status, 'Customer reported an issue: ' || coalesce(p_issue_type, 'general dispute') || '.', auth.uid());
  select id into admin_profile from public.profiles where role = 'admin' order by created_at asc limit 1;
  if admin_profile is not null then
    perform public.create_notification(admin_profile, p_job_id, 'dispute_raised', 'Dispute raised', 'A customer reported an issue and admin review is needed.', jsonb_build_object('dispute_id', dispute_row.id, 'issue_type', p_issue_type));
  end if;

  return dispute_row;
end;
$$;

create or replace function public.resolve_dispute(
  p_dispute_id uuid,
  p_status text,
  p_resolution_action text default null,
  p_resolution_note text default null
)
returns public.disputes
language plpgsql
security definer
set search_path = public
as $$
declare
  dispute_row public.disputes;
begin
  if not public.is_admin() then
    raise exception 'Admin access required';
  end if;

  update public.disputes
  set status = coalesce(nullif(p_status, ''), status),
      resolution_action = p_resolution_action,
      resolution_note = p_resolution_note,
      resolved_by = auth.uid(),
      resolved_at = now()
  where id = p_dispute_id
  returning * into dispute_row;

  if not found then
    raise exception 'Dispute not found';
  end if;

  perform public.append_job_timeline(dispute_row.job_id, (select status from public.jobs where id = dispute_row.job_id), 'Admin resolved dispute: ' || coalesce(p_resolution_action, dispute_row.status) || '.', auth.uid());
  return dispute_row;
end;
$$;

create or replace function public.reward_completed_referral(p_referred_profile_id uuid, p_job_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  referral_row public.referrals;
  reward_value numeric := 2500;
  wallet_row public.wallets;
begin
  select * into referral_row
  from public.referrals
  where referred_profile_id = p_referred_profile_id
    and status <> 'rewarded'
  order by created_at asc
  limit 1
  for update;

  if not found then
    return;
  end if;

  select * into wallet_row
  from public.ensure_wallet_for_profile(referral_row.referrer_profile_id);

  update public.wallets
  set balance = balance + reward_value
  where id = wallet_row.id
  returning * into wallet_row;

  insert into public.wallet_transactions (wallet_id, profile_id, job_id, transaction_type, amount, note)
  values (wallet_row.id, referral_row.referrer_profile_id, p_job_id, 'referral_reward', reward_value, 'Referral reward for first completed job.');

  update public.referrals
  set status = 'rewarded',
      reward_amount = reward_value,
      completed_at = coalesce(completed_at, now()),
      rewarded_at = now()
  where id = referral_row.id;

  perform public.create_notification(referral_row.referrer_profile_id, p_job_id, 'reward_issued', 'Referral reward added', 'A wallet reward has been added to your VoltFriq wallet.', jsonb_build_object('amount', reward_value));
end;
$$;

create or replace function public.handle_wallets_touch_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

drop trigger if exists wallets_touch_updated_at on public.wallets;
create trigger wallets_touch_updated_at
before update on public.wallets
for each row execute function public.handle_wallets_touch_updated_at();

create or replace function public.create_customer_job(
  p_service_area text,
  p_location_label text,
  p_latitude double precision,
  p_longitude double precision,
  p_issue_category text,
  p_urgency job_urgency,
  p_customer_note text,
  p_requires_assessment boolean,
  p_material_handling text,
  p_photo_paths text[] default '{}'
)
returns public.jobs
language plpgsql
security definer
set search_path = public
as $$
declare
  customer_row public.customers;
  created_job public.jobs;
begin
  select * into customer_row from public.customers where profile_id = auth.uid();
  if not found then
    raise exception 'Customer profile not found';
  end if;

  if exists (
    select 1
    from public.jobs j
    where j.customer_id = customer_row.id
      and j.issue_category = p_issue_category
      and j.service_area = p_service_area
      and j.status not in ('rated', 'cancelled')
      and j.created_at >= now() - interval '15 minutes'
  ) then
    raise exception 'A similar booking is already active. Track the existing job instead of creating a duplicate.';
  end if;

  insert into public.jobs (
    customer_id,
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
    customer_row.id,
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

  perform public.append_job_timeline(created_job.id, 'requested', 'Customer created a new booking request.', auth.uid());
  perform public.append_job_timeline(created_job.id, 'matching', 'Automatic dispatch started.', auth.uid());
  perform public.create_notification(auth.uid(), created_job.id, 'new_job_created', 'Booking created', 'We are finding the nearest verified VoltFriq for you.', '{}'::jsonb);

  select * into created_job from public.dispatch_job(created_job.id, null);
  return created_job;
end;
$$;

create or replace function public.submit_payment_proof(
  p_job_id uuid,
  p_payment_type payment_type,
  p_amount numeric,
  p_reference text,
  p_proof_path text
)
returns public.job_payments
language plpgsql
security definer
set search_path = public
as $$
declare
  payment_row public.job_payments;
  customer_profile uuid;
begin
  if exists (
    select 1
    from public.job_payments
    where job_id = p_job_id
      and payment_type = p_payment_type
      and status = 'submitted'
  ) then
    raise exception 'A payment proof is already waiting for manual verification for this step.';
  end if;

  insert into public.job_payments (job_id, submitted_by, payment_type, amount, proof_path, reference)
  values (p_job_id, auth.uid(), p_payment_type, coalesce(p_amount, 0), p_proof_path, p_reference)
  returning * into payment_row;

  update public.jobs
  set status = case
    when p_payment_type = 'assessment_fee' then 'assessment_payment_pending_verification'
    else 'work_payment_pending_verification'
  end
  where id = p_job_id;

  select c.profile_id into customer_profile
  from public.jobs j
  join public.customers c on c.id = j.customer_id
  where j.id = p_job_id;

  perform public.append_job_timeline(p_job_id, (select status from public.jobs where id = p_job_id), 'Payment proof submitted for manual verification.', auth.uid());
  perform public.create_notification(
    (select id from public.profiles where role = 'admin' order by created_at asc limit 1),
    p_job_id,
    'payment_proof_submitted',
    'Payment verification needed',
    'A customer submitted payment proof that needs review.',
    jsonb_build_object('payment_id', payment_row.id, 'payment_type', p_payment_type)
  );
  if customer_profile is not null then
    perform public.create_notification(customer_profile, p_job_id, 'payment_pending_verification', 'Payment received', 'Your payment proof was received and is pending manual verification.', jsonb_build_object('payment_id', payment_row.id));
  end if;
  return payment_row;
end;
$$;

create or replace function public.verify_job_payment(
  p_payment_id uuid,
  p_approved boolean,
  p_admin_note text default null
)
returns public.job_payments
language plpgsql
security definer
set search_path = public
as $$
declare
  payment_row public.job_payments;
  next_status job_status;
  customer_profile uuid;
  electrician_profile uuid;
begin
  if not public.is_admin() then
    raise exception 'Admin access required';
  end if;

  select * into payment_row from public.job_payments where id = p_payment_id for update;
  if not found then
    raise exception 'Payment not found';
  end if;

  update public.job_payments
  set status = case when p_approved then 'verified' else 'rejected' end,
      admin_note = p_admin_note,
      verified_by = auth.uid(),
      verified_at = now()
  where id = p_payment_id
  returning * into payment_row;

  if p_approved then
    next_status := case
      when payment_row.payment_type = 'assessment_fee' then 'assessment_confirmed'
      else 'payment_confirmed'
    end;
  else
    next_status := case
      when payment_row.payment_type = 'assessment_fee' then 'assessment_fee_pending'
      else 'quote_accepted'
    end;
  end if;

  update public.jobs set status = next_status where id = payment_row.job_id;

  select c.profile_id into customer_profile
  from public.jobs j
  join public.customers c on c.id = j.customer_id
  where j.id = payment_row.job_id;

  select p.id into electrician_profile
  from public.jobs j
  join public.electricians e on e.id = j.assigned_electrician_id
  join public.profiles p on p.id = e.profile_id
  where j.id = payment_row.job_id;

  perform public.append_job_timeline(payment_row.job_id, next_status, case when p_approved then 'Payment verified by admin.' else 'Payment rejected by admin.' end, auth.uid());
  if p_approved then
    if customer_profile is not null then
      perform public.create_notification(customer_profile, payment_row.job_id, 'payment_verified', 'Payment verified', 'Your payment was verified and the job can move forward.', jsonb_build_object('payment_id', payment_row.id));
    end if;
    if electrician_profile is not null then
      perform public.create_notification(electrician_profile, payment_row.job_id, 'payment_verified', 'Payment confirmed', 'Admin verified customer payment for this job.', jsonb_build_object('payment_id', payment_row.id));
    end if;
  end if;
  return payment_row;
end;
$$;

create or replace function public.electrician_accept_job(p_job_id uuid)
returns public.jobs
language plpgsql
security definer
set search_path = public
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
  if job_row.assigned_electrician_id is distinct from electrician_row.id then
    raise exception 'Job is not assigned to this electrician';
  end if;

  update public.jobs
  set status = case when job_row.requires_assessment then 'assessment_fee_pending' else 'accepted' end,
      accepted_at = now(),
      assignment_expires_at = null
  where id = p_job_id
  returning * into job_row;

  perform public.refresh_electrician_trust_metrics(electrician_row.id);

  select c.profile_id into customer_profile from public.customers c where c.id = job_row.customer_id;
  perform public.append_job_timeline(p_job_id, job_row.status, 'VoltFriq accepted the booking.', auth.uid());
  perform public.create_notification(customer_profile, p_job_id, 'electrician_accepted', 'VoltFriq accepted', 'Your assigned VoltFriq accepted the booking.', '{}'::jsonb);
  return job_row;
end;
$$;

create or replace function public.submit_rating(
  p_job_id uuid,
  p_score integer,
  p_comment text default null
)
returns public.ratings
language plpgsql
security definer
set search_path = public
as $$
declare
  customer_row public.customers;
  job_row public.jobs;
  rating_row public.ratings;
begin
  select * into customer_row from public.customers where profile_id = auth.uid();
  if not found then
    raise exception 'Customer profile not found';
  end if;

  select * into job_row from public.jobs where id = p_job_id;
  if not found then
    raise exception 'Job not found';
  end if;

  insert into public.ratings (job_id, customer_id, electrician_id, score, comment)
  values (p_job_id, customer_row.id, job_row.assigned_electrician_id, p_score, p_comment)
  on conflict (job_id) do update
  set score = excluded.score,
      comment = excluded.comment
  returning * into rating_row;

  update public.jobs set status = 'rated' where id = p_job_id;
  perform public.refresh_electrician_trust_metrics(job_row.assigned_electrician_id);
  perform public.reward_completed_referral(auth.uid(), p_job_id);
  perform public.append_job_timeline(p_job_id, 'rated', 'Customer submitted a rating.', auth.uid());
  return rating_row;
end;
$$;

create or replace function public.handle_job_status_notifications()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  customer_profile uuid;
  electrician_profile uuid;
  admin_profile uuid;
begin
  if tg_op <> 'UPDATE' or new.status = old.status then
    return new;
  end if;

  select c.profile_id into customer_profile from public.customers c where c.id = new.customer_id;
  select e.profile_id into electrician_profile from public.electricians e where e.id = new.assigned_electrician_id;
  select id into admin_profile from public.profiles where role = 'admin' order by created_at asc limit 1;

  if new.status = 'electrician_completed' and customer_profile is not null then
    perform public.create_notification(customer_profile, new.id, 'work_completed', 'Work marked complete', 'Your VoltFriq marked the job complete and is waiting for your confirmation.', '{}'::jsonb);
  end if;

  if new.status = 'payout_pending' and electrician_profile is not null then
    perform public.create_notification(electrician_profile, new.id, 'payout_ready', 'Payout ready', 'Customer confirmed the job. Admin will release payout next.', '{}'::jsonb);
  end if;

  if new.status = 'matching' and new.assigned_electrician_id is null and admin_profile is not null and coalesce(array_length(new.candidate_queue, 1), 0) = 0 then
    perform public.create_notification(admin_profile, new.id, 'job_stuck', 'Job stuck in matching', 'This job needs manual dispatch follow-up.', '{}'::jsonb);
  end if;

  if new.status = 'payout_complete' then
    if customer_profile is not null then
      perform public.create_notification(customer_profile, new.id, 'payout_released', 'Payout released', 'The payout has been released and your receipt is ready.', '{}'::jsonb);
    end if;
    if electrician_profile is not null then
      perform public.create_notification(electrician_profile, new.id, 'payout_released', 'Payout released', 'Admin released payout for this completed job.', '{}'::jsonb);
    end if;
  end if;

  return new;
end;
$$;

alter table public.wallets enable row level security;
alter table public.wallet_transactions enable row level security;
alter table public.referrals enable row level security;
alter table public.disputes enable row level security;

create policy "wallets self or admin" on public.wallets
for select using (profile_id = auth.uid() or public.is_admin());

create policy "wallets admin write" on public.wallets
for all using (public.is_admin()) with check (public.is_admin());

create policy "wallet transactions self or admin" on public.wallet_transactions
for select using (profile_id = auth.uid() or public.is_admin());

create policy "wallet transactions admin write" on public.wallet_transactions
for all using (public.is_admin()) with check (public.is_admin());

create policy "referrals self or admin read" on public.referrals
for select using (referrer_profile_id = auth.uid() or referred_profile_id = auth.uid() or public.is_admin());

create policy "referrals self insert" on public.referrals
for insert with check (referred_profile_id = auth.uid() or public.is_admin());

create policy "referrals admin update" on public.referrals
for update using (public.is_admin()) with check (public.is_admin());

create policy "disputes customer electrician or admin read" on public.disputes
for select using (
  public.is_admin()
  or customer_id = public.current_customer_id()
  or electrician_id = public.current_electrician_id()
);

create policy "disputes customer insert" on public.disputes
for insert with check (customer_id = public.current_customer_id() or public.is_admin());

create policy "disputes admin update" on public.disputes
for update using (public.is_admin()) with check (public.is_admin());
