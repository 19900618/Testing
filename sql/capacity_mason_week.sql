-- =============================================================================
-- raw_data_from_salesforce.capacity_mason_week(p_level, p_name, p_week_end)
-- raw_data_from_salesforce.territory_mason_week_v1  = capacity_mason_week(NULL, NULL, NULL)
--
-- The mason roster behind the capacity planning deep dive, for Rwanda,
-- Uganda and Kenya. One row per country x level x name x mason x week, at
-- territory and district level for Rwanda and at branch level for Uganda and
-- Kenya, for weeks in which the mason had a timesheet, approved pay or a
-- completed build there. Same week windows as capacity_week (days 1-7, 8-14,
-- 15-21, 22 to month end). District rows add the mason's territories
-- together, so a mason working two territories in one district is one row at
-- district level.
--
-- A table function, computed on read, the same treatment as capacity_week.
-- The app calls it for one deep dive:
--   SELECT * FROM `earth-enable-main.raw_data_from_salesforce.capacity_mason_week`('territory', 'Bugesera A', DATE '2026-09-14')
-- and gets that place's masons for the weeks ending in the 45 days up to
-- p_week_end, which always covers five week windows. The place and the
-- window are pushed into the scans of the two raw tables, so only that
-- place's lines in the window are read, and each raw table is scanned once.
-- A call takes about 5 seconds. The view of the old name is the same
-- function called with NULLs: every place, 18 months back, for ad hoc use.
--
-- Productive is the company's own rule, copied from productive_masons_monthly
-- and the TL bonus, not a rule of this page:
--   earnings  = approved, not deleted, gross amount_of_payment, bucketed by end_date
--   threshold = the country's weekly threshold x the number of Wednesdays in the window
-- Weeks 1 to 3 always hold one Wednesday. Week 4 runs from day 22 to month end
-- and holds two in some months, so its bar doubles then. That is correct and
-- matches the bonus calculation.
--
-- Where a mason's line sits follows capacity_week exactly: Rwanda by
-- territory; Uganda by Salesforce's own branch field on the line's location;
-- Kenya's districts are its branches. Lines with no country, district or
-- opportunity resolve to no unit and are left out.
--
-- Deploy: paste this file into the BigQuery console (or the connector) and
-- run it. It creates the function and then the view over it.
-- =============================================================================

CREATE OR REPLACE TABLE FUNCTION `earth-enable-main.raw_data_from_salesforce.capacity_mason_week`(p_level STRING, p_name STRING, p_week_end DATE)
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
  -- The window. With p_week_end: the 45 days up to it, which always covers
  -- five week windows (the longest run of five is 38 days). Without: 18
  -- months back through today. Nothing older is scanned.
  SELECT
    COALESCE(DATE_TRUNC(DATE_SUB(p_week_end, INTERVAL 45 DAY), MONTH), DATE_TRUNC(DATE_SUB(CURRENT_DATE(), INTERVAL 18 MONTH), MONTH)) AS spine_from,
    LEAST(COALESCE(p_week_end, CURRENT_DATE()), CURRENT_DATE()) AS spine_to
),

-- Weekly productive thresholds in local currency, copied from
-- productive_masons_monthly. Change them there first.
thresholds AS (
  SELECT * FROM UNNEST([
    STRUCT('Rwanda' AS country, 25000.0 AS weekly_threshold, 'RWF' AS currency),
    STRUCT('Uganda', 62500.0, 'UGX'),
    STRUCT('Kenya', 2500.0, 'KES')
  ])
),

