-- Supabase can show future default grants for the platform-owned supabase_admin role.
-- Application migrations run with postgres-owned objects, which are locked down in
-- 20260509143000_final_security_cleanup.sql. Try to clean the platform defaults too,
-- but do not block deploy if Supabase denies changing its reserved role.

do $$
begin
  execute 'alter default privileges for role supabase_admin in schema public revoke all on functions from public, anon, authenticated';
  execute 'alter default privileges for role supabase_admin in schema public revoke all on tables from public, anon, authenticated';
  execute 'alter default privileges for role supabase_admin in schema public revoke all on sequences from public, anon, authenticated';
  execute 'alter default privileges for role supabase_admin in schema public grant all on functions to postgres';
  execute 'alter default privileges for role supabase_admin in schema public grant all on functions to service_role';
  execute 'alter default privileges for role supabase_admin in schema public grant all on tables to postgres';
  execute 'alter default privileges for role supabase_admin in schema public grant all on tables to service_role';
  execute 'alter default privileges for role supabase_admin in schema public grant all on sequences to postgres';
  execute 'alter default privileges for role supabase_admin in schema public grant all on sequences to service_role';
exception
  when insufficient_privilege then
    raise notice 'Supabase denied changing default privileges for reserved role supabase_admin; postgres-owned future defaults remain locked down.';
end
$$;
