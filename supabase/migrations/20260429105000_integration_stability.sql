-- Integration stability guardrails.
-- This migration is additive/idempotent: it does not recreate existing data.

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

create table if not exists public.electrician_appeals (
  id uuid primary key default gen_random_uuid(),
  electrician_id uuid not null references public.electricians(id) on delete cascade,
  status text not null default 'open',
  appeal_note text not null,
  supporting_file_path text,
  admin_note text,
  reviewed_by uuid references public.profiles(id) on delete set null,
  reviewed_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.customer_addresses (
  id uuid primary key default gen_random_uuid(),
  profile_id uuid not null references public.profiles(id) on delete cascade,
  label text not null default 'Saved address',
  address_text text not null,
  location_label text,
  latitude double precision,
  longitude double precision,
  last_used_at timestamptz not null default now(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

alter table public.wallets enable row level security;
alter table public.wallet_transactions enable row level security;
alter table public.referrals enable row level security;
alter table public.disputes enable row level security;
alter table public.electrician_appeals enable row level security;
alter table public.customer_addresses enable row level security;

insert into storage.buckets (id, name, public)
values
  ('avatars', 'avatars', true),
  ('electrician-documents', 'electrician-documents', false),
  ('job-photos', 'job-photos', true),
  ('payment-proofs', 'payment-proofs', false)
on conflict (id) do update
set public = excluded.public;

do $$
begin
  if not exists (
    select 1 from pg_policies
    where schemaname = 'storage' and tablename = 'objects' and policyname = 'voltfriq storage public reads'
  ) then
    create policy "voltfriq storage public reads" on storage.objects
    for select to anon, authenticated
    using (bucket_id in ('avatars', 'job-photos'));
  end if;

  if not exists (
    select 1 from pg_policies
    where schemaname = 'storage' and tablename = 'objects' and policyname = 'voltfriq storage authenticated reads'
  ) then
    create policy "voltfriq storage authenticated reads" on storage.objects
    for select to authenticated
    using (
      bucket_id in ('avatars', 'job-photos')
      or owner = auth.uid()
      or public.is_admin()
    );
  end if;

  if not exists (
    select 1 from pg_policies
    where schemaname = 'storage' and tablename = 'objects' and policyname = 'voltfriq storage authenticated writes'
  ) then
    create policy "voltfriq storage authenticated writes" on storage.objects
    for insert to authenticated
    with check (bucket_id in ('avatars', 'electrician-documents', 'job-photos', 'payment-proofs'));
  end if;

  if not exists (
    select 1 from pg_policies
    where schemaname = 'storage' and tablename = 'objects' and policyname = 'voltfriq storage authenticated updates'
  ) then
    create policy "voltfriq storage authenticated updates" on storage.objects
    for update to authenticated
    using (owner = auth.uid() or public.is_admin())
    with check (bucket_id in ('avatars', 'electrician-documents', 'job-photos', 'payment-proofs'));
  end if;

  if not exists (
    select 1 from pg_policies
    where schemaname = 'storage' and tablename = 'objects' and policyname = 'voltfriq storage guest writes'
  ) then
    create policy "voltfriq storage guest writes" on storage.objects
    for insert to anon
    with check (
      bucket_id in ('job-photos', 'payment-proofs')
      and name like 'guest/%'
    );
  end if;
end $$;
