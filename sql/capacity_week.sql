-- =============================================================================
-- raw_data_from_salesforce.capacity_week(p_country, p_month)
-- raw_data_from_salesforce.territory_capacity_week_v1  = capacity_week(NULL, NULL)
--
-- Feeds the Capacity planning page (/capacity) for Rwanda, Uganda and Kenya.
-- One row per country x level x name x month x week set. Rwanda's levels are
-- territory, district, manager and country; Uganda and Kenya have branches
-- only, so their levels are branch and country. The logic is identical for
-- every country: same weeks, same four-builds standard, same productive
-- rule, same focus ranking. Only the unit changes.
--
-- A table function, computed on read, so the page is as current as the
-- Fivetran sync and nothing has to be rebuilt. The app calls it with the
-- selected country and month:
--   SELECT * FROM `earth-enable-main.raw_data_from_salesforce.capacity_week`('Rwanda', DATE '2026-09-01')
-- and gets that month's rows plus the six months before it, which covers the
-- trend (two months back) and the four-week comparison (eight complete weeks
-- back from the month's first week, so the first week of a month reaches
-- into the month before). The view of the old name is the same function
-- called with NULLs: every country, 18 months back, for ad hoc use.
--
-- What keeps it tolerable on read, in order of weight:
--   1. The filters apply BEFORE the expensive work: p_country and the window
--      are pushed into the scans of all_opportunities_master and
--      mason_timesheet_readable themselves, so only that country's rows in
--      the window are ever read, and into `dim` and `calendar`, so
--      everything downstream is sized by them.
--   2. Shape. BigQuery re-inlines a CTE at every reference, so a CTE that is
--      referenced three times is computed three times, and a chain of them
--      multiplies. Here each raw table is scanned at most twice, every fact
--      goes through ONE per-person aggregate (`set_person`), and the
--      four-week comparison, the focus ranking and its persistence are all
--      window functions in a single pass over the scored rows: no CTE
--      references the scored pipeline more than once. An earlier shape with
--      the same logic could not be planned at all ("query is too complex").
-- Even so a call takes 12 to 16 seconds: about 170 stages at 100 to 300 ms
-- each, whatever the filters. The app caches each country and month for 30
-- minutes. Fresh over fast was the decision on 2026-09-17.
-- Every threshold sits in `params`.
--
-- Every distinct count (masons, CSOs) is computed independently at each level,
-- the way cso_headcount_app_v1 does it, because a mason or a CSO working two
-- units is one person. Never roll these up by addition.
--
-- The single weeks (week_key '1'..'4') are the base grain; the other eleven
-- keys are every combination of weeks in the month, so when the page's week
-- multi-select picks weeks 1 and 2 it reads the '12' row and gets a distinct
-- mason count of 462, never 355 + 360. Filter `is_single_week` for the series.
--
-- Masons: Working + Assigned + To hire = the month's requirement. Working is
-- distinct masons with a timesheet starting in the set. Assigned is distinct
-- masons with a live job at the set's end and no timesheet in it, exclusive of
-- Working. `masons_to_hire` is each unit's own shortfall after both, floored
-- at zero, then summed: never netted against units that are over, and never
-- recomputed from a district or country total. CSOs follow the same rule:
-- `csos_short` is each unit's own shortfall against the country's CSOs per
-- unit, floored at zero, then summed. Where a unit is above its requirement
-- the parts can sum to more than it.
--
-- Where a unit sits: Rwanda by territory (all_opportunities_master's own
-- location_territory); Uganda by Salesforce's own branch field on the
-- location (location_c.branch_c), never a hardcoded district list; Kenya's
-- three districts are its three branches. Timesheet lines with no country,
-- district or opportunity (about 1,500 lines, 159 masons) resolve to no unit
-- and are excluded from every mason count. Do not try to allocate them.
--
-- Earnings are approved gross pay by end date, the bonus basis, the same as
-- capacity_mason_week; they will not tie to the Looker capacity dashboard's
-- earnings, which use net pay by start date.
--
-- Targets: Rwanda from tl_bonus_targets (territory grain); Uganda and Kenya
-- from branch_capacity_targets (branch grain, see sql/branch_capacity_targets.sql).
-- Never merged. Both are the month's own target (September activity vs
-- September's target). From September 2026 Nyagatare's district target is
-- shared B one half, A one quarter, C one quarter (see tl_targets).
--
-- Weeks are days 1-7, 8-14, 15-21 and 22 to month end, never Saturday to
-- Friday, so four weeks always sum back to the month.
--
-- Deploy: paste this file into the BigQuery console (or the connector) and
-- run it. It creates the function and then the view over it.
-- =============================================================================

CREATE OR REPLACE TABLE FUNCTION `earth-enable-main.raw_data_from_salesforce.capacity_week`(p_country STRING, p_month DATE)
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
-- -----------------------------------------------------------------------------
-- Thresholds and the window. Change them here and nowhere else.
-- -----------------------------------------------------------------------------
params AS (
  SELECT
    4    AS top_n,             -- focus: the N units per manager (per country where there is no manager) furthest behind their SQM-E target over 4 weeks
    0.20 AS drop_share,        -- watch line: masons, or earnings per mason, down by this share vs the 4 weeks before
    0.85 AS ratio_build_more,  -- build_coll_ratio below this = BUILD MORE
    1.15 AS ratio_sell_more,   -- build_coll_ratio above this = SELL MORE
    0.10 AS almost_nothing,    -- under this share of the SQM-E target the takeaway says "almost nothing"
    90   AS onsite_days,       -- a job is live for this long after it became buildable
    365  AS backlog_days,      -- collected_not_built only counts contracts collected within this many days
    -- The window. With p_month: the six months before it through the month
    -- itself. Without: 18 months back through the current month, which leaves
    -- the page's month selector room to go back a year. Timesheets reach back
    -- a further ten weeks for the prior four-week block; opportunities as far
    -- back as the backlog window.
    spine_from,
    spine_to,
    DATE_SUB(spine_from, INTERVAL 70 DAY) AS ts_from,
    DATE_SUB(spine_from, INTERVAL 365 DAY) AS opp_from
  FROM (
    SELECT
      COALESCE(DATE_TRUNC(DATE_SUB(p_month, INTERVAL 6 MONTH), MONTH), DATE_TRUNC(DATE_SUB(CURRENT_DATE(), INTERVAL 18 MONTH), MONTH)) AS spine_from,
      LEAST(COALESCE(DATE_TRUNC(p_month, MONTH), DATE_TRUNC(CURRENT_DATE(), MONTH)), DATE_TRUNC(CURRENT_DATE(), MONTH)) AS spine_to
  )
),

