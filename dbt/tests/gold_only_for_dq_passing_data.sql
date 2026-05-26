{# Singular test: fail when Gold contains a trip_date whose underlying (source_year, source_month) #}
{# partition is currently failing Glue DQ AND has not been quarantined. Once quarantined, the      #}
{# partition is removed from Silver via the post-hook DELETE, so Gold won't have rows for it.      #}

with latest_run as (
  select
    result_id,
    state,
    rules_failed,
    row_number() over (order by event_time desc) as rn
  from {{ source('citibike_observability', 'citibike_glue_dq_run_events') }}
  where table_name = 'citibike_trips_silver'
),

current_run as (
  select * from latest_run where rn = 1
)

select
  g.trip_date,
  g.source_year,
  g.source_month,
  cr.state,
  cr.rules_failed
from {{ ref('citibike_daily_ridership_gold') }} g
cross join current_run cr
left join {{ ref('citibike_quarantine_filter') }} qf
       on qf.source_year = g.source_year
      and qf.source_month = g.source_month
where (
  cr.state <> 'SUCCEEDED'
  or coalesce(cr.rules_failed, 0) > 0
)
  and qf.source_year is null
