-- verify_job_payment emits this event when an admin rejects a payment proof.

do $$
begin
  if not exists (
    select 1
    from pg_enum
    where enumtypid = 'public.notification_event'::regtype
      and enumlabel = 'payment_rejected'
  ) then
    alter type public.notification_event add value 'payment_rejected';
  end if;
end $$;