-- Per-country rules, defined once. The unit of management and the CSOs each
-- unit should have (the September 2026 operating standard). The same figure
-- is the headcount requirement AND the divisor that turns a unit's sales and
-- collections targets into a per-CSO standard, so a country is never scored
-- against another country's assumption. Never compare CSOs per unit across
-- countries: the unit differs.
country_rules AS (
  SELECT * FROM UNNEST([
    STRUCT('Rwanda' AS country, 'territory' AS unit_level, 5.0 AS csos_per_unit),
    STRUCT('Uganda', 'branch', 9.0),
    STRUCT('Kenya', 'branch', 7.0)
  ])
),

-- Where each unit sits, for the country asked for (every country when
-- p_country is NULL). Rwanda territories come from their latest target row
-- so grouping is stable across months, even a month with no target. Uganda
-- and Kenya branches come from their targets table; they have no district
-- or manager grouping.
dim AS (
  SELECT * FROM (
    SELECT 'Rwanda' AS country, 'territory' AS unit_level, territory AS unit, d.district, d.manager
    FROM (
      SELECT territory,
        ARRAY_AGG(STRUCT(COALESCE(district, 'Unknown') AS district, COALESCE(manager, 'Unassigned') AS manager)
                  ORDER BY month DESC LIMIT 1)[OFFSET(0)] AS d
      FROM tl_targets
      WHERE territory IS NOT NULL
      GROUP BY 1
    )
    UNION ALL
    SELECT DISTINCT country, 'branch', branch, CAST(NULL AS STRING), CAST(NULL AS STRING)
    FROM `earth-enable-main.raw_data_from_salesforce.branch_capacity_targets`
  )
  WHERE p_country IS NULL OR country = p_country
),

-- The grains, each as a list of member units.
members AS (
  SELECT country, unit_level AS level, unit AS name, district AS parent, manager, unit FROM dim
  UNION ALL SELECT country, 'district', district, CAST(NULL AS STRING), CAST(NULL AS STRING), unit FROM dim WHERE unit_level = 'territory'
  UNION ALL SELECT country, 'manager', manager, NULL, NULL, unit FROM dim WHERE unit_level = 'territory'
  UNION ALL SELECT country, 'country', country, NULL, NULL, unit FROM dim
),

names AS (
  SELECT country, level, name, ANY_VALUE(parent) AS parent, ANY_VALUE(manager) AS manager, COUNT(*) AS n_territories
  FROM members GROUP BY 1, 2, 3
),

-- Targets at unit grain, whichever table applies by country.
targets AS (
  SELECT 'Rwanda' AS country, territory AS unit, month, build_target, sqme_target, min_productive_masons, min_build_productivity
  FROM tl_targets
  WHERE territory IS NOT NULL
  UNION ALL
  SELECT country, branch, month, build_target, sqme_target, min_productive_masons, min_build_productivity
  FROM `earth-enable-main.raw_data_from_salesforce.branch_capacity_targets`
),

-- -----------------------------------------------------------------------------
-- Calendar: the four windows of each month, and the fifteen ways to pick them.
-- -----------------------------------------------------------------------------
weeksets AS (
  SELECT week_key, weeks FROM UNNEST(ARRAY<STRUCT<week_key STRING, weeks ARRAY<INT64>>>[
    ('1',[1]), ('2',[2]), ('3',[3]), ('4',[4]),
    ('12',[1,2]), ('13',[1,3]), ('14',[1,4]), ('23',[2,3]), ('24',[2,4]), ('34',[3,4]),
    ('123',[1,2,3]), ('124',[1,2,4]), ('134',[1,3,4]), ('234',[2,3,4]), ('1234',[1,2,3,4])
  ])
),

calendar AS (
  SELECT mth AS month, w AS week_no,
    DATE_ADD(mth, INTERVAL (w - 1) * 7 DAY) AS week_start,
    IF(w = 4, LAST_DAY(mth), DATE_ADD(mth, INTERVAL w * 7 - 1 DAY)) AS week_end
  FROM params p,
    UNNEST(GENERATE_DATE_ARRAY(p.spine_from, p.spine_to, INTERVAL 1 MONTH)) mth,
    UNNEST([1, 2, 3, 4]) w
  WHERE DATE_ADD(mth, INTERVAL (w - 1) * 7 DAY) <= CURRENT_DATE()   -- the week has started
),

spine AS (
  SELECT n.country, n.level, n.name, ws.week_key, c.month,
    COUNT(*) AS n_weeks,
    MIN(c.week_start) AS week_start,
    MAX(c.week_end) AS week_end,
    MAX(c.week_no) AS last_week_no,
    MAX(c.week_start) AS last_week_start,
    LOGICAL_AND(c.week_end < CURRENT_DATE()) AS is_complete_week
  FROM names n
  CROSS JOIN weeksets ws
  JOIN calendar c ON c.week_no IN UNNEST(ws.weeks)
  GROUP BY 1, 2, 3, 4, 5
  HAVING COUNT(*) = ARRAY_LENGTH(ANY_VALUE(ws.weeks))   -- every week in the set has started
),

