-- Admin dashboard reads must not refresh/write operational alerts during login.
-- Automation/cron owns alert refresh; the dashboard should read the latest snapshot.

create index if not exists notifications_profile_created_idx
  on public.notifications (profile_id, created_at desc);

create index if not exists job_payments_status_created_idx
  on public.job_payments (status, created_at desc);

create index if not exists disputes_status_created_idx
  on public.disputes (status, created_at desc);

create index if not exists electricians_status_created_idx
  on public.electricians (status, created_at desc);

create index if not exists jobs_status_updated_idx
  on public.jobs (status, updated_at desc);

create index if not exists jobs_status_assignment_expires_idx
  on public.jobs (status, assignment_expires_at)
  where assignment_expires_at is not null;

create index if not exists jobs_matching_dispatch_attempts_idx
  on public.jobs (status, dispatch_attempts desc, last_dispatch_at asc)
  where status = 'matching';

create index if not exists operational_alerts_status_severity_seen_idx
  on public.operational_alerts (status, severity, last_seen_at desc);

create index if not exists operational_alerts_status_alert_type_seen_idx
  on public.operational_alerts (status, alert_type, last_seen_at desc);

create index if not exists operational_automation_runs_status_started_idx
  on public.operational_automation_runs (status, started_at desc);

create index if not exists operational_automation_runs_status_finished_idx
  on public.operational_automation_runs (status, finished_at desc);

create index if not exists event_replay_runs_status_finished_idx
  on public.event_replay_runs (status, finished_at desc);

create index if not exists job_events_type_created_job_idx
  on public.job_events (event_type, created_at desc, job_id);

do $$
declare
  function_name text;
  function_def text;
  function_without_refresh text;
begin
  foreach function_name in array array[
    'public.admin_operational_summary()',
    'public.admin_operational_queues()'
  ]
  loop
    select pg_get_functiondef(function_name::regprocedure)
      into function_def;

    function_without_refresh := regexp_replace(
      function_def,
      E'\\n[[:space:]]*perform[[:space:]]+public\\.refresh_operational_alerts\\(\\);[[:space:]]*\\n',
      E'\n',
      'g'
    );

    if function_without_refresh = function_def then
      raise notice '% already avoids refresh_operational_alerts()', function_name;
    else
      execute function_without_refresh;
    end if;
  end loop;
end $$;

revoke all on function public.admin_operational_summary() from public, anon, authenticated;
grant execute on function public.admin_operational_summary() to authenticated, service_role;

revoke all on function public.admin_operational_queues() from public, anon, authenticated;
grant execute on function public.admin_operational_queues() to authenticated, service_role;
