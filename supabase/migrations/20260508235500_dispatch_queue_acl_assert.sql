revoke all on function public.process_dispatch_queue() from public;
revoke all on function public.process_dispatch_queue() from anon;
revoke all on function public.process_dispatch_queue() from authenticated;
grant execute on function public.process_dispatch_queue() to service_role;

revoke all on function public.dispatch_job_internal(uuid, uuid) from public;
revoke all on function public.dispatch_job_internal(uuid, uuid) from anon;
revoke all on function public.dispatch_job_internal(uuid, uuid) from authenticated;
grant execute on function public.dispatch_job_internal(uuid, uuid) to service_role;
