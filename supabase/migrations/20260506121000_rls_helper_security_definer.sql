create or replace function public.is_admin()
returns boolean
language sql
stable
security definer
set search_path to 'public'
as $$
  select exists (
    select 1
    from public.profiles
    where id = auth.uid() and role = 'admin'
  );
$$;

create or replace function public.current_customer_id()
returns uuid
language sql
stable
security definer
set search_path to 'public'
as $$
  select id from public.customers where profile_id = auth.uid() limit 1;
$$;

create or replace function public.current_electrician_id()
returns uuid
language sql
stable
security definer
set search_path to 'public'
as $$
  select id from public.electricians where profile_id = auth.uid() limit 1;
$$;

grant execute on function public.is_admin() to anon;
grant execute on function public.is_admin() to authenticated;
grant execute on function public.is_admin() to service_role;

grant execute on function public.current_customer_id() to anon;
grant execute on function public.current_customer_id() to authenticated;
grant execute on function public.current_customer_id() to service_role;

grant execute on function public.current_electrician_id() to anon;
grant execute on function public.current_electrician_id() to authenticated;
grant execute on function public.current_electrician_id() to service_role;
