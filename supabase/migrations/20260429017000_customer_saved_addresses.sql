-- Add saved addresses for authenticated customers.
-- Guest saved addresses remain device-local in the browser.

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

create index if not exists customer_addresses_profile_idx
on public.customer_addresses(profile_id, last_used_at desc);

create index if not exists customer_addresses_profile_address_idx
on public.customer_addresses(profile_id, lower(address_text));

drop trigger if exists customer_addresses_touch_updated_at on public.customer_addresses;
create trigger customer_addresses_touch_updated_at
before update on public.customer_addresses
for each row execute function public.touch_updated_at();

alter table public.customer_addresses enable row level security;

do $$
begin
  if not exists (
    select 1
    from pg_policies
    where schemaname = 'public'
      and tablename = 'customer_addresses'
      and policyname = 'customer addresses owner or admin'
  ) then
    create policy "customer addresses owner or admin" on public.customer_addresses
    for all
    using (profile_id = auth.uid() or public.is_admin())
    with check (profile_id = auth.uid() or public.is_admin());
  end if;
end $$;
