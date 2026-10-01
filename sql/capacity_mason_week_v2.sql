-- =============================================================================
-- raw_data_from_salesforce.capacity_mason_week_v2(p_country, p_level, p_name, p_start, p_end, p_weeks)
--
-- The individual masons list of the country workspaces: one row per mason for
-- one place (a territory, district or branch, or the whole country) over one
-- period. A second version beside capacity_mason_week, which the Classic
-- toolkit's deep dive still reads and which is never changed.
--
-- The period is the calendar weeks of capacity_week (days 1-7, 8-14, 15-21,
-- 22 to month end) between p_start and p_end whose number is in p_weeks
-- ('12', '1234' ...), or every week of the quarter when p_weeks is 'Q'. So a
-- month with weeks 1 and 3 selected, or a whole quarter, is one call:
--   capacity_mason_week_v2('Rwanda', 'territory', 'Bugesera A', DATE '2026-09-01', DATE '2026-09-21', '123')
--   capacity_mason_week_v2('Uganda', 'country', 'Uganda', DATE '2026-07-01', DATE '2026-09-30', 'Q')
--
-- Per mason:
--   status            Working when they had a timesheet starting in the period
--                     or completed a build in it; Assigned, not started when
--                     they hold a live job at the period's end and no
--                     timesheet in it.
--   builds_completed  phase 1 jobs completed in the period (one per house);
--   sqme_completed    SQM-E of every phase completed in the period, Floor plus
--                     Plaster only (the scored products; product_class()).
--   revenue           contract value (total_amount) of every phase completed
--                     in the period: the mason's share of the live revenue
--                     figure (sql/completed_value_daily.sql). Local currency.
--   builds_on_time    all_opportunities_master.build_on_time on those jobs.
--   sqme_in_hand      SQM-E of the jobs assigned to them that became buildable
--                     in the 90 days to the period's end and were not finished
--                     by then: what they still have to build.
--   time_needed_weeks sqme_in_hand / weekly_rate.
--   weekly_rate       THE STANDARD, provisional: the unit's next-month SQM-E
--                     target over its mason requirement gives the monthly
--                     SQM-E one mason should build; over weeks_per_month
--                     (4.33, in params) it is the weekly rate. Derived from the
--                     targets already in the tables, one line to change.
--   earnings          approved gross pay by end date in the period, the bonus
--                     basis; is_productive when it met the country's weekly
--                     bar times the Wednesdays in the period.
--   weeks             the last five calendar weeks up to the period's end,
--                     rolling across month ends, each scored on the same rule,
--                     for the form guide. is_selected marks the period's own weeks.
--   qa_measured, qa_passed   the skills proxy: first QA checks (compaction,
--                     screed, prior paint) on the mason's jobs in the 90 days
--                     to the period's end, a job passing when none of its
--                     first checks was a non-pass. Lives in the `skills` CTE
--                     alone, so a real training source can replace it there
--                     without touching the page.
--
-- Where a mason's line sits follows capacity_week_v2 exactly. Their `unit` is
-- where most of their timesheets in the period were, else where they built,
-- else where their live job is.
--
-- Deploy: run this file in the BigQuery console or through the connector. The
-- app ships the same body inline (src/generated/sql.ts) until then.
-- =============================================================================

CREATE OR REPLACE TABLE FUNCTION `earth-enable-main.raw_data_from_salesforce.capacity_mason_week_v2`(
  p_country STRING, p_level STRING, p_name STRING, p_start DATE, p_end DATE, p_weeks STRING)
