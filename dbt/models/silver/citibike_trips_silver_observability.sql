{{
  config(
    materialized='incremental',
    table_type='iceberg',
    incremental_strategy='merge',
    unique_key='trip_date',
    unique_tmp_table_suffix=true,
    partitioned_by=['month(trip_date)'],
    on_schema_change='sync_all_columns',
    table_properties={
      'optimize_rewrite_delete_file_threshold': '2'
    },
    lf_tags_config={
      'enabled': true,
      'tags': {
        'domain': 'observability',
        'layer': 'silver',
        'pii_level': 'none',
        'freshness_tier': 'daily'
      }
    }
  )
}}

with silver as (
  select *
  from {{ ref('citibike_trips_silver') }}
  where trip_date is not null
  {% if is_incremental() %}
    and trip_date >= (
      select date_add(
        'day',
        -7,
        coalesce(max(trip_date), date '{{ var("citibike_start_date", "2026-01-01") }}')
      )
      from {{ this }}
    )
  {% endif %}
),

daily as (
  select
    trip_date,
    min(source_year) as source_year,
    min(source_month) as source_month,
    count(*) as total_rides,
    count(distinct ride_id) as distinct_ride_ids,
    count(*) - count(distinct ride_id) as duplicate_ride_ids,
    count_if(is_valid_duration) as valid_duration_rides,
    count_if(not is_valid_duration) as invalid_duration_rides,
    count_if(rideable_type = 'electric_bike') as electric_bike_rides,
    count_if(rideable_type = 'classic_bike') as classic_bike_rides,
    count_if(rideable_type is null or rideable_type not in ('electric_bike', 'classic_bike')) as invalid_rideable_type_rides,
    count_if(member_casual = 'member') as member_rides,
    count_if(member_casual = 'casual') as casual_rides,
    count_if(member_casual is null or member_casual not in ('member', 'casual')) as invalid_member_type_rides,
    count_if(start_station_id is null) as missing_start_station_id_rides,
    count_if(end_station_id is null) as missing_end_station_id_rides,
    count_if(start_station_id is null or end_station_id is null) as missing_station_rides,
    count_if(
      start_lat is null
      or start_lng is null
      or end_lat is null
      or end_lng is null
    ) as missing_geo_rides,
    count_if(
      start_lat not between 40.0 and 41.5
      or end_lat not between 40.0 and 41.5
      or start_lng not between -75.0 and -72.0
      or end_lng not between -75.0 and -72.0
    ) as out_of_bounds_geo_rides,
    min(started_at) as first_started_at,
    max(started_at) as last_started_at,
    min(loaded_at) as first_loaded_at,
    max(loaded_at) as last_loaded_at,
    min(duration_seconds) as min_duration_seconds,
    avg(if(is_valid_duration, cast(duration_seconds as double), null)) as average_valid_duration_seconds,
    approx_percentile(if(is_valid_duration, cast(duration_seconds as double), null), 0.5) as median_valid_duration_seconds,
    approx_percentile(if(is_valid_duration, cast(duration_seconds as double), null), 0.9) as p90_valid_duration_seconds,
    approx_percentile(if(is_valid_duration, cast(duration_seconds as double), null), 0.99) as p99_valid_duration_seconds,
    max(duration_seconds) as max_duration_seconds
  from silver
  group by trip_date
),

scored as (
  select
    *,
    cast(invalid_duration_rides as double) / nullif(total_rides, 0) as invalid_duration_rate,
    cast(missing_station_rides as double) / nullif(total_rides, 0) as missing_station_rate,
    cast(missing_geo_rides as double) / nullif(total_rides, 0) as missing_geo_rate,
    cast(out_of_bounds_geo_rides as double) / nullif(total_rides, 0) as out_of_bounds_geo_rate,
    cast(electric_bike_rides as double) / nullif(total_rides, 0) as electric_bike_rate,
    cast(member_rides as double) / nullif(total_rides, 0) as member_rate
  from daily
)

select
  trip_date,
  source_year,
  source_month,
  total_rides,
  distinct_ride_ids,
  duplicate_ride_ids,
  valid_duration_rides,
  invalid_duration_rides,
  invalid_duration_rate,
  electric_bike_rides,
  classic_bike_rides,
  invalid_rideable_type_rides,
  member_rides,
  casual_rides,
  invalid_member_type_rides,
  missing_start_station_id_rides,
  missing_end_station_id_rides,
  missing_station_rides,
  missing_station_rate,
  missing_geo_rides,
  missing_geo_rate,
  out_of_bounds_geo_rides,
  out_of_bounds_geo_rate,
  electric_bike_rate,
  member_rate,
  first_started_at,
  last_started_at,
  first_loaded_at,
  last_loaded_at,
  min_duration_seconds,
  average_valid_duration_seconds,
  median_valid_duration_seconds,
  p90_valid_duration_seconds,
  p99_valid_duration_seconds,
  max_duration_seconds,
  case
    when total_rides < {{ var('silver_observability_min_daily_rides', 1000) }}
      or duplicate_ride_ids > 0
      or invalid_rideable_type_rides > 0
      or invalid_member_type_rides > 0
      or invalid_duration_rate >= {{ var('silver_observability_fail_invalid_duration_rate', 0.02) }}
      or missing_station_rate >= {{ var('silver_observability_fail_missing_station_rate', 0.25) }}
      or missing_geo_rate >= {{ var('silver_observability_fail_missing_geo_rate', 0.10) }}
      or out_of_bounds_geo_rides > 0
      then 'fail'
    when invalid_duration_rate >= {{ var('silver_observability_warn_invalid_duration_rate', 0.005) }}
      or missing_station_rate >= {{ var('silver_observability_warn_missing_station_rate', 0.10) }}
      or missing_geo_rate >= {{ var('silver_observability_warn_missing_geo_rate', 0.02) }}
      then 'warn'
    else 'pass'
  end as quality_status,
  cast(current_timestamp as timestamp) as observed_at
from scored