dim AS (
  SELECT 'Rwanda' AS country, 'territory' AS unit_level, territory AS unit, d.district
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

-- The place asked for (every place when the parameters are NULL), as the
-- levels it appears at and the units under it.
members AS (
  SELECT * FROM (
    SELECT country, unit_level AS level, unit AS name, unit FROM dim
    UNION ALL SELECT country, 'district', district, unit FROM dim WHERE unit_level = 'territory'
  )
  WHERE (p_level IS NULL OR level = p_level) AND (p_name IS NULL OR name = p_name)
),

-- Timesheet lines in the window, placed in their unit and kept only for the
-- place asked for. Each line becomes a Working event by start date and, if
-- approved, a pay event by end date, in one pass.
line_events AS (
  SELECT m.country, m.level, m.name, t.mason_id, t.mason AS mason_name, e.kind, e.d, e.amount
  FROM `earth-enable-main.raw_data_from_salesforce.mason_timesheet_readable` t
  CROSS JOIN params p
  LEFT JOIN `earth-enable-main.salesforce.location_c` l ON l.id = t.location_id AND t.country != 'Rwanda'
  LEFT JOIN dim du ON du.country = t.country AND du.unit = t.district AND du.unit_level = 'branch'
  JOIN members m ON m.country = t.country
    AND m.unit = IF(t.country = 'Rwanda', t.territory, COALESCE(NULLIF(TRIM(l.branch_c), ''), du.unit)),
    UNNEST([STRUCT('ts' AS kind, t.start_date AS d, 0.0 AS amount,
                   t.start_date BETWEEN p.spine_from AND p.spine_to AS ok),
            STRUCT('pay', t.end_date, IFNULL(t.amount_of_payment, 0.0),
                   NOT t.is_deleted AND t.status = 'Approved' AND t.end_date BETWEEN p.spine_from AND p.spine_to)]) e
  WHERE t.country IN ('Rwanda', 'Uganda', 'Kenya') AND NOT t.fivetran_deleted AND t.mason_id IS NOT NULL
    AND (t.start_date BETWEEN p.spine_from AND p.spine_to OR t.end_date BETWEEN p.spine_from AND p.spine_to)
    AND e.ok
),

-- Level x mason x week from the lines, added up per mason and week, with the
-- name on the mason's most recent line so a renamed record reads consistently.
lines_lvl AS (
  SELECT country, level, name, mason_id, DATE_TRUNC(d, MONTH) AS month,
    LEAST(CAST(CEIL(EXTRACT(DAY FROM d) / 7) AS INT64), 4) AS week_no,
    COUNTIF(kind = 'ts') AS timesheets,
    SUM(IF(kind = 'pay', amount, 0)) AS earnings,
    ARRAY_AGG(mason_name IGNORE NULLS ORDER BY d DESC LIMIT 1)[SAFE_OFFSET(0)] AS mason_name,
    MAX(d) AS last_seen
  FROM line_events
  GROUP BY 1, 2, 3, 4, 5, 6
),

-- Completed builds in the window, placed the same way and kept for the place.
build_lvl AS (
  SELECT m.country, m.level, m.name, x.mason_id, DATE_TRUNC(x.completed_date, MONTH) AS month,
    LEAST(CAST(CEIL(EXTRACT(DAY FROM x.completed_date) / 7) AS INT64), 4) AS week_no,
    COUNT(DISTINCT x.opportunity_id) AS builds_completed
  FROM (
    SELECT
      mo.location_country AS country,
      CASE mo.location_country
        WHEN 'Rwanda' THEN mo.location_territory
        WHEN 'Uganda' THEN COALESCE(NULLIF(TRIM(l.branch_c), ''), REGEXP_EXTRACT(mo.branch, r'^(.+) Branch$'))
        WHEN 'Kenya' THEN COALESCE(NULLIF(TRIM(l.branch_c), ''), NULLIF(TRIM(l.district_c), ''), mo.location_district)
      END AS unit,
      mo.mason_id, mo.opportunity_id, mo.completed_date
    FROM `earth-enable-main.raw_data_from_salesforce.all_opportunities_master` mo
    CROSS JOIN params p
    LEFT JOIN `earth-enable-main.salesforce.location_c` l ON l.id = mo.location_id AND mo.location_country != 'Rwanda'
    WHERE mo.location_country IN ('Rwanda', 'Uganda', 'Kenya')
      AND SAFE_CAST(mo.opportunity_phase AS INT64) = 1
      AND COALESCE(mo.simplified_product_interest, '') != 'Full House'
      AND mo.mason_id IS NOT NULL AND mo.completed_date IS NOT NULL
      AND mo.completed_date BETWEEN p.spine_from AND p.spine_to
  ) x
  JOIN members m ON m.country = x.country AND m.unit = x.unit
  GROUP BY 1, 2, 3, 4, 5, 6
),

calendar AS (
  SELECT month, week_no, week_start, week_end,
    (SELECT COUNTIF(EXTRACT(DAYOFWEEK FROM d) = 4) FROM UNNEST(GENERATE_DATE_ARRAY(week_start, week_end)) d) AS wednesdays
  FROM (
    SELECT mth AS month, w AS week_no,
      DATE_ADD(mth, INTERVAL (w - 1) * 7 DAY) AS week_start,
      IF(w = 4, LAST_DAY(mth), DATE_ADD(mth, INTERVAL w * 7 - 1 DAY)) AS week_end
    FROM params p,
      UNNEST(GENERATE_DATE_ARRAY(p.spine_from, DATE_TRUNC(p.spine_to, MONTH), INTERVAL 1 MONTH)) mth,
      UNNEST([1, 2, 3, 4]) w
    WHERE DATE_ADD(mth, INTERVAL (w - 1) * 7 DAY) <= p.spine_to
  )
),

-- One row per level x name x mason x week from either source.
joined AS (
  SELECT
    COALESCE(t.country, b.country) AS country,
    COALESCE(t.level, b.level) AS level,
    COALESCE(t.name, b.name) AS name,
    COALESCE(t.mason_id, b.mason_id) AS mason_id,
    COALESCE(t.month, b.month) AS month,
    COALESCE(t.week_no, b.week_no) AS week_no,
    IFNULL(t.timesheets, 0) AS timesheets,
    IFNULL(t.earnings, 0) AS earnings,
    IFNULL(b.builds_completed, 0) AS builds_completed,
    t.mason_name, t.last_seen
  FROM lines_lvl t
  FULL OUTER JOIN build_lvl b
    ON b.country = t.country AND b.level = t.level AND b.name = t.name AND b.mason_id = t.mason_id AND b.month = t.month AND b.week_no = t.week_no
)

SELECT
  k.country,
  k.level, k.name, k.mason_id,
  COALESCE(FIRST_VALUE(k.mason_name IGNORE NULLS) OVER (PARTITION BY k.mason_id ORDER BY k.last_seen DESC NULLS LAST), k.mason_id) AS mason_name,
  k.month, k.week_no, c.week_start, c.week_end,
  CONCAT('W', CAST(k.week_no AS STRING), ' (', FORMAT_DATE('%d', c.week_start), '-', FORMAT_DATE('%d %b', c.week_end), ')') AS week_label,
  c.week_end < CURRENT_DATE() AS is_complete_week,
  c.wednesdays,
  k.timesheets,
  k.earnings,
  k.builds_completed,
  th.currency,
  th.weekly_threshold,
  th.weekly_threshold * c.wednesdays AS threshold,
  SAFE_DIVIDE(k.earnings, th.weekly_threshold * c.wednesdays) AS pct_of_threshold,
  k.earnings >= th.weekly_threshold * c.wednesdays AS is_productive,
  CURRENT_TIMESTAMP() AS built_at
FROM joined k
JOIN calendar c ON c.month = k.month AND c.week_no = k.week_no
JOIN thresholds th ON th.country = k.country
);

-- The old name, for ad hoc queries: every place, 18 months back. The app
-- calls the function directly for the deep dive it is showing.
CREATE OR REPLACE VIEW `earth-enable-main.raw_data_from_salesforce.territory_mason_week_v1` AS
SELECT * FROM `earth-enable-main.raw_data_from_salesforce.capacity_mason_week`(NULL, NULL, NULL);
