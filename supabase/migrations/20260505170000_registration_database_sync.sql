-- Make Supabase Auth signups immediately visible in app-owned public tables.

create or replace function public.sync_app_account_for_auth_user(p_user_id uuid)
returns public.profiles
language plpgsql
security definer
set search_path = public
as $$
declare
  user_row auth.users;
  existing_role public.user_role;
  metadata_role text;
  account_role public.user_role;
  profile_role public.user_role;
  profile_row public.profiles;
  lat_raw text;
  lng_raw text;
  years_raw text;
  score_raw text;
  parsed_latitude double precision;
  parsed_longitude double precision;
  parsed_years integer;
  parsed_score numeric;
  service_areas text[] := '{}'::text[];
  onboarding_answers jsonb := '[]'::jsonb;
begin
  select * into user_row from auth.users where id = p_user_id;
  if not found then
    raise exception 'Auth user % does not exist', p_user_id;
  end if;

  select role into existing_role
  from public.profiles
  where id = user_row.id;

  metadata_role := lower(nullif(user_row.raw_user_meta_data ->> 'requested_role', ''));

  if metadata_role = 'electrician' then
    account_role := 'electrician';
  elsif existing_role = 'electrician' then
    account_role := 'electrician';
  else
    account_role := 'customer';
  end if;

  profile_role := case
    when existing_role = 'admin' then 'admin'::public.user_role
    else account_role
  end;

  lat_raw := nullif(coalesce(user_row.raw_user_meta_data ->> 'latitude', user_row.raw_user_meta_data ->> 'lat'), '');
  lng_raw := nullif(coalesce(user_row.raw_user_meta_data ->> 'longitude', user_row.raw_user_meta_data ->> 'lng'), '');
  years_raw := nullif(user_row.raw_user_meta_data ->> 'years_experience', '');
  score_raw := nullif(user_row.raw_user_meta_data ->> 'onboarding_score', '');

  if lat_raw ~ '^-?[0-9]+(\.[0-9]+)?$' then
    parsed_latitude := lat_raw::double precision;
  end if;

  if lng_raw ~ '^-?[0-9]+(\.[0-9]+)?$' then
    parsed_longitude := lng_raw::double precision;
  end if;

  if years_raw ~ '^[0-9]+$' then
    parsed_years := years_raw::integer;
  end if;

  if score_raw ~ '^-?[0-9]+(\.[0-9]+)?$' then
    parsed_score := score_raw::numeric;
  end if;

  if jsonb_typeof(user_row.raw_user_meta_data -> 'service_areas') = 'array' then
    select coalesce(array_agg(value), '{}'::text[])
    into service_areas
    from jsonb_array_elements_text(user_row.raw_user_meta_data -> 'service_areas') as area(value);
  elsif nullif(user_row.raw_user_meta_data ->> 'primary_service_area', '') is not null then
    service_areas := array[user_row.raw_user_meta_data ->> 'primary_service_area'];
  elsif nullif(user_row.raw_user_meta_data ->> 'service_area', '') is not null then
    service_areas := array[user_row.raw_user_meta_data ->> 'service_area'];
  end if;

  if jsonb_typeof(user_row.raw_user_meta_data -> 'onboarding_answers') = 'array' then
    onboarding_answers := user_row.raw_user_meta_data -> 'onboarding_answers';
  end if;

  insert into public.profiles (id, role, full_name, phone)
  values (
    user_row.id,
    profile_role,
    coalesce(nullif(user_row.raw_user_meta_data ->> 'full_name', ''), user_row.email, ''),
    nullif(user_row.raw_user_meta_data ->> 'phone', '')
  )
  on conflict (id) do update
    set role = case
          when public.profiles.role = 'admin' then 'admin'::public.user_role
          else excluded.role
        end,
        full_name = coalesce(nullif(excluded.full_name, ''), nullif(public.profiles.full_name, ''), user_row.email, ''),
        phone = coalesce(nullif(excluded.phone, ''), public.profiles.phone)
  returning * into profile_row;

  if profile_role = 'customer' then
    insert into public.customers (profile_id, primary_service_area, latitude, longitude)
    values (
      user_row.id,
      nullif(user_row.raw_user_meta_data ->> 'primary_service_area', ''),
      parsed_latitude,
      parsed_longitude
    )
    on conflict (profile_id) do update
      set primary_service_area = coalesce(excluded.primary_service_area, public.customers.primary_service_area),
          latitude = coalesce(excluded.latitude, public.customers.latitude),
          longitude = coalesce(excluded.longitude, public.customers.longitude);
  elsif profile_role = 'electrician' then
    insert into public.electricians (
      profile_id,
      status,
      years_experience,
      service_areas,
      location_label,
      latitude,
      longitude,
      bank_name,
      bank_account_number,
      bank_account_name,
      availability_status,
      onboarding_score,
      onboarding_review_status,
      onboarding_feedback,
      onboarding_answers
    )
    values (
      user_row.id,
      'pending',
      coalesce(parsed_years, 0),
      service_areas,
      nullif(user_row.raw_user_meta_data ->> 'location_label', ''),
      parsed_latitude,
      parsed_longitude,
      coalesce(nullif(user_row.raw_user_meta_data ->> 'bank_name', ''), ''),
      coalesce(nullif(user_row.raw_user_meta_data ->> 'bank_account_number', ''), ''),
      coalesce(nullif(user_row.raw_user_meta_data ->> 'bank_account_name', ''), ''),
      coalesce(nullif(user_row.raw_user_meta_data ->> 'availability_status', ''), 'available'),
      coalesce(parsed_score, 0),
      coalesce(nullif(user_row.raw_user_meta_data ->> 'onboarding_review_status', ''), 'pending'),
      nullif(user_row.raw_user_meta_data ->> 'onboarding_feedback', ''),
      onboarding_answers
    )
    on conflict (profile_id) do update
      set years_experience = greatest(public.electricians.years_experience, excluded.years_experience),
          service_areas = case
            when array_length(excluded.service_areas, 1) is not null then excluded.service_areas
            else public.electricians.service_areas
          end,
          location_label = coalesce(excluded.location_label, public.electricians.location_label),
          latitude = coalesce(excluded.latitude, public.electricians.latitude),
          longitude = coalesce(excluded.longitude, public.electricians.longitude),
          bank_name = coalesce(nullif(excluded.bank_name, ''), public.electricians.bank_name),
          bank_account_number = coalesce(nullif(excluded.bank_account_number, ''), public.electricians.bank_account_number),
          bank_account_name = coalesce(nullif(excluded.bank_account_name, ''), public.electricians.bank_account_name),
          availability_status = coalesce(nullif(excluded.availability_status, ''), public.electricians.availability_status),
          onboarding_score = greatest(public.electricians.onboarding_score, excluded.onboarding_score),
          onboarding_review_status = coalesce(nullif(excluded.onboarding_review_status, ''), public.electricians.onboarding_review_status),
          onboarding_feedback = coalesce(excluded.onboarding_feedback, public.electricians.onboarding_feedback),
          onboarding_answers = case
            when jsonb_array_length(excluded.onboarding_answers) > 0 then excluded.onboarding_answers
            else public.electricians.onboarding_answers
          end;
  end if;

  return profile_row;