-- -----------------------------------------------------------------------------
-- Raw rows: country and window pushed into the scans themselves.
-- -----------------------------------------------------------------------------
-- Same population as territory_capacity_monthly: phase 1, not Full House.
base AS (
  SELECT x.* FROM (
    SELECT
      m.location_country AS country,
      CASE m.location_country
        WHEN 'Rwanda' THEN m.location_territory
        WHEN 'Uganda' THEN COALESCE(NULLIF(TRIM(l.branch_c), ''), REGEXP_EXTRACT(m.branch, r'^(.+) Branch$'))
        WHEN 'Kenya' THEN COALESCE(NULLIF(TRIM(l.branch_c), ''), NULLIF(TRIM(l.district_c), ''), m.location_district)
      END AS unit,
      m.adjusted_square_meters AS sqme,        -- already SQM-E weighted (Floor x1, Plaster/Paint x0.333)
      m.cso_id,
      m.mason_id,
      m.customer_signed_date AS signed_date,
      m.completed_date,
      IF(m.simplified_product_interest = 'Floor', m.date_50pct_paid, m.date_100pct_paid) AS collected_date,
      COALESCE(IF(m.simplified_product_interest = 'Floor', m.date_50pct_paid, m.date_100pct_paid),
               m.customer_signed_date) AS buildable_date,
      m.associated_project_status AS assoc_status,
      m.opportunity_stage AS stage
    FROM `earth-enable-main.raw_data_from_salesforce.all_opportunities_master` m
    CROSS JOIN params p
    -- The branch field is only needed outside Rwanda, so Rwanda never joins it.
    LEFT JOIN `earth-enable-main.salesforce.location_c` l ON l.id = m.location_id AND m.location_country != 'Rwanda'
    WHERE m.location_country IN ('Rwanda', 'Uganda', 'Kenya')
      AND (p_country IS NULL OR m.location_country = p_country)
      AND SAFE_CAST(m.opportunity_phase AS INT64) = 1
      AND COALESCE(m.simplified_product_interest, '') != 'Full House'
      AND (m.customer_signed_date >= p.spine_from OR m.completed_date >= p.spine_from
           OR IF(m.simplified_product_interest = 'Floor', m.date_50pct_paid, m.date_100pct_paid) >= p.opp_from
           OR COALESCE(IF(m.simplified_product_interest = 'Floor', m.date_50pct_paid, m.date_100pct_paid), m.customer_signed_date)
                >= DATE_SUB(p.spine_from, INTERVAL p.onsite_days DAY))
  ) x
  JOIN dim tt ON tt.country = x.country AND tt.unit = x.unit
),

