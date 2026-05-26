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
        'domain': 'trips',
        'layer': 'gold',
        'pii_level': 'none',
        'freshness_tier': 'daily'
      }
    }
  )
}}

select
  trip_date,
  cast(year(trip_date) as varchar) as source_year,
  lpad(cast(month(trip_date) as varchar), 2, '0') as source_month,
  count(*) as total_rides,
  count_if(is_valid_duration) as valid_duration_rides,
  count_if(member_casual = 'member') as member_rides,
  count_if(member_casual = 'casual') as casual_rides,
  count_if(rideable_type = 'electric_bike') as electric_bike_rides,
  count_if(rideable_type = 'classic_bike') as classic_bike_rides,
  approx_distinct(start_station_id) as unique_start_stations,
  approx_distinct(end_station_id) as unique_end_stations,
  avg(if(is_valid_duration, cast(duration_seconds as double), null)) as average_duration_seconds,
  approx_percentile(if(is_valid_duration, cast(duration_seconds as double), null), 0.5) as median_duration_seconds,
  approx_percentile(if(is_valid_duration, cast(duration_seconds as double), null), 0.9) as p90_duration_seconds,
  sum(if(is_valid_duration, cast(duration_seconds as double), 0.0)) / 3600.0 as total_duration_hours,
  cast(current_timestamp as timestamp) as refreshed_at
from {{ ref('citibike_trips_silver') }}
where trip_date is not null
  and source_year >= '{{ var("citibike_start_year", "2026") }}'
group by trip_date
