-- Let pending VoltFriqs upload onboarding documents before document rows exist.

drop policy if exists "voltfriq electrician docs write" on storage.objects;

create policy "voltfriq electrician docs write" on storage.objects
for insert to authenticated
with check (
  bucket_id = 'electrician-documents'
  and (
    public.is_admin()
    or (
      owner = auth.uid()
      and (
        split_part(name, '/', 1) = auth.uid()::text
        or split_part(name, '/', 1) = 'appeals'
        or exists (
          select 1
          from public.electricians e
          where e.profile_id = auth.uid()
            and split_part(name, '/', 1) = e.id::text
        )
      )
    )
  )
);