-- Timesheet lines placed in their unit: Rwanda by territory; Uganda and
-- Kenya by the branch on the line's location, else the line's district when
-- that district is itself a branch (Kenya's always are). Lines that resolve
-- to no unit are excluded. Each line becomes a Working event by start date
-- and, if approved, a pay event by end date (the bonus rule: approved, not
-- deleted, gross).
ts_facts AS (
  SELECT t.country, tt.unit, e.d, DATE_TRUNC(e.d, MONTH) AS month,
    LEAST(CAST(CEIL(EXTRACT(DAY FROM e.d) / 7) AS INT64), 4) AS week_no,
    e.kind, t.mason_id AS person_id, 0.0 AS sqme, e.amount
  FROM `earth-enable-main.raw_data_from_salesforce.mason_timesheet_readable` t
  CROSS JOIN params p
  LEFT JOIN `earth-enable-main.salesforce.location_c` l ON l.id = t.location_id AND t.country != 'Rwanda'
  LEFT JOIN dim du ON du.country = t.country AND du.unit = t.district AND du.unit_level = 'branch'
  JOIN dim tt ON tt.country = t.country
    AND tt.unit = IF(t.country = 'Rwanda', t.territory, COALESCE(NULLIF(TRIM(l.branch_c), ''), du.unit)),
    UNNEST([STRUCT('ts' AS kind, t.start_date AS d, 0.0 AS amount,
                   t.start_date IS NOT NULL AND t.start_date >= p.ts_from AS ok),
            STRUCT('pay', t.end_date, IFNULL(t.amount_of_payment, 0.0),
                   NOT t.is_deleted AND t.status = 'Approved' AND t.end_date IS NOT NULL AND t.end_date >= p.ts_from)]) e
  WHERE t.country IN ('Rwanda', 'Uganda', 'Kenya')
    AND (p_country IS NULL OR t.country = p_country)
    AND NOT t.fivetran_deleted AND t.mason_id IS NOT NULL
    AND (t.start_date >= p.ts_from OR t.end_date >= p.ts_from)
    AND e.ok
),

-- How settled a week's pay is: approved timesheet lines over all lines, by
-- end date, per country. The newest week reads low until approvals catch up.
approvals AS (
  SELECT t.country, DATE_TRUNC(t.end_date, MONTH) AS month,
    LEAST(CAST(CEIL(EXTRACT(DAY FROM t.end_date) / 7) AS INT64), 4) AS week_no,
    SAFE_DIVIDE(COUNTIF(t.status = 'Approved'), COUNT(*)) AS approval_rate
  FROM `earth-enable-main.raw_data_from_salesforce.mason_timesheet_readable` t
  CROSS JOIN params p
  WHERE NOT t.fivetran_deleted AND NOT t.is_deleted AND t.end_date IS NOT NULL AND t.country IS NOT NULL
    AND (p_country IS NULL OR t.country = p_country)
    AND t.end_date >= p.ts_from
  GROUP BY 1, 2, 3
),

-- -----------------------------------------------------------------------------
-- One fact stream: every event the page counts, as (unit, week, kind, person).
-- Person-level rows stay person-level so the set and level rollups can take
-- their own distinct counts.
--   sold, collected, built  from the opportunity, dated by that event; person = the CSO (sold, collected) or mason (built)
--   onsite                  a mason with a live job as at a week's end: buildable in the last onsite_days and not yet completed
--   backlog                 a contract collected in the last backlog_days and not built by the week's end
--   ts, pay                 from ts_facts above
-- -----------------------------------------------------------------------------
facts AS (
  SELECT b.country, b.unit, e.d, DATE_TRUNC(e.d, MONTH) AS month,
    LEAST(CAST(CEIL(EXTRACT(DAY FROM e.d) / 7) AS INT64), 4) AS week_no,
    e.kind, e.person_id, b.sqme, 0.0 AS amount
  FROM base b
  CROSS JOIN params p,
    UNNEST([STRUCT('sold' AS kind, b.signed_date AS d, b.cso_id AS person_id),
            STRUCT('collected', b.collected_date, b.cso_id),
            STRUCT('built', b.completed_date, b.mason_id)]) e
  WHERE e.d >= p.spine_from

  UNION ALL

  SELECT b.country, b.unit, c.week_end AS d, c.month, c.week_no,
    kind, IF(kind = 'onsite', b.mason_id, NULL) AS person_id, 0.0 AS sqme, 0.0 AS amount
  FROM base b
  CROSS JOIN params p
  JOIN calendar c
    ON b.buildable_date BETWEEN DATE_SUB(c.week_end, INTERVAL p.onsite_days DAY) AND c.week_end
    OR b.collected_date BETWEEN DATE_SUB(c.week_end, INTERVAL p.backlog_days DAY) AND c.week_end,
    UNNEST(ARRAY_CONCAT(
      IF(b.mason_id IS NOT NULL
         AND b.buildable_date BETWEEN DATE_SUB(c.week_end, INTERVAL p.onsite_days DAY) AND c.week_end
         AND ((b.completed_date IS NOT NULL AND b.completed_date > c.week_end)
              OR (b.completed_date IS NULL AND b.assoc_status = 'In Progress')),
         ['onsite'], ARRAY<STRING>[]),
      IF(b.collected_date BETWEEN DATE_SUB(c.week_end, INTERVAL p.backlog_days DAY) AND c.week_end
         AND (b.completed_date IS NULL OR b.completed_date > c.week_end)
         AND COALESCE(b.stage, '') != 'Closed Lost',
         ['backlog'], ARRAY<STRING>[])
    )) AS kind

  UNION ALL

  SELECT country, unit, d, month, week_no, kind, person_id, sqme, amount FROM ts_facts
),

-- -----------------------------------------------------------------------------
-- Rollups per (country, level, name, month, week set). Distinct counts are
-- taken here, at the set and level, never added across weeks or units.
-- -----------------------------------------------------------------------------
set_weeks AS (
  SELECT s.country, s.level, s.name, s.month, s.week_key, s.n_weeks, s.last_week_no, m.unit, w AS week_no
  FROM spine s
  JOIN members m ON m.country = s.country AND m.level = s.level AND m.name = s.name
  JOIN weeksets ws ON ws.week_key = s.week_key, UNNEST(ws.weeks) w
),

-- One row per set and person, so a person seen in two units of a district,
-- or in two weeks of a set, is one row. Assigned is decided here: on site at
-- the set's last week and no timesheet anywhere in the set.
set_person AS (
  SELECT k.country, k.level, k.name, k.month, k.week_key, f.person_id,
    COUNTIF(f.kind = 'sold') AS sold,
    SUM(IF(f.kind = 'sold', f.sqme, 0)) AS sqme_sold,
    COUNTIF(f.kind = 'collected') AS collected,
    SUM(IF(f.kind = 'collected', f.sqme, 0)) AS sqme_collected,
    COUNTIF(f.kind = 'built') AS built,
    SUM(IF(f.kind = 'built', f.sqme, 0)) AS sqme_built,
    LOGICAL_OR(f.kind IN ('sold', 'collected') AND f.person_id IS NOT NULL) AS is_cso,
    LOGICAL_OR(f.kind = 'built' AND f.person_id IS NOT NULL) AS built_any,
    LOGICAL_OR(f.kind = 'ts') AS has_ts,
    LOGICAL_OR(f.kind = 'pay') AS paid,
    SUM(IF(f.kind = 'pay', f.amount, 0)) AS earnings,
    LOGICAL_OR(f.kind = 'onsite' AND f.week_no = k.last_week_no) AS onsite_last,
    COUNTIF(f.kind = 'backlog' AND f.week_no = k.last_week_no) AS backlog
  FROM set_weeks k
  JOIN facts f ON f.country = k.country AND f.unit = k.unit AND f.month = k.month AND f.week_no = k.week_no
  GROUP BY 1, 2, 3, 4, 5, 6
),

set_agg AS (
  SELECT country, level, name, month, week_key,
    SUM(sold) AS contracts_sold, SUM(sqme_sold) AS sqme_sold,
    SUM(collected) AS contracts_collected, SUM(sqme_collected) AS sqme_collected,
    SUM(built) AS contracts_built, SUM(sqme_built) AS sqme_built,
    COUNTIF(is_cso) AS csos_active,
    COUNTIF(built_any) AS masons_built,
    COUNTIF(has_ts) AS masons_on_timesheet,
    COUNTIF(paid) AS masons_paid,
    SUM(earnings) AS mason_earnings,
    COUNTIF(onsite_last) AS masons_onsite,
    COUNTIF(onsite_last AND NOT has_ts) AS masons_assigned,
    SUM(backlog) AS collected_not_built
  FROM set_person
  GROUP BY 1, 2, 3, 4, 5
),

-- Targets are the month's own: September activity vs September's target.
-- Every shortfall is per unit, after what is
-- in place, floored at zero, then summed. Never SUM(min) - SUM(actual).
-- The CSO requirement per unit is the country lookup, and the same figure is
-- the divisor behind the per-CSO sales and collections standards.
target_set AS (
  SELECT k.country, k.level, k.name, k.month, k.week_key,
    LOGICAL_OR(t.unit IS NOT NULL) AS has_targets,
    COUNTIF(t.unit IS NOT NULL) AS n_targeted,
    SUM(t.min_productive_masons) AS min_masons,
    SUM(IF(t.unit IS NULL, NULL, cr.csos_per_unit)) AS min_csos,
    SUM(t.build_target) * 0.25 * ANY_VALUE(k.n_weeks) AS build_target_week,
    SUM(t.sqme_target) * 0.25 * ANY_VALUE(k.n_weeks) AS sqme_target_week,
    SUM(t.build_target) * 1.3 * 0.25 * ANY_VALUE(k.n_weeks) AS sales_target_week,
    -- Builds these masons should have completed: each unit's own bar times its own working masons.
    SUM(t.min_build_productivity * 0.25 * k.n_weeks * IFNULL(u.masons_on_timesheet, 0)) AS expected_builds,
    COALESCE(
      SAFE_DIVIDE(SUM(t.min_build_productivity * 0.25 * k.n_weeks * IFNULL(u.masons_on_timesheet, 0)),
                  SUM(IF(t.min_build_productivity IS NULL, 0, IFNULL(u.masons_on_timesheet, 0)))),
      AVG(t.min_build_productivity) * 0.25 * ANY_VALUE(k.n_weeks)) AS usual_builds_per_mason,
    SUM(GREATEST(t.min_productive_masons - (IFNULL(u.masons_on_timesheet, 0) + IFNULL(u.masons_assigned, 0)), 0)) AS masons_to_hire,
    COUNTIF(t.min_productive_masons > IFNULL(u.masons_on_timesheet, 0) + IFNULL(u.masons_assigned, 0)) AS territories_short,
    SUM(IF(t.unit IS NULL, NULL, GREATEST(cr.csos_per_unit - IFNULL(u.csos_active, 0), 0))) AS csos_short,
    COUNTIF(t.unit IS NOT NULL AND cr.csos_per_unit > IFNULL(u.csos_active, 0)) AS units_short_csos
  FROM (SELECT DISTINCT country, level, name, month, week_key, n_weeks, unit FROM set_weeks) k
  JOIN country_rules cr ON cr.country = k.country
  LEFT JOIN targets t ON t.country = k.country AND t.unit = k.unit AND t.month = k.month
  LEFT JOIN set_agg u ON u.level IN ('territory', 'branch') AND u.country = k.country AND u.name = k.unit AND u.month = k.month AND u.week_key = k.week_key
  GROUP BY 1, 2, 3, 4, 5
),

-- Distinct masons over each four-week block of complete single weeks. A sum
-- of four weekly distinct counts would count a mason four times, so the
-- block is counted from the timesheet lines themselves. Working from
-- timesheets by start date; paid from approved pay by end date, so earnings
-- per mason divides pay by the people it was paid to, the same as the
-- roster. Block boundaries come from the spine, not the scored rows.
blocks AS (
  SELECT country, level, name, week_start, week_end,
    COALESCE(LAG(week_start, 3) OVER w, FIRST_VALUE(week_start) OVER w) AS cur_start,
    LAG(week_start, 7) OVER w AS prev_start,
    LAG(week_end, 4) OVER w AS prev_end
  FROM spine
  WHERE n_weeks = 1 AND is_complete_week
  WINDOW w AS (PARTITION BY country, level, name ORDER BY week_start)
),

hist_people AS (
  SELECT b.country, b.level, b.name, b.week_start,
    COUNT(DISTINCT IF(f.kind = 'ts' AND f.d BETWEEN b.cur_start AND b.week_end, f.person_id, NULL)) AS masons_4w,
    COUNT(DISTINCT IF(f.kind = 'ts' AND f.d BETWEEN b.prev_start AND b.prev_end, f.person_id, NULL)) AS masons_prev_4w,
    COUNT(DISTINCT IF(f.kind = 'pay' AND f.d BETWEEN b.cur_start AND b.week_end, f.person_id, NULL)) AS paid_4w,
    COUNT(DISTINCT IF(f.kind = 'pay' AND f.d BETWEEN b.prev_start AND b.prev_end, f.person_id, NULL)) AS paid_prev_4w
  FROM blocks b
  JOIN members m ON m.country = b.country AND m.level = b.level AND m.name = b.name
  LEFT JOIN ts_facts f ON f.country = m.country AND f.unit = m.unit
    AND f.d BETWEEN COALESCE(b.prev_start, b.cur_start) AND b.week_end
  GROUP BY 1, 2, 3, 4
),

-- -----------------------------------------------------------------------------
-- One row per spine row with every metric, scored and constrained. From here
-- on everything is one pass: no CTE below references another one twice.
-- -----------------------------------------------------------------------------
metrics AS (
  SELECT
    s.country, s.level, s.name, n.parent, n.manager, n.n_territories,
    s.week_key, s.month, s.n_weeks, s.n_weeks = 1 AS is_single_week,
    IF(s.n_weeks = 1, s.last_week_no, NULL) AS week_no,
    s.week_start, s.week_end, s.last_week_no, s.last_week_start, s.is_complete_week,
    -- The rows the four-week comparison runs over: complete single weeks.
    s.n_weeks = 1 AND s.is_complete_week AS is_block_week,
    IFNULL(g.has_targets, FALSE) AS has_targets,
    IFNULL(g.n_targeted, 0) AS n_targeted,
    IFNULL(a.contracts_sold, 0) AS contracts_sold,
    IFNULL(a.sqme_sold, 0) AS sqme_sold,
    IFNULL(a.contracts_collected, 0) AS contracts_collected,
    IFNULL(a.sqme_collected, 0) AS sqme_collected,
    IFNULL(a.contracts_built, 0) AS contracts_built,
    IFNULL(a.sqme_built, 0) AS sqme_built,
    IFNULL(a.csos_active, 0) AS csos_active,
    IFNULL(a.masons_on_timesheet, 0) AS masons_on_timesheet,
    IFNULL(a.masons_paid, 0) AS masons_paid,
    IFNULL(a.mason_earnings, 0) AS mason_earnings,
    ap.approval_rate,
    IFNULL(a.masons_built, 0) AS masons_built,
    IFNULL(a.masons_onsite, 0) AS masons_onsite,
    IFNULL(a.masons_assigned, 0) AS masons_assigned,
    IFNULL(a.masons_on_timesheet, 0) + IFNULL(a.masons_assigned, 0) AS masons_total,
    IFNULL(a.collected_not_built, 0) AS collected_not_built,
    g.min_masons, g.masons_to_hire, IFNULL(g.territories_short, 0) AS territories_short,
    g.min_csos, g.csos_short, IFNULL(g.units_short_csos, 0) AS units_short_csos,
    g.build_target_week, g.sqme_target_week, g.sales_target_week,
    g.expected_builds, g.usual_builds_per_mason,
    hp.masons_4w, hp.masons_prev_4w, hp.paid_4w, hp.paid_prev_4w
  FROM spine s
  JOIN names n ON n.country = s.country AND n.level = s.level AND n.name = s.name
  LEFT JOIN set_agg a ON a.country = s.country AND a.level = s.level AND a.name = s.name AND a.month = s.month AND a.week_key = s.week_key
  LEFT JOIN approvals ap ON ap.country = s.country AND ap.month = s.month AND ap.week_no = s.last_week_no
  LEFT JOIN target_set g ON g.country = s.country AND g.level = s.level AND g.name = s.name AND g.month = s.month AND g.week_key = s.week_key
  LEFT JOIN hist_people hp ON s.n_weeks = 1 AND s.is_complete_week
    AND hp.country = s.country AND hp.level = s.level AND hp.name = s.name AND hp.week_start = s.week_start
),

ratios AS (
  SELECT m.*,
    SAFE_DIVIDE(mason_earnings, NULLIF(masons_paid, 0)) AS earnings_per_mason,
    SAFE_DIVIDE(contracts_built, build_target_week) AS pct_of_build_target,
    SAFE_DIVIDE(sqme_built, sqme_target_week) AS pct_of_sqme_target,
    SAFE_DIVIDE(contracts_sold, sales_target_week) AS pct_of_sales_target,
    SAFE_DIVIDE(contracts_collected, build_target_week) AS pct_of_coll_target,
    SAFE_DIVIDE(contracts_built, NULLIF(contracts_collected, 0)) AS build_coll_ratio,
    SAFE_DIVIDE(contracts_built, NULLIF(masons_on_timesheet, 0)) AS builds_per_mason,
    SAFE_DIVIDE(contracts_built, NULLIF(expected_builds, 0)) AS pct_build_productivity,
    -- Masons the requirement is short of on productivity alone: the builds
    -- actually completed, at the per-mason standard for these weeks, against
    -- the requirement. Compared with masons_to_hire in the readings.
    COALESCE(GREATEST(min_masons - SAFE_DIVIDE(contracts_built, NULLIF(usual_builds_per_mason, 0)), 0), 0) AS productivity_gap,
    -- Sales and collections per CSO against the per-CSO standard, which is the
    -- unit's target over the country's CSOs per unit.
    SAFE_DIVIDE(SAFE_DIVIDE(contracts_sold, NULLIF(csos_active, 0)), SAFE_DIVIDE(sales_target_week, NULLIF(min_csos, 0))) AS pct_sales_productivity,
    SAFE_DIVIDE(SAFE_DIVIDE(contracts_collected, NULLIF(csos_active, 0)), SAFE_DIVIDE(build_target_week, NULLIF(min_csos, 0))) AS pct_coll_productivity,
    -- CSOs the requirement is short of on output alone: the CSOs that would
    -- not be needed if each one signed to the standard.
    COALESCE(GREATEST(min_csos - SAFE_DIVIDE(contracts_sold, NULLIF(SAFE_DIVIDE(sales_target_week, NULLIF(min_csos, 0)), 0)), 0), 0) AS cso_output_gap,
    -- Four-week blocks, evaluated on complete single weeks only, in a
    -- continuous series across month ends. Each block of four holds exactly
    -- one week 4, so the longer last window never skews a comparison. Week
    -- against week is never used: builds run 3 per territory in week 1 and
    -- 15 in week 4 because of the month-end push, so it would measure the
    -- calendar. The other rows sit in their own partition and ignore these.
    SUM(contracts_built) OVER cur  AS built_4w,
    SUM(contracts_built) OVER prev AS built_prev_4w,
    SUM(build_target_week) OVER cur  AS target_4w,
    SUM(build_target_week) OVER prev AS target_prev_4w,
    SUM(sqme_built) OVER cur  AS sqme_built_4w,
    SUM(sqme_built) OVER prev AS sqme_built_prev_4w,
    SUM(sqme_target_week) OVER cur  AS sqme_target_4w,
    SUM(sqme_target_week) OVER prev AS sqme_target_prev_4w,
    SUM(contracts_sold) OVER cur  AS sold_4w,
    SUM(contracts_sold) OVER prev AS sold_prev_4w,
    SUM(sales_target_week) OVER cur  AS sales_target_4w,
    SUM(sales_target_week) OVER prev AS sales_target_prev_4w,
    SUM(contracts_collected) OVER cur  AS coll_4w,
    SUM(contracts_collected) OVER prev AS coll_prev_4w,
    SUM(mason_earnings) OVER cur  AS earnings_4w,
    SUM(mason_earnings) OVER prev AS earnings_prev_4w,
    COUNT(*) OVER cur  AS weeks_cur,
    COUNT(*) OVER prev AS weeks_prev
  FROM metrics m
  WINDOW
    w    AS (PARTITION BY country, level, name, is_block_week ORDER BY week_start),
    cur  AS (w ROWS BETWEEN 3 PRECEDING AND CURRENT ROW),
    prev AS (w ROWS BETWEEN 7 PRECEDING AND 4 PRECEDING)
),

scored AS (
  SELECT r.*,
    CASE
      WHEN NOT has_targets THEN 'NO TARGET SET'
      WHEN contracts_collected = 0 AND contracts_built = 0 THEN 'NO DATA'
      WHEN contracts_collected = 0 THEN 'SELL MORE'   -- built with nothing collected: the ratio is unbounded
      WHEN build_coll_ratio < p.ratio_build_more THEN 'BUILD MORE'
      WHEN build_coll_ratio > p.ratio_sell_more THEN 'SELL MORE'
      ELSE 'BALANCED'
    END AS constraint_type,
    -- People versus performance, each side of the chain. Headcount is named
    -- only when the headcount gap is the larger of the two gaps; otherwise the
    -- people in place are read against the standard for the same weeks.
    CASE
      WHEN masons_to_hire > 0 AND masons_to_hire >= productivity_gap
        THEN CONCAT('Not enough masons. ', CAST(masons_total AS STRING), ' against a requirement of ', CAST(CAST(ROUND(min_masons) AS INT64) AS STRING), '.')
      WHEN builds_per_mason IS NULL THEN 'No mason was on a timesheet in these weeks.'
      WHEN usual_builds_per_mason IS NULL THEN CONCAT('Enough masons, each building ', FORMAT('%.1f', builds_per_mason), ', with no standard set.')
      ELSE CONCAT('Enough masons, each building ', FORMAT('%.1f', builds_per_mason),
                  ' against a target of ', FORMAT('%g', usual_builds_per_mason), IF(n_weeks = 4, '.', ' for these weeks.'))
    END AS mason_reading,
    CASE
      WHEN csos_short > 0 AND csos_short >= cso_output_gap
        THEN CONCAT('Not enough CSOs. ', CAST(csos_active AS STRING), ' against a requirement of ', CAST(CAST(ROUND(min_csos) AS INT64) AS STRING), '.')
      WHEN csos_active = 0 THEN 'No CSO signed or collected a contract in these weeks.'
      WHEN cso_output_gap = 0 THEN 'Enough CSOs, each signing to the standard or above it.'
      ELSE 'Enough CSOs, each signing fewer contracts than the standard.'
    END AS cso_reading,
    -- The four-week comparison, on block weeks.
    SAFE_DIVIDE(earnings_4w, NULLIF(paid_4w, 0)) AS epm_4w,
    SAFE_DIVIDE(earnings_prev_4w, NULLIF(paid_prev_4w, 0)) AS epm_prev_4w,
    SAFE_DIVIDE(built_4w, target_4w) AS pct_build_4w,
    SAFE_DIVIDE(built_prev_4w, target_prev_4w) AS pct_build_prev_4w,
    SAFE_DIVIDE(sqme_built_4w, sqme_target_4w) AS pct_sqme_4w,
    SAFE_DIVIDE(sqme_built_prev_4w, sqme_target_prev_4w) AS pct_sqme_prev_4w,
    SAFE_DIVIDE(sold_4w, sales_target_4w) AS pct_sales_4w,
    SAFE_DIVIDE(sold_prev_4w, sales_target_prev_4w) AS pct_sales_prev_4w,
    SAFE_DIVIDE(coll_4w, target_4w) AS pct_coll_4w,
    SAFE_DIVIDE(coll_prev_4w, target_prev_4w) AS pct_coll_prev_4w,
    sqme_target_4w - sqme_built_4w AS sqme_gap_4w,
    sqme_target_prev_4w - sqme_built_prev_4w AS sqme_gap_prev_4w,
    -- The watch signals need a full eight weeks and a non-zero baseline.
    is_block_week AND weeks_cur = 4 AND weeks_prev = 4 AND masons_prev_4w > 0
      AND masons_4w <= masons_prev_4w * (1 - p.drop_share) AS trig_masons,
    is_block_week AND weeks_cur = 4 AND weeks_prev = 4
      AND COALESCE(SAFE_DIVIDE(earnings_prev_4w, NULLIF(paid_prev_4w, 0)), 0) > 0
      AND COALESCE(SAFE_DIVIDE(earnings_4w, NULLIF(paid_4w, 0)), 0)
          <= SAFE_DIVIDE(earnings_prev_4w, NULLIF(paid_prev_4w, 0)) * (1 - p.drop_share) AS trig_earnings
  FROM ratios r
  CROSS JOIN params p
),

-- Focus: the units furthest behind their SQM-E target over the last four
-- complete weeks, ranked within each manager (within the country where there
-- are no managers). Nothing else decides who appears: a CSO or mason
-- shortage shows up here through its effect on output, never as an input.
-- Ranked on block weeks only; every other row sits in its own partition.
ranked AS (
  SELECT s.*,
    IF(s.is_block_week AND s.level IN ('territory', 'branch'),
       ROW_NUMBER() OVER (PARTITION BY s.country, s.level, s.manager, s.is_block_week, s.week_start
                          ORDER BY IF(s.weeks_cur = 4, s.sqme_gap_4w, NULL) DESC, s.name),
       NULL) AS focus_rank
  FROM scored s
),

focus_state AS (
  SELECT r.*,
    r.is_block_week AND r.level IN ('territory', 'branch') AND r.weeks_cur = 4 AND r.focus_rank <= p.top_n AND COALESCE(r.sqme_gap_4w, 0) > 0 AS is_focus
  FROM ranked r
  CROSS JOIN params p
),

-- Persistence: how many consecutive block weeks a unit has been in focus.
islands AS (
  SELECT *,
    ROW_NUMBER() OVER (PARTITION BY country, level, name, is_block_week ORDER BY week_start)
      - ROW_NUMBER() OVER (PARTITION BY country, level, name, is_block_week, is_focus ORDER BY week_start) AS island
  FROM focus_state
),

focus AS (
  SELECT *,
    IF(is_focus, ROW_NUMBER() OVER (PARTITION BY country, level, name, is_block_week, is_focus, island ORDER BY week_start), 0) AS focus_weeks,
    CASE
      WHEN NOT is_block_week THEN NULL
      WHEN sqme_target_4w IS NULL OR sqme_target_4w = 0 THEN NULL
      WHEN COALESCE(pct_sqme_4w, 0) <= LEAST(COALESCE(pct_sales_4w, 9), COALESCE(pct_coll_4w, 9)) THEN 'built'
      WHEN COALESCE(pct_coll_4w, 9) <= COALESCE(pct_sales_4w, 9) THEN 'collected'
      ELSE 'sold'
    END AS weakest_4w
  FROM islands
),

-- Every row, complete or not, carries the four-week comparison and focus
-- state as at the latest complete single week on or before its last week, so
-- an in-progress week never moves the list. Rows are ordered by their last
-- week with the block week itself first, and the most recent block week's
-- values are carried forward.
carried AS (
  SELECT *,
    LAST_VALUE(IF(is_block_week, STRUCT(
      week_end AS focus_as_of, weeks_cur AS weeks_4w,
      masons_4w, masons_prev_4w, epm_4w, epm_prev_4w,
      built_4w, built_prev_4w, target_4w, target_prev_4w, pct_build_4w, pct_build_prev_4w,
      sqme_built_4w, sqme_target_4w, pct_sqme_4w, pct_sqme_prev_4w, sqme_gap_4w, sqme_gap_prev_4w,
      sold_4w, sold_prev_4w, sales_target_4w, pct_sales_4w, pct_sales_prev_4w,
      coll_4w, coll_prev_4w, pct_coll_4w, pct_coll_prev_4w,
      focus_rank, is_focus, focus_weeks, trig_masons, trig_earnings, weakest_4w), NULL) IGNORE NULLS)
    OVER (PARTITION BY country, level, name ORDER BY last_week_start, IF(is_block_week, 0, 1)
          ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS f
  FROM focus
)

-- -----------------------------------------------------------------------------
-- Final shape.
-- -----------------------------------------------------------------------------
SELECT
  s.country,
  s.level, s.name, s.parent, s.manager, s.n_territories,
  s.month, FORMAT_DATE('%B %Y', s.month) AS month_label,
  s.week_key, s.n_weeks, s.is_single_week, s.week_no, s.week_start, s.week_end,
  IF(s.is_single_week,
     CONCAT('W', CAST(s.week_no AS STRING), ' (', FORMAT_DATE('%d', s.week_start), '-', FORMAT_DATE('%d %b', s.week_end), ')'),
     CONCAT('W', ARRAY_TO_STRING(REGEXP_EXTRACT_ALL(s.week_key, r'\d'), '+W'))) AS week_label,
  s.is_complete_week,
  s.is_single_week AND s.week_start <= CURRENT_DATE() AND s.week_end >= CURRENT_DATE() AS is_current_week,
  s.has_targets, s.n_targeted,
  s.contracts_sold, s.sqme_sold, s.contracts_collected, s.sqme_collected, s.contracts_built, s.sqme_built,
  s.masons_on_timesheet, s.masons_assigned, s.masons_total, s.masons_onsite, s.masons_built,
  s.masons_paid, s.mason_earnings, s.earnings_per_mason, s.approval_rate,
  s.csos_active, s.min_csos, s.csos_short, s.units_short_csos,
  s.build_target_week, s.sqme_target_week, s.sales_target_week,
  s.min_masons, s.masons_to_hire, s.territories_short,
  s.pct_of_build_target, s.pct_of_sqme_target, s.pct_of_sales_target, s.pct_of_coll_target,
  s.builds_per_mason, s.usual_builds_per_mason, s.pct_build_productivity, s.productivity_gap,
  s.pct_sales_productivity, s.pct_coll_productivity, s.cso_output_gap,
  s.build_coll_ratio,
  s.collected_not_built,
  -- Constraint and diagnosis, from this row's own weeks. Diagnose, never instruct.
  s.constraint_type,
  CASE s.constraint_type
    WHEN 'NO TARGET SET' THEN 'No targets set for this month'
    WHEN 'NO DATA' THEN 'No customers paid and nothing was built'
    WHEN 'BUILD MORE' THEN 'Building is the weak link'
    WHEN 'SELL MORE' THEN 'Selling is the weak link'
    ELSE 'Selling and building are in balance'
  END AS constraint_reading,
  CASE s.constraint_type
    WHEN 'BUILD MORE' THEN s.mason_reading
    WHEN 'SELL MORE' THEN IF(COALESCE(s.pct_coll_productivity, 0) < COALESCE(s.pct_sales_productivity, 0),
      'Customers signed but have not paid yet.', s.cso_reading)
    WHEN 'BALANCED' THEN IF(COALESCE(s.pct_build_productivity, 0) < COALESCE(s.pct_sales_productivity, 0),
      s.mason_reading, s.cso_reading)
    ELSE NULL
  END AS diagnosis,
  -- Four-week comparison and focus state as at the latest complete week.
  s.f.focus_as_of,
  s.f.weeks_4w,
  s.f.masons_4w, s.f.masons_prev_4w, s.f.epm_4w, s.f.epm_prev_4w,
  s.f.built_4w, s.f.built_prev_4w, s.f.target_4w, s.f.target_prev_4w, s.f.pct_build_4w, s.f.pct_build_prev_4w,
  s.f.sqme_built_4w, s.f.sqme_target_4w, s.f.pct_sqme_4w, s.f.pct_sqme_prev_4w,
  s.f.sqme_gap_4w, s.f.sqme_gap_prev_4w,
  s.f.sold_4w, s.f.sold_prev_4w, s.f.sales_target_4w, s.f.pct_sales_4w, s.f.pct_sales_prev_4w,
  s.f.coll_4w, s.f.coll_prev_4w, s.f.pct_coll_4w, s.f.pct_coll_prev_4w,
  s.f.focus_rank,
  COALESCE(s.f.is_focus, FALSE) AS is_focus,
  COALESCE(s.f.focus_weeks, 0) AS focus_weeks,
  COALESCE(s.f.focus_weeks, 0) = 1 AS is_new_focus,
  COALESCE(s.f.trig_masons, FALSE) AS trig_masons,
  COALESCE(s.f.trig_earnings, FALSE) AS trig_earnings,
  s.f.weakest_4w,
  -- The card sentence: which side of the chain is furthest behind over the
  -- four-week block, then whether that is people or performance, read on
  -- this row's own weeks.
  CASE s.f.weakest_4w
    WHEN 'built' THEN CONCAT(IF(COALESCE(s.f.pct_sqme_4w, 0) < p.almost_nothing,
      'Customers are signing and paying, but almost nothing is being built. ',
      'Customers are signing and paying, but building is furthest behind. '), s.mason_reading)
    WHEN 'collected' THEN 'Customers are signing, but too few have paid, so there is little to build.'
    WHEN 'sold' THEN CONCAT('Building keeps up with what is sold, but too few new customers are signing. ', s.cso_reading)
    ELSE 'No targets set for these weeks, so there is nothing to compare against.'
  END AS takeaway,
  -- The query time. The page prints it as "Data as at".
  CURRENT_TIMESTAMP() AS built_at
FROM carried s
CROSS JOIN params p
);

-- The old name, for ad hoc queries: every country, 18 months back. The app
-- calls the function directly with the selected country and month.
CREATE OR REPLACE VIEW `earth-enable-main.raw_data_from_salesforce.territory_capacity_week_v1` AS
SELECT * FROM `earth-enable-main.raw_data_from_salesforce.capacity_week`(NULL, NULL);
