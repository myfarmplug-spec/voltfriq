-- VoltFriq production launch coverage: Nigeria-wide service locations.

alter table public.admin_settings
  add column if not exists supported_states text[] not null default '{}'::text[],
  add column if not exists supported_cities text[] not null default '{}'::text[],
  add column if not exists launch_cities text[] not null default '{}'::text[],
  add column if not exists disabled_service_areas text[] not null default '{}'::text[];

alter table public.electricians
  add column if not exists service_radius_km integer not null default 25;

do $$
declare
  nigeria_states text[] := array[
    'Abia','Adamawa','Akwa Ibom','Anambra','Bauchi','Bayelsa','Benue','Borno','Cross River',
    'Delta','Ebonyi','Edo','Ekiti','Enugu','FCT','Gombe','Imo','Jigawa','Kaduna','Kano',
    'Katsina','Kebbi','Kogi','Kwara','Lagos','Nasarawa','Niger','Ogun','Ondo','Osun',
    'Oyo','Plateau','Rivers','Sokoto','Taraba','Yobe','Zamfara'
  ];
begin
  insert into public.admin_settings (service_areas, supported_states, supported_cities, launch_cities, disabled_service_areas)
  select nigeria_states, nigeria_states, '{}'::text[], '{}'::text[], '{}'::text[]
  where not exists (select 1 from public.admin_settings);

  update public.admin_settings
  set service_areas = nigeria_states,
      supported_states = nigeria_states,
      supported_cities = coalesce(supported_cities, '{}'::text[]),
      launch_cities = coalesce(launch_cities, '{}'::text[]),
      disabled_service_areas = coalesce(disabled_service_areas, '{}'::text[]),
      updated_at = now()
  where coalesce(array_length(service_areas, 1), 0) = 0
     or service_areas <@ array[
        'GRA, Port Harcourt','Old GRA, Port Harcourt','New GRA, Port Harcourt','D-Line, Port Harcourt',
        'Trans Amadi, Port Harcourt','Woji, Port Harcourt','Rumuola, Port Harcourt','Rumuodomaya, Port Harcourt',
        'Rumuokoro, Port Harcourt','Rumuigbo, Port Harcourt','Ada George, Port Harcourt','Eliozu, Port Harcourt',
        'Elelenwo, Port Harcourt','Mile 1, Port Harcourt','Mile 3, Port Harcourt','Choba, Port Harcourt',
        'Owerri Municipal','Owerri North','Owerri West','Orlu','Okigwe'
      ]::text[]
     or service_areas <@ array['Lekki Phase 1','Victoria Island','Ikeja','Surulere','Yaba','Ajah']::text[];
end
$$;

create or replace function public.find_matching_electricians(
  p_service_area text,
  p_issue_category text,
  p_latitude double precision default null,
  p_longitude double precision default null,
  p_limit integer default 5
) returns table (
  electrician_id uuid,
  profile_id uuid,
  full_name text,
  phone text,
  avatar_url text,
  service_areas text[],
  years_experience integer,
  average_rating numeric,
  completed_jobs integer,
  availability_status text,
  distance_km numeric,
  average_response_seconds numeric,
  last_assigned_at timestamptz,
  level_badge text,
  watchlist boolean,
  negative_rating_count integer,
  level_rank integer
)
language sql
security definer
set search_path = public
as $$
  with latest_settings as (
    select
      coalesce((ranking_weights ->> 'max_distance_km')::numeric, 25) as max_distance_km,
      coalesce((trust_settings ->> 'watchlist_rank_penalty_km')::numeric, 8) as watchlist_rank_penalty_km
    from public.admin_settings
    order by updated_at desc
    limit 1
  ),
  settings as (
    select * from latest_settings
    union all
    select 25::numeric, 8::numeric
    where not exists (select 1 from latest_settings)
  ),
  ranked as (
    select
      e.id as electrician_id,
      e.profile_id,
      p.full_name,
      p.phone,
      p.avatar_url,
      e.service_areas,
      e.years_experience,
      e.average_rating,
      e.completed_jobs,
      e.availability_status,
      case
        when p_latitude is null or p_longitude is null or e.latitude is null or e.longitude is null then 999
        else (
          6371 * acos(
            least(1, greatest(-1,
              cos(radians(p_latitude)) * cos(radians(e.latitude)) * cos(radians(e.longitude) - radians(p_longitude)) +
              sin(radians(p_latitude)) * sin(radians(e.latitude))
            ))
          )
        )
      end as distance_km,
      (
        select round(avg(extract(epoch from (j.accepted_at - j.last_dispatch_at)))::numeric, 2)
        from public.jobs j
        where j.assigned_electrician_id = e.id
          and j.accepted_at is not null
          and j.last_dispatch_at is not null
          and j.accepted_at >= j.last_dispatch_at
      ) as average_response_seconds,
      e.last_offered_at as last_assigned_at,
      e.level_badge,
      e.watchlist,
      e.negative_rating_count,
      public.electrician_level_rank(e.level_badge) as level_rank,
      settings.watchlist_rank_penalty_km
    from public.electricians e
    join public.profiles p on p.id = e.profile_id
    cross join settings
    where e.status = 'approved'
      and e.availability_status = 'available'
      and exists (
        select 1
        from public.electrician_skills s
        where s.electrician_id = e.id
          and lower(trim(s.category)) = lower(trim(p_issue_category))
      )
      and (
        p_service_area is null
        or exists (
          select 1
          from unnest(e.service_areas) as area
          where lower(regexp_replace(trim(area), '\s+', ' ', 'g')) = lower(regexp_replace(trim(p_service_area), '\s+', ' ', 'g'))
             or lower(regexp_replace(trim(p_service_area), '\s+', ' ', 'g')) like '%' || lower(regexp_replace(trim(area), '\s+', ' ', 'g')) || '%'
             or lower(regexp_replace(trim(area), '\s+', ' ', 'g')) like '%' || lower(regexp_replace(trim(p_service_area), '\s+', ' ', 'g')) || '%'
        )
        or (
          p_latitude is not null
          and p_longitude is not null
          and e.latitude is not null
          and e.longitude is not null
          and (
            6371 * acos(
              least(1, greatest(-1,
                cos(radians(p_latitude)) * cos(radians(e.latitude)) * cos(radians(e.longitude) - radians(p_longitude)) +
                sin(radians(p_latitude)) * sin(radians(e.latitude))
              ))
            )
          ) <= coalesce(nullif(e.service_radius_km, 0), settings.max_distance_km)
        )
      )
  )
  select
    electrician_id,
    profile_id,
    full_name,
    phone,
    avatar_url,
    service_areas,
    years_experience,
    average_rating,
    completed_jobs,
    availability_status,
    round(distance_km::numeric, 2) as distance_km,
    average_response_seconds,
    last_assigned_at,
    level_badge,
    watchlist,
    negative_rating_count,
    level_rank
  from ranked
  order by
    distance_km asc,
    watchlist asc,
    negative_rating_count asc,
    level_rank desc,
    average_rating desc,
    completed_jobs desc
  limit p_limit;
$$;

revoke all on function public.find_matching_electricians(text,text,double precision,double precision,integer) from public, anon, authenticated;
grant execute on function public.find_matching_electricians(text,text,double precision,double precision,integer) to authenticated, service_role;
