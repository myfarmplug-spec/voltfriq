-- Tighten storage access around VoltFriq uploads while keeping live customer flows working.

insert into storage.buckets (id, name, public)
values
  ('avatars', 'avatars', true),
  ('electrician-documents', 'electrician-documents', false),
  ('job-photos', 'job-photos', true),
  ('payment-proofs', 'payment-proofs', false)
on conflict (id) do update
set public = excluded.public;

drop policy if exists "voltfriq storage public reads" on storage.objects;
drop policy if exists "voltfriq storage authenticated reads" on storage.objects;
drop policy if exists "voltfriq storage authenticated writes" on storage.objects;
drop policy if exists "voltfriq storage authenticated updates" on storage.objects;
drop policy if exists "voltfriq storage guest writes" on storage.objects;
drop policy if exists "voltfriq authenticated uploads" on storage.objects;
drop policy if exists "voltfriq guest uploads" on storage.objects;

create policy "voltfriq avatar public read" on storage.objects
for select to anon, authenticated
using (bucket_id = 'avatars');

create policy "voltfriq job photos public read" on storage.objects
for select to anon, authenticated
using (bucket_id = 'job-photos');

create policy "voltfriq electrician docs read" on storage.objects
for select to authenticated
using (
  bucket_id = 'electrician-documents'
  and (
    public.is_admin()
    or exists (
      select 1
      from public.electrician_documents d
      join public.electricians e on e.id = d.electrician_id
      where d.file_path = storage.objects.name
        and e.profile_id = auth.uid()
    )
    or exists (
      select 1
      from public.electrician_appeals a
      join public.electricians e on e.id = a.electrician_id
      where a.supporting_file_path = storage.objects.name
        and e.profile_id = auth.uid()
    )
  )
);

create policy "voltfriq payment proof read" on storage.objects
for select to authenticated
using (
  bucket_id = 'payment-proofs'
  and (
    public.is_admin()
    or exists (
      select 1
      from public.job_payments jp
      join public.jobs j on j.id = jp.job_id
      left join public.customers c on c.id = j.customer_id
      left join public.electricians e on e.id = j.assigned_electrician_id
      where jp.proof_path = storage.objects.name
        and (
          jp.submitted_by = auth.uid()
          or c.profile_id = auth.uid()
          or e.profile_id = auth.uid()
        )
    )
  )
);

create policy "voltfriq avatar owner write" on storage.objects
for insert to authenticated
with check (
  bucket_id = 'avatars'
  and owner = auth.uid()
  and split_part(name, '/', 1) = auth.uid()::text
);

create policy "voltfriq avatar owner update" on storage.objects
for update to authenticated
using (
  bucket_id = 'avatars'
  and (owner = auth.uid() or public.is_admin())
)
with check (
  bucket_id = 'avatars'
  and (owner = auth.uid() or public.is_admin())
);

create policy "voltfriq electrician docs write" on storage.objects
for insert to authenticated
with check (
  bucket_id = 'electrician-documents'
  and (
    public.is_admin()
    or exists (
      select 1
      from public.electricians e
      where e.profile_id = auth.uid()
        and (
          split_part(storage.objects.name, '/', 1) = e.id::text
          or split_part(storage.objects.name, '/', 1) = 'appeals'
        )
    )
  )
);

create policy "voltfriq electrician docs update" on storage.objects
for update to authenticated
using (
  bucket_id = 'electrician-documents'
  and (owner = auth.uid() or public.is_admin())
)
with check (
  bucket_id = 'electrician-documents'
  and (owner = auth.uid() or public.is_admin())
);

create policy "voltfriq authenticated job photo write" on storage.objects
for insert to authenticated
with check (
  bucket_id = 'job-photos'
  and split_part(name, '/', 1) = 'job-photos'
  and split_part(name, '/', 2) = auth.uid()::text
);

create policy "voltfriq authenticated job photo update" on storage.objects
for update to authenticated
using (
  bucket_id = 'job-photos'
  and (owner = auth.uid() or public.is_admin())
)
with check (
  bucket_id = 'job-photos'
  and (owner = auth.uid() or public.is_admin())
);

create policy "voltfriq authenticated payment proof write" on storage.objects
for insert to authenticated
with check (
  bucket_id = 'payment-proofs'
  and (
    public.is_admin()
    or split_part(name, '/', 1) = 'payments'
  )
);

create policy "voltfriq authenticated payment proof update" on storage.objects
for update to authenticated
using (
  bucket_id = 'payment-proofs'
  and (owner = auth.uid() or public.is_admin())
)
with check (
  bucket_id = 'payment-proofs'
  and (owner = auth.uid() or public.is_admin())
);

create policy "voltfriq guest upload write" on storage.objects
for insert to anon
with check (
  bucket_id in ('job-photos', 'payment-proofs')
  and split_part(name, '/', 1) = 'guest'
);
