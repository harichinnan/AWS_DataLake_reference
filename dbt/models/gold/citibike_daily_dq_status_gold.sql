{{
  config(
    materialized='view'
  )
}}

with latest_run as (
  select
    result_id,
    run_id,
    ruleset_name,
    state,
    score,
    rules_succeeded,
    rules_failed,
    rules_skipped,
    started_on,
    completed_on,
    event_time,
    row_number() over (order by event_time desc) as rn
  from {{ source('citibike_observability', 'citibike_glue_dq_run_events') }}
  where table_name = 'citibike_trips_silver'
),

current_run as (
  select * from latest_run where rn = 1
),

failing_rules as (
  select
    rr.result_id,
    array_agg(rr.rule_name order by rr.rule_name) as failing_rule_names,
    array_agg(coalesce(rr.evaluation_message, '') order by rr.rule_name) as failing_rule_messages
  from {{ source('citibike_observability', 'citibike_glue_dq_rule_results') }} rr
  inner join current_run cr on rr.result_id = cr.result_id
  where rr.rule_result <> 'PASS'
  group by rr.result_id
)

select
  g.trip_date,
  g.source_year,
  g.source_month,
  g.total_rides,
  g.member_rides,
  g.casual_rides,
  g.valid_duration_rides,
  cr.result_id              as latest_dq_result_id,
  cr.run_id                 as latest_dq_run_id,
  cr.ruleset_name           as latest_dq_ruleset_name,
  cr.state                  as latest_dq_state,
  cr.score                  as latest_dq_score,
  cr.rules_succeeded        as latest_dq_rules_succeeded,
  cr.rules_failed           as latest_dq_rules_failed,
  cr.rules_skipped          as latest_dq_rules_skipped,
  cr.started_on             as latest_dq_started_on,
  cr.completed_on           as latest_dq_completed_on,
  cr.event_time             as latest_dq_event_time,
  coalesce(fr.failing_rule_names, array[]) as latest_dq_failing_rule_names,
  coalesce(fr.failing_rule_messages, array[]) as latest_dq_failing_rule_messages,
  (cr.state = 'SUCCEEDED' and coalesce(cr.rules_failed, 0) = 0) as latest_dq_passed,
  (qf.source_year is not null) as quarantined,
  qf.latest_quarantined_at,
  qf.latest_run_id as quarantine_run_id
from {{ ref('citibike_daily_ridership_gold') }} g
left join current_run cr on true
left join failing_rules fr on fr.result_id = cr.result_id
left join {{ ref('citibike_quarantine_filter') }} qf
       on qf.source_year = g.source_year
      and qf.source_month = g.source_month
