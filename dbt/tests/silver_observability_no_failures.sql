select
  trip_date,
  total_rides,
  duplicate_ride_ids,
  invalid_duration_rate,
  missing_station_rate,
  missing_geo_rate,
  out_of_bounds_geo_rides,
  invalid_rideable_type_rides,
  invalid_member_type_rides,
  quality_status
from {{ ref('citibike_trips_silver_observability') }}
where quality_status = 'fail'