AS (
WITH
-- Rwanda's territory targets, with the Nyagatare rule applied (see below).
tl_targets AS (
  SELECT month, territory, district, n_territories, sqme_target, build_target, min_productive_masons, min_build_productivity, manager FROM `earth-enable-main.raw_data_from_salesforce.tl_bonus_targets`
  WHERE NOT (territory IN ('Nyagatare A', 'Nyagatare B', 'Nyagatare C') AND month >= DATE '2026-09-01')
  UNION ALL
  -- From September 2026 the Nyagatare district target (the official A + B) is
  -- shared B one half, A one quarter, C one quarter (regional manager,
  -- 2026-09-29). Nothing is added: district and country totals stay official.
  -- Before that, A and B keep their rows and C has no target.
  SELECT d.month, s.territory, d.district, 3 AS n_territories,
    d.sqme_target * s.share, d.build_target * s.share, d.min_productive_masons * s.share,
    d.min_build_productivity, d.manager
  FROM (
    SELECT month, ANY_VALUE(district) AS district, ANY_VALUE(manager) AS manager,
      SUM(sqme_target) AS sqme_target, SUM(build_target) AS build_target,
      SUM(min_productive_masons) AS min_productive_masons, ANY_VALUE(min_build_productivity) AS min_build_productivity
    FROM `earth-enable-main.raw_data_from_salesforce.tl_bonus_targets`
    WHERE territory IN ('Nyagatare A', 'Nyagatare B') AND month >= DATE '2026-09-01'
    GROUP BY month
  ) d
  CROSS JOIN UNNEST([STRUCT('Nyagatare A' AS territory, 0.25 AS share), ('Nyagatare B', 0.5), ('Nyagatare C', 0.25)]) s
),
params AS (
  SELECT
    4.33 AS weeks_per_month,   -- THE STANDARD's divisor: monthly SQM-E per mason over this many weeks is the weekly rate
    90   AS onsite_days,       -- a job is live for this long after it became buildable
    90   AS skills_days,       -- QA checks in this many days to the period's end make the skills proxy
    5    AS form_weeks,        -- weeks on the form guide
    DATE_TRUNC(p_start, MONTH) AS period_month_from,
    DATE_TRUNC(LEAST(p_end, CURRENT_DATE()), MONTH) AS period_month_to,
    LEAST(p_end, CURRENT_DATE()) AS period_end,
    -- The form guide reaches back two months so five weeks always exist.
    DATE_TRUNC(DATE_SUB(p_start, INTERVAL 2 MONTH), MONTH) AS spine_from
),

country_rules AS (
  SELECT * FROM UNNEST([
    STRUCT('Rwanda' AS country, 25000.0 AS weekly_threshold, 'RWF' AS currency),
    STRUCT('Uganda', 62500.0, 'UGX'),
    STRUCT('Kenya', 2500.0, 'KES')
  ])
  WHERE p_country IS NULL OR country = p_country
),

dim AS (
  SELECT 'Rwanda' AS country, 'territory' AS unit_level, territory AS unit, d.district AS parent
  FROM (
    SELECT territory,
      ARRAY_AGG(STRUCT(COALESCE(district, 'Unknown') AS district) ORDER BY month DESC LIMIT 1)[OFFSET(0)] AS d
    FROM tl_targets
    WHERE territory IS NOT NULL
    GROUP BY 1
  )
  UNION ALL
  SELECT DISTINCT country, 'branch', branch, CAST(NULL AS STRING)
  FROM `earth-enable-main.raw_data_from_salesforce.branch_capacity_targets`
),

-- The place asked for, as the units under it.
members AS (
  SELECT * FROM (
    SELECT country, unit_level AS level, unit AS name, unit, parent FROM dim
    UNION ALL SELECT country, 'district', parent, unit, parent FROM dim WHERE unit_level = 'territory'
    UNION ALL SELECT country, 'country', country, unit, parent FROM dim
  )
  WHERE (p_country IS NULL OR country = p_country)
    AND (p_level IS NULL OR level = p_level) AND (p_name IS NULL OR name = p_name)
),

-- The unit's standard: the SQM-E target of the month the period ends in, over
-- its mason requirement, as a weekly rate.
unit_rate AS (
  SELECT t.country, t.unit,
    SAFE_DIVIDE(SAFE_DIVIDE(t.sqme_target, NULLIF(t.min_productive_masons, 0)), p.weeks_per_month) AS weekly_rate
  FROM (
    SELECT 'Rwanda' AS country, territory AS unit, month, sqme_target, min_productive_masons
    FROM tl_targets WHERE territory IS NOT NULL
    UNION ALL
    SELECT country, branch, month, sqme_target, min_productive_masons
    FROM `earth-enable-main.raw_data_from_salesforce.branch_capacity_targets`
  ) t
  CROSS JOIN params p
  WHERE t.month = p.period_month_to
),

-- Calendar weeks from two months before the period to its end, flagged as
-- selected (in the period) or not, with the form guide's five weeks marked.
calendar AS (
  SELECT *,
    ROW_NUMBER() OVER (ORDER BY week_start DESC) <= (SELECT form_weeks FROM params) AS on_form
  FROM (
    SELECT c.month, c.week_no, c.week_start, LEAST(c.week_end, CURRENT_DATE()) AS week_end_capped, c.week_end,
      (SELECT COUNTIF(EXTRACT(DAYOFWEEK FROM d) = 4) FROM UNNEST(GENERATE_DATE_ARRAY(c.week_start, c.week_end)) d) AS wednesdays,
      c.week_end < CURRENT_DATE() AS is_complete,
      c.month BETWEEN p.period_month_from AND p.period_month_to
        AND c.week_start <= p.period_end
        AND (p_weeks = 'Q' OR CAST(c.week_no AS STRING) IN UNNEST(REGEXP_EXTRACT_ALL(p_weeks, r'\d'))) AS is_selected
    FROM params p,
      UNNEST(GENERATE_DATE_ARRAY(p.spine_from, p.period_month_to, INTERVAL 1 MONTH)) mth,
      UNNEST([1, 2, 3, 4]) w,
      UNNEST([STRUCT(mth AS month, w AS week_no,
        DATE_ADD(mth, INTERVAL (w - 1) * 7 DAY) AS week_start,
        IF(w = 4, LAST_DAY(mth), DATE_ADD(mth, INTERVAL w * 7 - 1 DAY)) AS week_end)]) c
    WHERE c.week_start <= p.period_end
  )
  -- The form guide ends at the period's last selected week, so drop later weeks.
  WHERE week_start <= (SELECT MAX(IF(is_sel, ws, NULL)) FROM (
      SELECT DATE_ADD(mth, INTERVAL (w - 1) * 7 DAY) AS ws,
        mth BETWEEN p.period_month_from AND p.period_month_to
          AND DATE_ADD(mth, INTERVAL (w - 1) * 7 DAY) <= p.period_end
          AND (p_weeks = 'Q' OR CAST(w AS STRING) IN UNNEST(REGEXP_EXTRACT_ALL(p_weeks, r'\d'))) AS is_sel
      FROM params p, UNNEST(GENERATE_DATE_ARRAY(p.spine_from, p.period_month_to, INTERVAL 1 MONTH)) mth, UNNEST([1, 2, 3, 4]) w))
),

period AS (
  SELECT MIN(IF(is_selected, week_start, NULL)) AS period_start,
    MAX(IF(is_selected, week_end_capped, NULL)) AS period_end,
    SUM(IF(is_selected, wednesdays, 0)) AS wednesdays,
    MIN(week_start) AS scan_from
  FROM calendar
),

-- Timesheet lines in the window, placed in their unit and kept for the place.
line_events AS (
  SELECT m.country, m.unit, m.parent, t.mason_id, t.mason AS mason_name, e.kind, e.d, e.amount
  FROM `earth-enable-main.raw_data_from_salesforce.mason_timesheet_readable` t
  CROSS JOIN period w
  LEFT JOIN `earth-enable-main.salesforce.location_c` l ON l.id = t.location_id AND t.country != 'Rwanda'
  LEFT JOIN dim du ON du.country = t.country AND du.unit = t.district AND du.unit_level = 'branch'
  JOIN members m ON m.country = t.country
    AND m.unit = IF(t.country = 'Rwanda', t.territory, COALESCE(NULLIF(TRIM(l.branch_c), ''), du.unit)),
    UNNEST([STRUCT('ts' AS kind, t.start_date AS d, 0.0 AS amount,
                   t.start_date BETWEEN w.scan_from AND w.period_end AS ok),
            STRUCT('pay', t.end_date, IFNULL(t.amount_of_payment, 0.0),
                   NOT t.is_deleted AND t.status = 'Approved' AND t.end_date BETWEEN w.scan_from AND w.period_end)]) e
  WHERE t.country IN ('Rwanda', 'Uganda', 'Kenya')
    AND (p_country IS NULL OR t.country = p_country)
    AND NOT t.fivetran_deleted AND t.mason_id IS NOT NULL
    AND (t.start_date BETWEEN w.scan_from AND w.period_end OR t.end_date BETWEEN w.scan_from AND w.period_end)
    AND e.ok
),

-- Per mason x week from the lines.
lines_week AS (
  SELECT e.country, e.mason_id, c.week_start,
    COUNTIF(e.kind = 'ts') AS timesheets,
    SUM(IF(e.kind = 'pay', e.amount, 0)) AS earnings,
    ARRAY_AGG(e.mason_name IGNORE NULLS ORDER BY e.d DESC LIMIT 1)[SAFE_OFFSET(0)] AS mason_name,
    MAX(e.d) AS last_seen
  FROM line_events e
  JOIN calendar c ON e.d BETWEEN c.week_start AND c.week_end
  GROUP BY 1, 2, 3
),

-- The unit with most of the mason's timesheets in the period.
ts_unit AS (
  SELECT country, mason_id, unit, parent
  FROM (
    SELECT e.country, e.mason_id, e.unit, e.parent, COUNT(*) AS n
    FROM line_events e
    JOIN calendar c ON e.d BETWEEN c.week_start AND c.week_end AND c.is_selected
    WHERE e.kind = 'ts'
    GROUP BY 1, 2, 3, 4
  )
  QUALIFY ROW_NUMBER() OVER (PARTITION BY country, mason_id ORDER BY n DESC, unit) = 1
),

-- The mason's jobs: completed in the period, or in hand at its end. Placed
-- like capacity_week_v2 and kept for the place.
jobs AS (
  SELECT m.country, m.unit, m.parent, x.mason_id, x.opportunity_id, x.is_job, x.sqme, x.total_amount, x.completed_date, x.build_on_time,
    x.completed_date BETWEEN w.period_start AND w.period_end AS done_in_period,
    x.mason_id IS NOT NULL
      AND x.buildable_date BETWEEN DATE_SUB(w.period_end, INTERVAL p.onsite_days DAY) AND w.period_end
      AND (x.completed_date IS NULL OR x.completed_date > w.period_end)
      AND COALESCE(x.stage, '') != 'Closed Lost' AS in_hand
  FROM (
    SELECT
      mo.location_country AS country,
      CASE mo.location_country
        WHEN 'Rwanda' THEN mo.location_territory
        WHEN 'Uganda' THEN COALESCE(NULLIF(TRIM(l.branch_c), ''), REGEXP_EXTRACT(mo.branch, r'^(.+) Branch$'))
        WHEN 'Kenya' THEN COALESCE(NULLIF(TRIM(l.branch_c), ''), NULLIF(TRIM(l.district_c), ''), mo.location_district)
      END AS unit,
      mo.mason_id, mo.opportunity_id,
      SAFE_CAST(mo.opportunity_phase AS INT64) = 1 AS is_job,
      -- Scored SQM-E: Floor plus Plaster only; paint and the rest carry no SQM-E here.
      IF(pc.product IN ('Floor', 'Plaster'), IFNULL(mo.adjusted_square_meters, 0), 0) AS sqme,
      IFNULL(mo.total_amount, 0) AS total_amount,
      mo.completed_date, mo.build_on_time, mo.opportunity_stage AS stage,
      COALESCE(IF(pc.product = 'Floor', COALESCE(mo.date_50pct_paid, mo.date_100pct_paid), mo.date_100pct_paid),
               mo.customer_signed_date) AS buildable_date
    FROM `earth-enable-main.raw_data_from_salesforce.all_opportunities_master` mo
    CROSS JOIN period w
    CROSS JOIN params p
    LEFT JOIN `earth-enable-main.salesforce.location_c` l ON l.id = mo.location_id AND mo.location_country != 'Rwanda'
    -- The Contractor record type is out of every count, as in capacity_week_v2 and completed_value_daily.
    LEFT JOIN (
      SELECT o.id FROM `earth-enable-main.salesforce.opportunity` o
      JOIN `earth-enable-main.salesforce.record_type` rt ON rt.id = o.record_type_id
      WHERE rt.name = 'Contractor'
    ) ct ON ct.id = mo.opportunity_id,
    UNNEST([STRUCT(`earth-enable-main.raw_data_from_salesforce.product_class`(COALESCE(mo.product_interest, mo.new_product_interest)) AS product)]) AS pc
    WHERE mo.location_country IN ('Rwanda', 'Uganda', 'Kenya')
      AND (p_country IS NULL OR mo.location_country = p_country)
      AND pc.product != 'House'
      AND ct.id IS NULL
      AND mo.mason_id IS NOT NULL
      AND (mo.completed_date BETWEEN w.period_start AND w.period_end
           OR COALESCE(IF(pc.product = 'Floor', COALESCE(mo.date_50pct_paid, mo.date_100pct_paid), mo.date_100pct_paid),
                       mo.customer_signed_date) >= DATE_SUB(w.period_end, INTERVAL p.onsite_days DAY))
  ) x
  CROSS JOIN period w
  CROSS JOIN params p
  JOIN members m ON m.country = x.country AND m.unit = x.unit
),

jobs_by_mason AS (
  SELECT country, mason_id,
    COUNTIF(done_in_period AND is_job) AS builds_completed,
    SUM(IF(done_in_period, sqme, 0)) AS sqme_completed,
    SUM(IF(done_in_period, total_amount, 0)) AS revenue,
    COUNTIF(done_in_period AND is_job AND build_on_time = 1) AS builds_on_time,
    COUNTIF(done_in_period AND is_job AND build_on_time = 0) AS builds_late,
    COUNTIF(in_hand AND is_job) AS jobs_in_hand,
    SUM(IF(in_hand, sqme, 0)) AS sqme_in_hand,
    ARRAY_AGG(IF(done_in_period, STRUCT(unit, parent), NULL) IGNORE NULLS LIMIT 1)[SAFE_OFFSET(0)] AS built_unit,
    ARRAY_AGG(IF(in_hand, STRUCT(unit, parent), NULL) IGNORE NULLS LIMIT 1)[SAFE_OFFSET(0)] AS hand_unit
  FROM jobs
  WHERE done_in_period OR in_hand
  GROUP BY 1, 2
),

-- The skills proxy. Replace this CTE alone when a training source exists.
skills AS (
  SELECT j.country, j.mason_id,
    COUNT(*) AS qa_measured,
    COUNTIF(q.qa_passed) AS qa_passed
  FROM (
    SELECT opportunity_id, MIN(eval_date) AS qa_date, COUNTIF(decision_c IS DISTINCT FROM 'Pass') = 0 AS qa_passed
    FROM (
      SELECT q.opportunity_name_c AS opportunity_id, q.date_c AS eval_date, q.decision_c,
        ROW_NUMBER() OVER (PARTITION BY q.opportunity_name_c,
          CASE WHEN rt.name LIKE 'Compaction%' THEN 'Compaction' WHEN rt.name LIKE 'Screed%' THEN 'Screed' ELSE 'PriorPaint' END
          ORDER BY q.date_c, q.created_date) AS rn
      FROM `earth-enable-main.salesforce.quality_assurance_survey_c` q
      JOIN `earth-enable-main.salesforce.record_type` rt ON rt.id = q.record_type_id
      CROSS JOIN period w
      CROSS JOIN params p
      WHERE NOT q._fivetran_deleted AND NOT COALESCE(q.is_deleted, FALSE)
        AND q.opportunity_name_c IS NOT NULL AND q.date_c IS NOT NULL
        AND q.date_c BETWEEN DATE_SUB(w.period_end, INTERVAL p.skills_days + 180 DAY) AND w.period_end
        AND (rt.name LIKE 'Compaction%' OR rt.name LIKE 'Screed%' OR rt.name LIKE 'Prior Paint%')
        AND q.type_c IS NOT NULL
        AND REGEXP_CONTAINS(q.type_c, r'(?i)quality|QA|Auditor')
        AND NOT REGEXP_CONTAINS(q.type_c, r'(?i)R&D')
    )
    WHERE rn = 1
    GROUP BY 1
  ) q
  JOIN (
    SELECT mo.opportunity_id, mo.location_country AS country, mo.mason_id
    FROM `earth-enable-main.raw_data_from_salesforce.all_opportunities_master` mo
    WHERE mo.mason_id IS NOT NULL AND (p_country IS NULL OR mo.location_country = p_country)
  ) j ON j.opportunity_id = q.opportunity_id
  CROSS JOIN period w
  CROSS JOIN params p
  WHERE q.qa_date BETWEEN DATE_SUB(w.period_end, INTERVAL p.skills_days DAY) AND w.period_end
  GROUP BY 1, 2
),

-- One row per mason: the period's totals and the form guide.
masons AS (
  SELECT
    COALESCE(lw.country, jb.country) AS country,
    COALESCE(lw.mason_id, jb.mason_id) AS mason_id,
    lw.mason_name, lw.last_seen,
    lw.timesheets, lw.earnings, lw.weeks,
    STRUCT(tu.unit, tu.parent) AS ts_unit,
    jb.builds_completed, jb.sqme_completed, jb.revenue, jb.builds_on_time, jb.builds_late, jb.jobs_in_hand, jb.sqme_in_hand,
    jb.built_unit, jb.hand_unit
  FROM (
    SELECT lw.country, lw.mason_id,
      ARRAY_AGG(lw.mason_name IGNORE NULLS ORDER BY lw.last_seen DESC LIMIT 1)[SAFE_OFFSET(0)] AS mason_name,
      MAX(lw.last_seen) AS last_seen,
      SUM(IF(c.is_selected, lw.timesheets, 0)) AS timesheets,
      SUM(IF(c.is_selected, lw.earnings, 0)) AS earnings,
      ARRAY_AGG(IF(c.on_form, STRUCT(c.week_start, c.week_end, lw.earnings, c.wednesdays, c.is_complete, c.is_selected), NULL) IGNORE NULLS) AS weeks
    FROM lines_week lw
    JOIN calendar c ON c.week_start = lw.week_start
    GROUP BY 1, 2
  ) lw
  FULL OUTER JOIN jobs_by_mason jb ON jb.country = lw.country AND jb.mason_id = lw.mason_id
  LEFT JOIN ts_unit tu ON tu.country = COALESCE(lw.country, jb.country) AND tu.mason_id = COALESCE(lw.mason_id, jb.mason_id)
)

SELECT
  m.country,
  p_level AS level, p_name AS name,
  m.mason_id,
  COALESCE(m.mason_name, mn.mason_name, m.mason_id) AS mason_name,
  COALESCE(m.ts_unit.unit, m.built_unit.unit, m.hand_unit.unit) AS unit,
  COALESCE(m.ts_unit.parent, m.built_unit.parent, m.hand_unit.parent) AS unit_parent,
  IF(IFNULL(m.timesheets, 0) > 0 OR IFNULL(m.builds_completed, 0) > 0, 'Working', 'Assigned, not started') AS status,
  IFNULL(m.timesheets, 0) AS timesheets,
  IFNULL(m.builds_completed, 0) AS builds_completed,
  IFNULL(m.sqme_completed, 0) AS sqme_completed,
  IFNULL(m.revenue, 0) AS revenue,
  IFNULL(m.builds_on_time, 0) AS builds_on_time,
  IFNULL(m.builds_late, 0) AS builds_late,
  SAFE_DIVIDE(m.builds_on_time, NULLIF(m.builds_on_time + m.builds_late, 0)) AS pct_on_time,
  IFNULL(m.jobs_in_hand, 0) AS jobs_in_hand,
  IFNULL(m.sqme_in_hand, 0) AS sqme_in_hand,
  ur.weekly_rate,
  SAFE_DIVIDE(m.sqme_in_hand, NULLIF(ur.weekly_rate, 0)) AS time_needed_weeks,
  IFNULL(m.earnings, 0) AS earnings,
  cr.currency, cr.weekly_threshold,
  cr.weekly_threshold * w.wednesdays AS threshold,
  SAFE_DIVIDE(m.earnings, cr.weekly_threshold * w.wednesdays) AS pct_of_threshold,
  IFNULL(m.earnings, 0) >= cr.weekly_threshold * w.wednesdays AS is_productive,
  ARRAY(
    SELECT AS STRUCT c.week_start, c.week_end,
      CONCAT('W', CAST(c.week_no AS STRING), ' ', FORMAT_DATE('%b', c.week_end)) AS week_label,
      c.is_complete, c.is_selected,
      IFNULL(wk.earnings, 0) AS earnings,
      cr.weekly_threshold * c.wednesdays AS threshold,
      SAFE_DIVIDE(wk.earnings, cr.weekly_threshold * c.wednesdays) AS pct_of_threshold,
      IFNULL(wk.earnings, 0) >= cr.weekly_threshold * c.wednesdays AS is_productive
    FROM calendar c
    LEFT JOIN UNNEST(m.weeks) wk ON wk.week_start = c.week_start
    WHERE c.on_form
    ORDER BY c.week_start
  ) AS weeks,
  IFNULL(sk.qa_measured, 0) AS qa_measured,
  IFNULL(sk.qa_passed, 0) AS qa_passed,
  SAFE_DIVIDE(sk.qa_passed, NULLIF(sk.qa_measured, 0)) AS pct_qa_pass,
  w.period_start, w.period_end, w.wednesdays,
  CURRENT_TIMESTAMP() AS built_at
FROM masons m
CROSS JOIN period w
JOIN country_rules cr ON cr.country = m.country
LEFT JOIN unit_rate ur ON ur.country = m.country AND ur.unit = COALESCE(m.ts_unit.unit, m.built_unit.unit, m.hand_unit.unit)
LEFT JOIN skills sk ON sk.country = m.country AND sk.mason_id = m.mason_id
LEFT JOIN (
  SELECT mason_id, ARRAY_AGG(mason_name IGNORE NULLS ORDER BY completed_date DESC LIMIT 1)[SAFE_OFFSET(0)] AS mason_name
  FROM `earth-enable-main.raw_data_from_salesforce.all_opportunities_master`
  WHERE mason_id IS NOT NULL AND (p_country IS NULL OR location_country = p_country)
  GROUP BY 1
) mn ON mn.mason_id = m.mason_id
WHERE m.timesheets > 0 OR m.builds_completed > 0 OR m.jobs_in_hand > 0
);
