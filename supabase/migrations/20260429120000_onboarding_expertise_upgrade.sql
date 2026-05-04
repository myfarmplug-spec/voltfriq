create table if not exists public.expertise_categories (
  id uuid primary key default gen_random_uuid(),
  label text not null unique,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.electrician_certifications (
  id uuid primary key default gen_random_uuid(),
  electrician_id uuid not null references public.electricians(id) on delete cascade,
  title text not null,
  license_number text,
  issuer text,
  created_at timestamptz not null default now()
);

alter table public.electricians
  add column if not exists onboarding_score numeric(5,2) not null default 0,
  add column if not exists onboarding_review_status text not null default 'pending',
  add column if not exists onboarding_feedback text,
  add column if not exists onboarding_answers jsonb not null default '[]'::jsonb;

alter table public.expertise_categories enable row level security;
alter table public.electrician_certifications enable row level security;

do $$
begin
  if not exists (
    select 1 from pg_policies
    where schemaname = 'public' and tablename = 'expertise_categories' and policyname = 'expertise categories readable by all'
  ) then
    create policy "expertise categories readable by all" on public.expertise_categories
    for select to anon, authenticated
    using (true);
  end if;

  if not exists (
    select 1 from pg_policies
    where schemaname = 'public' and tablename = 'expertise_categories' and policyname = 'expertise categories admin write'
  ) then
    create policy "expertise categories admin write" on public.expertise_categories
    for all to authenticated
    using (public.is_admin())
    with check (public.is_admin());
  end if;

  if not exists (
    select 1 from pg_policies
    where schemaname = 'public' and tablename = 'electrician_certifications' and policyname = 'electrician certifications own or admin read'
  ) then
    create policy "electrician certifications own or admin read" on public.electrician_certifications
    for select to authenticated
    using (
      public.is_admin()
      or exists (
        select 1
        from public.electricians e
        where e.id = electrician_certifications.electrician_id
          and e.profile_id = auth.uid()
      )
    );
  end if;

  if not exists (
    select 1 from pg_policies
    where schemaname = 'public' and tablename = 'electrician_certifications' and policyname = 'electrician certifications own insert'
  ) then
    create policy "electrician certifications own insert" on public.electrician_certifications
    for insert to authenticated
    with check (
      public.is_admin()
      or exists (
        select 1
        from public.electricians e
        where e.id = electrician_certifications.electrician_id
          and e.profile_id = auth.uid()
      )
    );
  end if;
end $$;

insert into public.expertise_categories (label)
select category
from (
  values
    ('Light fitting'),
    ('Socket repair'),
    ('Wiring issue'),
    ('Inverter'),
    ('Generator'),
    ('Tripped breaker'),
    ('General Installation'),
    ('Inspection'),
    ('Solar'),
    ('Other')
) as defaults(category)
on conflict (label) do nothing;
