-- Mobile booking/admin operations fix:
-- - keep production service areas Port Harcourt focused
-- - make service-area matching case/spacing tolerant
-- - make matching work even if admin_settings has not been created yet

do $$
declare
  ph_areas text[] := array[
    'GRA, Port Harcourt',
    'Old GRA, Port Harcourt',
    'New GRA, Port Harcourt',
    'D-Line, Port Harcourt',
    'Trans Amadi, Port Harcourt',
    'Woji, Port Harcourt',
    'Rumuola, Port Harcourt',
    'Rumuokoro, Port Harcourt',
    'Rumuigbo, Port Harcourt',
    'Ada George, Port Harcourt',
    'Eliozu, Port Harcourt',
    'Elelenwo, Port Harcourt',
    'Mile 1, Port Harcourt',
    'Mile 3, Port Harcourt',
    'Choba, Port Harcourt'
  ];
begin
  insert into public.admin_settings (service_areas)
  select ph_areas
  where not exists (select 1 from public.admin_settings);

  update public.admin_settings
  set service_areas = ph_areas,
      updated_at = now()
  where coalesce(array_length(service_areas, 1), 0) = 0
    or (
      service_areas <@ array['Lekki Phase 1','Victoria Island','Ikeja','Surulere','Yaba','Ajah']::text[]
      and not exists (
        select 1
        from unnest(service_areas) as area
        where lower(area) like '%port harcourt%'
           or lower(area) like '%gra%'
      )
    );
end $$;

create or replace function public.find_matching_electricians(
  p_service_area text,
  p_issue_category text,
  p_latitude double precision default null,
  p_longitude double precision default null,
  p_limit integer default 5
)
returns table(
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
set search_path to 'public'
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
          ) <= settings.max_distance_km
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
    distance_km,
    average_response_seconds,
    last_assigned_at,
    level_badge,
    watchlist,
    negative_rating_count,
    level_rank
  from ranked
  order by
    (distance_km + case when watchlist then watchlist_rank_penalty_km else 0 end) asc,
    average_rating desc nulls last,
    completed_jobs desc,
    level_rank desc,
    average_response_seconds asc nulls last,
    coalesce(last_assigned_at, to_timestamp(0)) asc
  limit greatest(p_limit, 1);
$$;
