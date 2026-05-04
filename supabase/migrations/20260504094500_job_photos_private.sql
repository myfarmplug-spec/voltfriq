-- Make customer job photos private and readable only by relevant parties.

insert into storage.buckets (id, name, public)
values ('job-photos', 'job-photos', false)
on conflict (id) do update
set public = excluded.public;

drop policy if exists "voltfriq job photos public read" on storage.objects;

create policy "voltfriq job photos protected read" on storage.objects
for select to authenticated
using (
  bucket_id = 'job-photos'
  and (
    public.is_admin()
    or exists (
      select 1
      from public.job_photos jp
      join public.jobs j on j.id = jp.job_id
      left join public.customers c on c.id = j.customer_id
      left join public.electricians e on e.id = j.assigned_electrician_id
      where jp.file_path = storage.objects.name
        and (
          c.profile_id = auth.uid()
          or e.profile_id = auth.uid()
        )
    )
  )
);
