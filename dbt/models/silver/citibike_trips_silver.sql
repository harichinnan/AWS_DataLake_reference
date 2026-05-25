{{
  config(
    materialized='incremental',
    table_type='iceberg',
    incremental_strategy='merge',
    unique_key='ride_id',
    partitioned_by=['month(started_at)'],
    on_schema_change='sync_all_columns',
    table_properties={
      'optimize_rewrite_delete_file_threshold': '2'
    }
  )
}}

with typed as (
  select
    nullif(trim(ride_id), '') as ride_id,
    lower(nullif(trim(rideable_type), '')) as rideable_type,
    try_cast(started_at as timestamp) as started_at,
    try_cast(ended_at as timestamp) as ended_at,
    nullif(trim(start_station_name), '') as start_station_name,
    nullif(trim(start_station_id), '') as start_station_id,
    nullif(trim(end_station_name), '') as end_station_name,
    nullif(trim(end_station_id), '') as end_station_id,
    try_cast(start_lat as double) as start_lat,
    try_cast(start_lng as double) as start_lng,
    try_cast(end_lat as double) as end_lat,
    try_cast(end_lng as double) as end_lng,
    lower(nullif(trim(member_casual), '')) as member_casual,
    year as source_year,
    month as source_month
  from {{ source('citibike_raw', 'citibike_trips_raw') }}
  where ride_id is not null
    and trim(ride_id) <> ''
    and year >= '{{ var("citibike_start_year", "2026") }}'
    and date(try_cast(started_at as timestamp)) >= date '{{ var("citibike_start_date", "2026-01-01") }}'
),

ranked as (
  select
    *,
    row_number() over (
      partition by ride_id
      order by started_at desc, source_year desc, source_month desc
    ) as ride_row_number
  from typed
)

select
  ride_id,
  rideable_type,
  started_at,
  ended_at,
  date_diff('second', started_at, ended_at) as duration_seconds,
  coalesce(
    date_diff('second', started_at, ended_at) > 0
    and date_diff('second', started_at, ended_at) <= 86400,
    false
  ) as is_valid_duration,
  start_station_name,
  start_station_id,
  end_station_name,
  end_station_id,
  start_lat,
  start_lng,
  end_lat,
  end_lng,
  member_casual,
  cast(started_at as date) as trip_date,
  hour(started_at) as started_hour,
  day_of_week(started_at) as day_of_week,
  coalesce(member_casual = 'member', false) as is_member,
  coalesce(rideable_type = 'electric_bike', false) as is_electric,
  source_year,
  source_month,
  cast(current_timestamp as timestamp) as loaded_at
from ranked
where ride_row_number = 1
  and started_at is not null
  and ended_at is not null
