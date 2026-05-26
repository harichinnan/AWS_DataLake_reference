{{
  config(
    materialized='view'
  )
}}

select
  source_year,
  source_month,
  max(quarantined_at) as latest_quarantined_at,
  max(run_id)         as latest_run_id,
  max(result_id)      as latest_result_id
from {{ source('citibike_observability', 'citibike_quarantined_partitions') }}
where cleared_at is null
group by source_year, source_month