end;
$$;

revoke all on function public.sync_app_account_for_auth_user(uuid) from public;
revoke all on function public.sync_app_account_for_auth_user(uuid) from anon;
revoke all on function public.sync_app_account_for_auth_user(uuid) from authenticated;
grant execute on function public.sync_app_account_for_auth_user(uuid) to service_role;

create or replace function public.ensure_app_account_for_current_user()
returns public.profiles
language plpgsql
security definer
set search_path = public
as $$
begin
  if auth.uid() is null then
    raise exception 'No authenticated user';
  end if;

  return public.sync_app_account_for_auth_user(auth.uid());
end;
$$;

grant execute on function public.ensure_app_account_for_current_user() to authenticated;
grant execute on function public.ensure_app_account_for_current_user() to service_role;

create or replace function public.ensure_profile_for_current_user()
returns public.profiles
language plpgsql
security definer
set search_path = public
as $$
begin
  return public.ensure_app_account_for_current_user();
end;
$$;

create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  perform public.sync_app_account_for_auth_user(new.id);
  return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
after insert on auth.users
for each row execute function public.handle_new_user();

do $$
declare
  auth_user auth.users;
begin
  for auth_user in select * from auth.users loop
    perform public.sync_app_account_for_auth_user(auth_user.id);
  end loop;
end;
$$;
