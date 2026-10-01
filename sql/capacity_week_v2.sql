-- =============================================================================
-- raw_data_from_salesforce.capacity_week_v2(p_country, p_month, p_from)
-- raw_data_from_salesforce.territory_capacity_period_v2  = capacity_week_v2(NULL, NULL, NULL)
--
-- Feeds the country workspaces (Overview, Sales and collections, Masons) for
-- Rwanda, Uganda and Kenya. A second version beside capacity_week, which the
-- Classic toolkit's capacity page still reads and which is never changed.
--
-- One row per country x level x name x period month x week set. Rwanda's
-- levels are territory, district, manager and country; Uganda and Kenya have
-- branches only, so their levels are branch and country. Within a month the
-- fifteen week sets are the same as capacity_week ('1'..'4', '12' .. '1234'),
-- each with its own distinct counts. NEW in v2 is the quarter set: week_key
-- 'Q' on the quarter's first month covers every started week of its three
-- months, with distinct mason and CSO counts taken over the whole quarter, so
-- the app never sums months. A mason working in two months of a quarter is
-- one person.
--
-- What else v2 adds over capacity_week, all decided here and only here:
--   revenue            contract value (total_amount, Salesforce's
--                      total_payment_amount_c) of the builds completed in
--                      the period, the same completion date rule as
--                      contracts_built. Local currency. NOT cash. The same
--                      figure, at the same grain, as the view
--                      completed_value_daily (sql/completed_value_daily.sql),
--                      the company's live revenue: jobs of the Contractor
--                      record type are left out of the base, so revenue and
--                      builds always count the same set of jobs.
--   cash_received      every instalment (cash_received_c) paid in the
--                      period, dated by date_paid_c, on any contract in the
--                      unit, including contracts signed before 2024 and
--                      plans not yet settled; refunds and the Contractor
--                      record type excluded. Kept apart
--                      from revenue and never labelled as it.
--   revenue_target     qb_reporting.branch_financial_targets, metric
--                      'revenue', at branch grain (Rwanda: district), the
--                      same month's target like every other target here.
--                      Territory and manager rows carry none.
--   sqme_sales_target  sqme_target x 1.3, and sqme_target as the SQM-E
--                      collections target, mirroring the contract rule.
--   floors_built, plasters_built, other_built   the builds by product.
--   paint_sold, paint_sqme_sold, paint_collected, paint_sqme_collected,
--   paint_built, paint_sqme_built   paint beside the scored figures. Every
--                     sqme_* column is Floor plus Plaster only (the scored
--                     products); paint, repair, house and unknown are out.
--                     Product comes from product_class() (sql/product_class.sql).
--   builds_on_time, builds_late                 all_opportunities_master.build_on_time.
--   sold_then_paid     contracts signed in the period that have since crossed
--                      the payment gate ("signed to paid").
--   collected_today    contracts that crossed the gate on the current date, in
--                      whichever set holds today.
--   qa_measured, qa_passed   first QA check per job and stage (compaction,
--                      screed, prior paint), a job passes when none of its
--                      first checks was a non-pass: the rule of
--                      quality_monthly, dated by the first check.
--   masons_productive  masons whose approved pay in the set met the country's
--                      weekly bar times the Wednesdays in the set.
--   region             Rwanda territories, districts and managers: the sales
--                      managers' two-way split named by compass region, for
--                      the MARGA meeting page (see region_of_manager).
--   contracts_per_cso, usual_contracts_per_cso   contracts signed per active
--                      CSO, and the standard: sales target over the CSO
--                      requirement.
--   rank_sqme, rank_prev, rank_move   ranking on SQM-E built against target
--                      within the level (1 is best), and the change against
--                      the previous period of the same shape (the previous
--                      month with the same week set, or the previous quarter).
--                      Computed here, never in the app.
--
-- Phases. Contracts (sold, collected, built, backlog, on site) count phase 1
-- only, one job per house. SQM-E, revenue and cash count every phase, because
-- the SQM-E targets are set on all phases and a follow-on phase is priced,
-- paid and collected on its own. This follows the CSO views, not capacity_week.
-- Floor collections use COALESCE(date_50pct_paid, date_100pct_paid), the
-- documented fix, and a collection date before signing is ignored.
--
-- Window: p_from to p_month (p_from defaults to six months before p_month; the
-- app passes January of the year so the trend runs January to date). The
-- window always reaches at least one month before p_month so the ranking
-- movement has a previous period. With no p_month: 18 months back.
--
-- The shape rules of capacity_week still apply: filters pushed into the raw
-- scans, each raw table scanned at most twice, one per-person aggregate.
-- The four-week comparison, focus ranking and takeaways of capacity_week are
-- not here; the country workspaces do not use them.
--
-- Deploy: run this file in the BigQuery console or through the connector. The
-- app ships the same body inline (src/generated/sql.ts, built from this file
-- by scripts/build-sql.mjs) so it works before the function exists; set
-- CAPACITY_USE_FUNCTIONS=1 once it does.
-- =============================================================================

CREATE OR REPLACE TABLE FUNCTION `earth-enable-main.raw_data_from_salesforce.capacity_week_v2`(p_country STRING, p_month DATE, p_from DATE)
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
    90   AS onsite_days,       -- a job is live for this long after it became buildable
    365  AS backlog_days,      -- collected_not_built only counts contracts collected within this many days
    spine_from,
    spine_to,
    DATE_SUB(spine_from, INTERVAL 70 DAY) AS ts_from,
    DATE_SUB(spine_from, INTERVAL 365 DAY) AS opp_from
  FROM (
    SELECT
      LEAST(
        DATE_TRUNC(COALESCE(p_from, DATE_SUB(COALESCE(p_month, CURRENT_DATE()), INTERVAL IF(p_month IS NULL, 18, 6) MONTH)), MONTH),
        DATE_TRUNC(DATE_SUB(COALESCE(p_month, CURRENT_DATE()), INTERVAL 1 MONTH), MONTH)) AS spine_from,
      LEAST(COALESCE(DATE_TRUNC(p_month, MONTH), DATE_TRUNC(CURRENT_DATE(), MONTH)), DATE_TRUNC(CURRENT_DATE(), MONTH)) AS spine_to
  )
),

-- Per-country rules, defined once: the unit of management, the CSOs each unit
-- should have, and the weekly productive bar in local currency (copied from
-- productive_masons_monthly, change them there first).
country_rules AS (
  SELECT * FROM UNNEST([
    STRUCT('Rwanda' AS country, 'territory' AS unit_level, 5.0 AS csos_per_unit, 25000.0 AS weekly_threshold, 'RWF' AS currency),
    STRUCT('Uganda', 'branch', 9.0, 62500.0, 'UGX'),
    STRUCT('Kenya', 'branch', 7.0, 2500.0, 'KES')
  ])
),

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

-- The region the MARGA meeting splits Rwanda's territories by. It is the
-- sales managers' split (the manager column of tl_bonus_targets, two groups),
-- and each group is named by the compass region most of its territories
-- carry in bonus_tl_payout_by_month_territory: mostly 'East Rwanda' reads
-- 'East and North', otherwise 'South and West'. No manager, region or
-- territory is typed here. Uganda and Kenya carry no region.
region_of_manager AS (
  SELECT t.manager,
    IF(COUNTIF(b.region = 'East Rwanda') >= COUNTIF(b.region = 'South Rwanda'), 'East and North', 'South and West') AS region
  FROM (
    SELECT territory, ANY_VALUE(manager HAVING MAX month) AS manager
    FROM tl_targets
    WHERE territory IS NOT NULL AND manager IS NOT NULL
    GROUP BY 1
  ) t
  LEFT JOIN (
    SELECT territory, ANY_VALUE(region HAVING MAX month) AS region
    FROM `earth-enable-main.raw_data_from_salesforce.bonus_tl_payout_by_month_territory`
    WHERE country = 'Rwanda' AND territory IS NOT NULL
    GROUP BY 1
  ) b ON b.territory = t.territory
  GROUP BY 1
),
members AS (
  SELECT country, unit_level AS level, unit AS name, district AS parent, manager, unit FROM dim
  UNION ALL SELECT country, 'district', district, CAST(NULL AS STRING), CAST(NULL AS STRING), unit FROM dim WHERE unit_level = 'territory'
  UNION ALL SELECT country, 'manager', manager, NULL, NULL, unit FROM dim WHERE unit_level = 'territory'
  UNION ALL SELECT country, 'country', country, NULL, NULL, unit FROM dim
),
-- The region rides in here by territory (every member row carries its
-- territory as `unit`), so the lookup is joined once, never per level.
names AS (
  SELECT m.country, m.level, m.name, ANY_VALUE(m.parent) AS parent, ANY_VALUE(m.manager) AS manager,
    ANY_VALUE(IF(m.level = 'country', NULL, rt.region)) AS region, COUNT(*) AS n_territories
  FROM members m
  LEFT JOIN (
    SELECT t.territory, r.region
    FROM (SELECT territory, ANY_VALUE(manager HAVING MAX month) AS manager
          FROM tl_targets
          WHERE territory IS NOT NULL AND manager IS NOT NULL GROUP BY 1) t
    JOIN region_of_manager r ON r.manager = t.manager
  ) rt ON rt.territory = m.unit
  GROUP BY 1, 2, 3
),

targets AS (
  SELECT 'Rwanda' AS country, territory AS unit, month, build_target, sqme_target, min_productive_masons, min_build_productivity
  FROM tl_targets
  WHERE territory IS NOT NULL
  UNION ALL
  SELECT country, branch, month, build_target, sqme_target, min_productive_masons, min_build_productivity
  FROM `earth-enable-main.raw_data_from_salesforce.branch_capacity_targets`
),

-- Revenue targets live at branch grain (Rwanda: district) in the finance
-- targets table. Rolled up to the country; nothing below the branch.
rev_targets AS (
  SELECT country, level, name, month, SUM(target_value) AS revenue_target
  FROM (
    SELECT country, IF(country = 'Rwanda', 'district', 'branch') AS level, branch AS name, month, target_value
    FROM `earth-enable-main.qb_reporting.branch_financial_targets`
    WHERE metric = 'revenue' AND (p_country IS NULL OR country = p_country)
    UNION ALL
    SELECT country, 'country', country, month, target_value
    FROM `earth-enable-main.qb_reporting.branch_financial_targets`
    WHERE metric = 'revenue' AND (p_country IS NULL OR country = p_country)
  )
  GROUP BY 1, 2, 3, 4
),

-- -----------------------------------------------------------------------------
-- Calendar: the four windows of each month, the fifteen ways to pick them,
-- and the quarter.
-- -----------------------------------------------------------------------------
weeksets AS (
  SELECT week_key, weeks FROM UNNEST(ARRAY<STRUCT<week_key STRING, weeks ARRAY<INT64>>>[
    ('1',[1]), ('2',[2]), ('3',[3]), ('4',[4]),
    ('12',[1,2]), ('13',[1,3]), ('14',[1,4]), ('23',[2,3]), ('24',[2,4]), ('34',[3,4]),
    ('123',[1,2,3]), ('124',[1,2,4]), ('134',[1,3,4]), ('234',[2,3,4]), ('1234',[1,2,3,4])
  ])
),

calendar AS (
  SELECT month, week_no, week_start, week_end,
    (SELECT COUNTIF(EXTRACT(DAYOFWEEK FROM d) = 4) FROM UNNEST(GENERATE_DATE_ARRAY(week_start, week_end)) d) AS wednesdays,
    COUNT(*) OVER (PARTITION BY month) AS weeks_started
  FROM (
    SELECT mth AS month, w AS week_no,
      DATE_ADD(mth, INTERVAL (w - 1) * 7 DAY) AS week_start,
      IF(w = 4, LAST_DAY(mth), DATE_ADD(mth, INTERVAL w * 7 - 1 DAY)) AS week_end
    FROM params p,
      UNNEST(GENERATE_DATE_ARRAY(p.spine_from, p.spine_to, INTERVAL 1 MONTH)) mth,
      UNNEST([1, 2, 3, 4]) w
    WHERE DATE_ADD(mth, INTERVAL (w - 1) * 7 DAY) <= CURRENT_DATE()   -- the week has started
  )
),

-- Every (period month, week set) and the calendar weeks inside it. Month sets
-- as before; the quarter set holds every started week of the three months.
set_calendar AS (
  SELECT c.month AS period_month, ws.week_key, ARRAY_LENGTH(ws.weeks) AS set_size,
    c.month AS wk_month, c.week_no, c.week_start, c.week_end, c.wednesdays, c.weeks_started
  FROM calendar c
  JOIN weeksets ws ON c.week_no IN UNNEST(ws.weeks)
  UNION ALL
  SELECT DATE_TRUNC(c.month, QUARTER), 'Q', NULL, c.month, c.week_no, c.week_start, c.week_end, c.wednesdays, NULL
  FROM calendar c
  CROSS JOIN params p
  WHERE DATE_TRUNC(c.month, QUARTER) >= p.spine_from
),

-- One row per period x set, keeping month sets whose every week has started.
sets AS (
  SELECT period_month AS month, week_key,
    COUNT(*) AS n_weeks,
    MIN(week_start) AS week_start,
    MAX(week_end) AS week_end,
    SUM(wednesdays) AS wednesdays,
    LOGICAL_AND(week_end < CURRENT_DATE()) AS is_complete,
    week_key = 'Q' AS is_quarter,
    week_key != 'Q' AND COUNT(*) = ANY_VALUE(weeks_started) AS is_whole_month,
    ARRAY_AGG(STRUCT(wk_month, week_no) ORDER BY week_end DESC LIMIT 1)[OFFSET(0)] AS last_week
  FROM set_calendar
  GROUP BY 1, 2
  HAVING week_key = 'Q' OR COUNT(*) = ANY_VALUE(set_size)
),

-- The spine carries the name's attributes so metrics need not join names
-- again (every reference to a CTE is another inlining of dim).
spine AS (
  SELECT n.country, n.level, n.name, n.parent, n.manager, n.region, n.n_territories, s.*
  FROM names n
  CROSS JOIN sets s
),

-- -----------------------------------------------------------------------------
-- Raw rows: country and window pushed into the scans themselves.
-- -----------------------------------------------------------------------------
-- First QA check per job and stage, by QA staff, then the job's verdict: it
-- passes when none of its first checks was a non-pass. The rule of
-- quality_monthly. Dated by the first check.
qa_opp AS (
  SELECT opportunity_id, MIN(eval_date) AS qa_date, COUNTIF(decision_c IS DISTINCT FROM 'Pass') = 0 AS qa_passed
  FROM (
    SELECT q.opportunity_name_c AS opportunity_id, q.date_c AS eval_date, q.decision_c,
      ROW_NUMBER() OVER (PARTITION BY q.opportunity_name_c,
        CASE WHEN rt.name LIKE 'Compaction%' THEN 'Compaction' WHEN rt.name LIKE 'Screed%' THEN 'Screed' ELSE 'PriorPaint' END
        ORDER BY q.date_c, q.created_date) AS rn
    FROM `earth-enable-main.salesforce.quality_assurance_survey_c` q
    JOIN `earth-enable-main.salesforce.record_type` rt ON rt.id = q.record_type_id
    CROSS JOIN params p
    WHERE NOT q._fivetran_deleted AND NOT COALESCE(q.is_deleted, FALSE)
      AND q.opportunity_name_c IS NOT NULL AND q.date_c IS NOT NULL
      AND q.date_c >= DATE_SUB(p.spine_from, INTERVAL 6 MONTH) AND q.date_c <= CURRENT_DATE()
      AND (rt.name LIKE 'Compaction%' OR rt.name LIKE 'Screed%' OR rt.name LIKE 'Prior Paint%')
      AND q.type_c IS NOT NULL
      AND REGEXP_CONTAINS(q.type_c, r'(?i)quality|QA|Auditor')
      AND NOT REGEXP_CONTAINS(q.type_c, r'(?i)R&D')
  )
  WHERE rn = 1
  GROUP BY 1
),

-- The Contractor record type: not our builds, out of every count (the rule of
-- completed_value_daily). About 150 jobs, all in Rwanda.
contractor AS (
  SELECT o.id
  FROM `earth-enable-main.salesforce.opportunity` o
  JOIN `earth-enable-main.salesforce.record_type` rt ON rt.id = o.record_type_id
  WHERE rt.name = 'Contractor'
),

-- Cash received: every instalment (cash_received_c), in the month it was paid
-- (date_paid_c), whatever the state of the payment plan it belongs to. A plan
-- (payment_c) only turns Paid once it is settled, so counting plans put a
-- plan's whole value in the month it closed and missed every instalment on a
-- plan still open. Refunded instalments are not cash received.
-- Read straight off the opportunity and its location rather than through
-- all_opportunities_master, which drops contracts signed before 2024: money
-- paid this month on an old contract is still money received this month. The
-- unit is placed the way base places it. Every product and phase except Full
-- House, which the page leaves out everywhere, and the Contractor record type,
-- out of every count here; a unit outside dim (no targets, e.g. Kamonyi C) has
-- no row to land on.
cash_lines AS (
  SELECT tt.country, tt.unit, x.d, x.amount
  FROM (
    SELECT
      l.country_c AS country,
      CASE l.country_c
        WHEN 'Rwanda' THEN sec.territory_c
        WHEN 'Uganda' THEN COALESCE(NULLIF(TRIM(l.branch_c), ''), REGEXP_EXTRACT(m.branch, r'^(.+) Branch$'))
        WHEN 'Kenya' THEN COALESCE(NULLIF(TRIM(l.branch_c), ''), NULLIF(TRIM(l.district_c), ''), m.location_district)
      END AS unit,
      cr.date_paid_c AS d,
      IFNULL(cr.installment_amount_c, 0) AS amount
    FROM `earth-enable-main.salesforce.cash_received_c` cr
    CROSS JOIN params w
    JOIN `earth-enable-main.salesforce.payment_c` p ON p.id = cr.payment_c
    JOIN `earth-enable-main.salesforce.opportunity` o ON o.id = p.opportunity_c
    JOIN `earth-enable-main.salesforce.location_c` l ON l.id = o.umudugudu_c
    LEFT JOIN `earth-enable-main.salesforce.location_c` sec ON sec.id = l.sector_c
    LEFT JOIN `earth-enable-main.raw_data_from_salesforce.all_opportunities_master` m ON m.opportunity_id = o.id
    LEFT JOIN contractor ct ON ct.id = o.id
    WHERE ct.id IS NULL
      AND NOT cr._fivetran_deleted AND NOT COALESCE(cr.is_deleted, FALSE)
      AND COALESCE(cr.status_c, '') != 'Refunded'
      AND NOT p._fivetran_deleted AND NOT COALESCE(p.is_deleted, FALSE)
      AND NOT o._fivetran_deleted
      AND `earth-enable-main.raw_data_from_salesforce.product_class`(COALESCE(o.product_interest_c, o.new_product_interest_c)) != 'House'
      AND l.country_c IN ('Rwanda', 'Uganda', 'Kenya')
      AND (p_country IS NULL OR l.country_c = p_country)
      AND cr.date_paid_c BETWEEN w.spine_from AND CURRENT_DATE()
  ) x
  JOIN dim tt ON tt.country = x.country AND tt.unit = x.unit
),

-- Every contract of every phase in the country and window, placed in its unit.
base AS (
  SELECT x.* FROM (
    SELECT
      m.opportunity_id,
      m.location_country AS country,
      CASE m.location_country
        WHEN 'Rwanda' THEN m.location_territory
        WHEN 'Uganda' THEN COALESCE(NULLIF(TRIM(l.branch_c), ''), REGEXP_EXTRACT(m.branch, r'^(.+) Branch$'))
        WHEN 'Kenya' THEN COALESCE(NULLIF(TRIM(l.branch_c), ''), NULLIF(TRIM(l.district_c), ''), m.location_district)
      END AS unit,
      SAFE_CAST(m.opportunity_phase AS INT64) = 1 AS is_job,
      IFNULL(m.adjusted_square_meters, 0) AS sqme,   -- already SQM-E weighted
      IFNULL(m.total_amount, 0) AS total_amount,
      pc.product,   -- the company's classification (sql/product_class.sql), never the master view's own column
      m.cso_id,
      m.mason_id,
      m.customer_signed_date AS signed_date,
      m.completed_date,
      IF(cd.collected_date < m.customer_signed_date, NULL, cd.collected_date) AS collected_date,
      COALESCE(IF(cd.collected_date < m.customer_signed_date, NULL, cd.collected_date), m.customer_signed_date) AS buildable_date,
      m.associated_project_status AS assoc_status,
      m.opportunity_stage AS stage,
      m.build_on_time,
      q.qa_date, q.qa_passed
    FROM `earth-enable-main.raw_data_from_salesforce.all_opportunities_master` m
    CROSS JOIN params p
    LEFT JOIN `earth-enable-main.salesforce.location_c` l ON l.id = m.location_id AND m.location_country != 'Rwanda'
    LEFT JOIN qa_opp q ON q.opportunity_id = m.opportunity_id
    LEFT JOIN contractor ct ON ct.id = m.opportunity_id,
    UNNEST([STRUCT(`earth-enable-main.raw_data_from_salesforce.product_class`(COALESCE(m.product_interest, m.new_product_interest)) AS product)]) AS pc,
    UNNEST([IF(pc.product = 'Floor', COALESCE(m.date_50pct_paid, m.date_100pct_paid), m.date_100pct_paid)]) AS cd_date,
    UNNEST([STRUCT(cd_date AS collected_date)]) AS cd
    WHERE m.location_country IN ('Rwanda', 'Uganda', 'Kenya')
      AND (p_country IS NULL OR m.location_country = p_country)
      AND pc.product != 'House'
      AND ct.id IS NULL
      AND (m.customer_signed_date >= p.spine_from OR m.completed_date >= p.spine_from
           OR cd_date >= p.opp_from
           OR COALESCE(cd_date, m.customer_signed_date) >= DATE_SUB(p.spine_from, INTERVAL p.onsite_days DAY)
           OR q.qa_date >= p.spine_from)
  ) x
  JOIN dim tt ON tt.country = x.country AND tt.unit = x.unit
),

ts_facts AS (
  SELECT t.country, tt.unit, e.d, DATE_TRUNC(e.d, MONTH) AS month,
    LEAST(CAST(CEIL(EXTRACT(DAY FROM e.d) / 7) AS INT64), 4) AS week_no,
    e.kind, t.mason_id AS person_id, 0.0 AS sqme, e.amount, CAST(NULL AS INT64) AS flag, CAST(NULL AS STRING) AS product, FALSE AS is_job
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

-- -----------------------------------------------------------------------------
-- One fact stream: (unit, day, kind, person, sqme, amount, flag, product, is_job).
--   sold, collected, built, qa, cash   from the contract, dated by that event
--   onsite, backlog                    as at a week's end
--   ts, pay                            from the timesheets
-- -----------------------------------------------------------------------------
facts AS (
  SELECT b.country, b.unit, e.d, DATE_TRUNC(e.d, MONTH) AS month,
    LEAST(CAST(CEIL(EXTRACT(DAY FROM e.d) / 7) AS INT64), 4) AS week_no,
    e.kind, e.person_id, e.sqme, e.amount, e.flag, e.product, e.is_job
  FROM base b
  CROSS JOIN params p,
    UNNEST(ARRAY_CONCAT(
      [STRUCT('sold' AS kind, b.signed_date AS d, b.cso_id AS person_id, b.sqme AS sqme, 0.0 AS amount,
              IF(b.collected_date IS NOT NULL, 1, 0) AS flag, b.product AS product, b.is_job AS is_job),
       STRUCT('collected', b.collected_date, b.cso_id, b.sqme, 0.0, CAST(NULL AS INT64), b.product, b.is_job),
       STRUCT('built', b.completed_date, b.mason_id, b.sqme, b.total_amount, b.build_on_time, b.product, b.is_job),
       STRUCT('qa', b.qa_date, CAST(NULL AS STRING), 0.0, 0.0, IF(b.qa_passed, 1, 0), CAST(NULL AS STRING), b.is_job)]
    )) e
  WHERE e.d >= p.spine_from AND e.d <= CURRENT_DATE()

  UNION ALL

  -- Cash, one row per instalment, from cash_lines above.
  SELECT country, unit, d, DATE_TRUNC(d, MONTH), LEAST(CAST(CEIL(EXTRACT(DAY FROM d) / 7) AS INT64), 4),
    'cash', CAST(NULL AS STRING), 0.0, amount, CAST(NULL AS INT64), CAST(NULL AS STRING), FALSE
  FROM cash_lines

  UNION ALL

  SELECT b.country, b.unit, c.week_end AS d, c.month, c.week_no,
    kind, IF(kind = 'onsite', b.mason_id, NULL) AS person_id, 0.0 AS sqme, 0.0 AS amount, CAST(NULL AS INT64), CAST(NULL AS STRING), TRUE
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
  WHERE b.is_job

  UNION ALL

  SELECT country, unit, d, month, week_no, kind, person_id, sqme, amount, flag, product, is_job FROM ts_facts
),

-- -----------------------------------------------------------------------------
-- Rollups per (country, level, name, period month, week set). Distinct counts
-- are taken here, at the set and level, never added across weeks, months or
-- units.
-- -----------------------------------------------------------------------------
set_weeks AS (
  SELECT s.country, s.level, s.name, s.month, s.week_key, s.n_weeks, s.wednesdays, m.unit,
    sc.wk_month, sc.week_no,
    sc.wk_month = s.last_week.wk_month AND sc.week_no = s.last_week.week_no AS is_last
  FROM spine s
  JOIN members m ON m.country = s.country AND m.level = s.level AND m.name = s.name
  JOIN set_calendar sc ON sc.period_month = s.month AND sc.week_key = s.week_key
),

set_person AS (
  SELECT k.country, k.level, k.name, k.month, k.week_key, f.person_id,
    COUNTIF(f.kind = 'sold' AND f.is_job) AS sold,
    -- Scored SQM-E is Floor plus Plaster only (ceiling plaster is Plaster).
    -- Paint is counted beside it, never inside it; Repair, House, Other and
    -- Unknown are in neither.
    SUM(IF(f.kind = 'sold' AND f.product IN ('Floor', 'Plaster'), f.sqme, 0)) AS sqme_sold,
    COUNTIF(f.kind = 'sold' AND f.is_job AND f.product = 'Paint') AS paint_sold,
    SUM(IF(f.kind = 'sold' AND f.product = 'Paint', f.sqme, 0)) AS paint_sqme_sold,
    COUNTIF(f.kind = 'sold' AND f.is_job AND f.flag = 1) AS sold_then_paid,
    COUNTIF(f.kind = 'collected' AND f.is_job) AS collected,
    SUM(IF(f.kind = 'collected' AND f.product IN ('Floor', 'Plaster'), f.sqme, 0)) AS sqme_collected,
    COUNTIF(f.kind = 'collected' AND f.is_job AND f.product = 'Paint') AS paint_collected,
    SUM(IF(f.kind = 'collected' AND f.product = 'Paint', f.sqme, 0)) AS paint_sqme_collected,
    COUNTIF(f.kind = 'collected' AND f.is_job AND f.d = CURRENT_DATE()) AS collected_today,
    COUNTIF(f.kind = 'built' AND f.is_job) AS built,
    SUM(IF(f.kind = 'built' AND f.product IN ('Floor', 'Plaster'), f.sqme, 0)) AS sqme_built,
    COUNTIF(f.kind = 'built' AND f.is_job AND f.product = 'Paint') AS paint_built,
    SUM(IF(f.kind = 'built' AND f.product = 'Paint', f.sqme, 0)) AS paint_sqme_built,
    COUNTIF(f.kind = 'built' AND f.is_job AND f.product = 'Floor') AS floors_built,
    COUNTIF(f.kind = 'built' AND f.is_job AND f.product = 'Plaster') AS plasters_built,
    COUNTIF(f.kind = 'built' AND f.is_job AND COALESCE(f.product, '') NOT IN ('Floor', 'Plaster')) AS other_built,
    SUM(IF(f.kind = 'built', f.amount, 0)) AS revenue,
    COUNTIF(f.kind = 'built' AND f.is_job AND f.flag = 1) AS builds_on_time,
    COUNTIF(f.kind = 'built' AND f.is_job AND f.flag = 0) AS builds_late,
    SUM(IF(f.kind = 'cash', f.amount, 0)) AS cash_received,
    COUNTIF(f.kind = 'qa' AND f.is_job) AS qa_measured,
    COUNTIF(f.kind = 'qa' AND f.is_job AND f.flag = 1) AS qa_passed,
    LOGICAL_OR(f.kind IN ('sold', 'collected') AND f.person_id IS NOT NULL) AS is_cso,
    LOGICAL_OR(f.kind = 'built' AND f.person_id IS NOT NULL) AS built_any,
    LOGICAL_OR(f.kind = 'ts') AS has_ts,
    LOGICAL_OR(f.kind = 'pay') AS paid,
    SUM(IF(f.kind = 'pay', f.amount, 0)) AS earnings,
    LOGICAL_OR(f.kind = 'onsite' AND k.is_last) AS onsite_last,
    COUNTIF(f.kind = 'backlog' AND k.is_last) AS backlog,
    ANY_VALUE(k.wednesdays) AS wednesdays
  FROM set_weeks k
  JOIN facts f ON f.country = k.country AND f.unit = k.unit AND f.month = k.wk_month AND f.week_no = k.week_no
  GROUP BY 1, 2, 3, 4, 5, 6
),

set_agg AS (
  SELECT p.country, p.level, p.name, p.month, p.week_key,
    SUM(sold) AS contracts_sold, SUM(sqme_sold) AS sqme_sold, SUM(sold_then_paid) AS sold_then_paid,
    SUM(paint_sold) AS paint_sold, SUM(paint_sqme_sold) AS paint_sqme_sold,
    SUM(collected) AS contracts_collected, SUM(sqme_collected) AS sqme_collected, SUM(collected_today) AS collected_today,
    SUM(paint_collected) AS paint_collected, SUM(paint_sqme_collected) AS paint_sqme_collected,
    SUM(built) AS contracts_built, SUM(sqme_built) AS sqme_built,
    SUM(paint_built) AS paint_built, SUM(paint_sqme_built) AS paint_sqme_built,
    SUM(floors_built) AS floors_built, SUM(plasters_built) AS plasters_built, SUM(other_built) AS other_built,
    SUM(revenue) AS revenue, SUM(builds_on_time) AS builds_on_time, SUM(builds_late) AS builds_late,
    SUM(cash_received) AS cash_received,
    SUM(qa_measured) AS qa_measured, SUM(qa_passed) AS qa_passed,
    COUNTIF(is_cso) AS csos_active,
    COUNTIF(built_any) AS masons_built,
    COUNTIF(has_ts) AS masons_on_timesheet,
    COUNTIF(paid) AS masons_paid,
    COUNTIF(paid AND earnings >= cr.weekly_threshold * wednesdays) AS masons_productive,
    SUM(earnings) AS mason_earnings,
    COUNTIF(onsite_last) AS masons_onsite,
    COUNTIF(onsite_last AND NOT has_ts) AS masons_assigned,
    SUM(backlog) AS collected_not_built
  FROM set_person p
  JOIN country_rules cr ON cr.country = p.country
  GROUP BY 1, 2, 3, 4, 5
),

-- Targets per unit per set: each week takes a quarter of its own month's
-- target (September activity against September's target). The headcount
-- requirement is the month's figure,
-- averaged over the set's targeted weeks.
unit_target AS (
  SELECT k.country, k.level, k.name, k.month, k.week_key, k.unit,
    ANY_VALUE(k.n_weeks) AS n_weeks,
    COUNTIF(t.unit IS NOT NULL) AS weeks_targeted,
    SUM(t.build_target * 0.25) AS build_target,
    SUM(t.sqme_target * 0.25) AS sqme_target,
    AVG(t.min_productive_masons) AS min_masons,
    AVG(t.min_build_productivity) AS min_build_productivity,
    ANY_VALUE(cr.csos_per_unit) AS csos_per_unit
  FROM (SELECT DISTINCT country, level, name, month, week_key, n_weeks, unit, wk_month, week_no FROM set_weeks) k
  JOIN country_rules cr ON cr.country = k.country
  LEFT JOIN targets t ON t.country = k.country AND t.unit = k.unit AND t.month = k.wk_month
  GROUP BY 1, 2, 3, 4, 5, 6
),

-- Every shortfall is per unit, after what is in place, floored at zero, then
-- summed. Never SUM(min) - SUM(actual).
target_set AS (
  SELECT u.country, u.level, u.name, u.month, u.week_key,
    LOGICAL_OR(u.weeks_targeted > 0) AS has_targets,
    COUNTIF(u.weeks_targeted > 0) AS n_targeted,
    SUM(u.build_target) AS build_target,
    SUM(u.sqme_target) AS sqme_target,
    SUM(u.build_target) * 1.3 AS sales_target,
    SUM(u.sqme_target) * 1.3 AS sqme_sales_target,
    SUM(u.min_masons) AS min_masons,
    SUM(IF(u.weeks_targeted > 0, u.csos_per_unit, NULL)) AS min_csos,
    SUM(u.min_build_productivity * 0.25 * u.n_weeks * IFNULL(a.masons_on_timesheet, 0)) AS expected_builds,
    COALESCE(
      SAFE_DIVIDE(SUM(u.min_build_productivity * 0.25 * u.n_weeks * IFNULL(a.masons_on_timesheet, 0)),
                  SUM(IF(u.min_build_productivity IS NULL, 0, IFNULL(a.masons_on_timesheet, 0)))),
      AVG(u.min_build_productivity) * 0.25 * ANY_VALUE(u.n_weeks)) AS usual_builds_per_mason,
    SUM(GREATEST(u.min_masons - (IFNULL(a.masons_on_timesheet, 0) + IFNULL(a.masons_assigned, 0)), 0)) AS masons_to_hire,
    COUNTIF(u.min_masons > IFNULL(a.masons_on_timesheet, 0) + IFNULL(a.masons_assigned, 0)) AS territories_short,
    SUM(IF(u.weeks_targeted > 0, GREATEST(u.csos_per_unit - IFNULL(a.csos_active, 0), 0), NULL)) AS csos_short,
    COUNTIF(u.weeks_targeted > 0 AND u.csos_per_unit > IFNULL(a.csos_active, 0)) AS units_short_csos
  FROM unit_target u
  LEFT JOIN set_agg a ON a.level IN ('territory', 'branch') AND a.country = u.country AND a.name = u.unit AND a.month = u.month AND a.week_key = u.week_key
  GROUP BY 1, 2, 3, 4, 5
),

rev_set AS (
  SELECT s.country, s.level, s.name, s.month, s.week_key, SUM(r.revenue_target * 0.25) AS revenue_target
  FROM spine s
  JOIN set_calendar sc ON sc.period_month = s.month AND sc.week_key = s.week_key
  JOIN rev_targets r ON r.country = s.country AND r.level = s.level AND r.name = s.name AND r.month = sc.wk_month
  GROUP BY 1, 2, 3, 4, 5
),

-- -----------------------------------------------------------------------------
-- One row per spine row with every metric.
-- -----------------------------------------------------------------------------
metrics AS (
  SELECT
    s.country, s.level, s.name, s.parent, s.manager, s.region, s.n_territories,
    s.month, s.week_key, s.n_weeks, s.n_weeks = 1 AND NOT s.is_quarter AS is_single_week, s.is_quarter, s.is_whole_month,
    s.week_start, s.week_end, s.is_complete, s.wednesdays,
    IFNULL(g.has_targets, FALSE) AS has_targets,
    IFNULL(g.n_targeted, 0) AS n_targeted,
    IFNULL(a.contracts_sold, 0) AS contracts_sold,
    IFNULL(a.sqme_sold, 0) AS sqme_sold,
    IFNULL(a.sold_then_paid, 0) AS sold_then_paid,
    IFNULL(a.contracts_collected, 0) AS contracts_collected,
    IFNULL(a.sqme_collected, 0) AS sqme_collected,
    IFNULL(a.collected_today, 0) AS collected_today,
    IFNULL(a.contracts_built, 0) AS contracts_built,
    IFNULL(a.sqme_built, 0) AS sqme_built,
    IFNULL(a.paint_sold, 0) AS paint_sold,
    IFNULL(a.paint_sqme_sold, 0) AS paint_sqme_sold,
    IFNULL(a.paint_collected, 0) AS paint_collected,
    IFNULL(a.paint_sqme_collected, 0) AS paint_sqme_collected,
    IFNULL(a.paint_built, 0) AS paint_built,
    IFNULL(a.paint_sqme_built, 0) AS paint_sqme_built,
    IFNULL(a.floors_built, 0) AS floors_built,
    IFNULL(a.plasters_built, 0) AS plasters_built,
    IFNULL(a.other_built, 0) AS other_built,
    IFNULL(a.revenue, 0) AS revenue,
    IFNULL(a.builds_on_time, 0) AS builds_on_time,
    IFNULL(a.builds_late, 0) AS builds_late,
    IFNULL(a.cash_received, 0) AS cash_received,
    IFNULL(a.qa_measured, 0) AS qa_measured,
    IFNULL(a.qa_passed, 0) AS qa_passed,
    IFNULL(a.csos_active, 0) AS csos_active,
    IFNULL(a.masons_on_timesheet, 0) AS masons_on_timesheet,
    IFNULL(a.masons_paid, 0) AS masons_paid,
    IFNULL(a.masons_productive, 0) AS masons_productive,
    IFNULL(a.mason_earnings, 0) AS mason_earnings,
    IFNULL(a.masons_built, 0) AS masons_built,
    IFNULL(a.masons_onsite, 0) AS masons_onsite,
    IFNULL(a.masons_assigned, 0) AS masons_assigned,
    IFNULL(a.masons_on_timesheet, 0) + IFNULL(a.masons_assigned, 0) AS masons_total,
    IFNULL(a.collected_not_built, 0) AS collected_not_built,
    g.min_masons, g.masons_to_hire, IFNULL(g.territories_short, 0) AS territories_short,
    g.min_csos, g.csos_short, IFNULL(g.units_short_csos, 0) AS units_short_csos,
    g.build_target, g.sqme_target, g.sales_target, g.sqme_sales_target,
    g.expected_builds, g.usual_builds_per_mason,
    rv.revenue_target,
    cr.currency, cr.weekly_threshold
  FROM spine s
  JOIN country_rules cr ON cr.country = s.country
  LEFT JOIN set_agg a ON a.country = s.country AND a.level = s.level AND a.name = s.name AND a.month = s.month AND a.week_key = s.week_key
  LEFT JOIN target_set g ON g.country = s.country AND g.level = s.level AND g.name = s.name AND g.month = s.month AND g.week_key = s.week_key
  LEFT JOIN rev_set rv ON rv.country = s.country AND rv.level = s.level AND rv.name = s.name AND rv.month = s.month AND rv.week_key = s.week_key
),

ratios AS (
  SELECT m.*,
    SAFE_DIVIDE(mason_earnings, NULLIF(masons_paid, 0)) AS earnings_per_mason,
    SAFE_DIVIDE(contracts_built, build_target) AS pct_of_build_target,
    SAFE_DIVIDE(sqme_built, sqme_target) AS pct_of_sqme_target,
    SAFE_DIVIDE(contracts_sold, sales_target) AS pct_of_sales_target,
    SAFE_DIVIDE(sqme_sold, sqme_sales_target) AS pct_of_sqme_sales_target,
    SAFE_DIVIDE(contracts_collected, build_target) AS pct_of_coll_target,
    SAFE_DIVIDE(sqme_collected, sqme_target) AS pct_of_sqme_coll_target,
    SAFE_DIVIDE(revenue, revenue_target) AS pct_of_revenue_target,
    SAFE_DIVIDE(sold_then_paid, NULLIF(contracts_sold, 0)) AS pct_sold_then_paid,
    SAFE_DIVIDE(builds_on_time, NULLIF(builds_on_time + builds_late, 0)) AS pct_on_time,
    SAFE_DIVIDE(qa_passed, NULLIF(qa_measured, 0)) AS pct_qa_pass,
    SAFE_DIVIDE(masons_productive, NULLIF(masons_on_timesheet, 0)) AS pct_masons_productive,
    SAFE_DIVIDE(collected_not_built, NULLIF(masons_on_timesheet, 0)) AS waiting_per_mason,
    SAFE_DIVIDE(contracts_built, NULLIF(masons_on_timesheet, 0)) AS builds_per_mason,
    SAFE_DIVIDE(contracts_built, NULLIF(expected_builds, 0)) AS pct_build_productivity,
    SAFE_DIVIDE(SAFE_DIVIDE(contracts_sold, NULLIF(csos_active, 0)), SAFE_DIVIDE(sales_target, NULLIF(min_csos, 0))) AS pct_sales_productivity,
    SAFE_DIVIDE(SAFE_DIVIDE(contracts_collected, NULLIF(csos_active, 0)), SAFE_DIVIDE(build_target, NULLIF(min_csos, 0))) AS pct_coll_productivity,
    -- The per-CSO output and its standard: contracts signed per active CSO,
    -- against the sales target over the CSO requirement (the capacity pages).
    SAFE_DIVIDE(contracts_sold, NULLIF(csos_active, 0)) AS contracts_per_cso,
    SAFE_DIVIDE(sales_target, NULLIF(min_csos, 0)) AS usual_contracts_per_cso
  FROM metrics m
),

-- Ranking on SQM-E built against target, 1 is best, within the level for the
-- same period and set, among units with a target. The previous period of the
-- same shape is the previous month with the same week set, or the previous
-- quarter; where the window holds no such period the movement is null.
ranked AS (
  SELECT r.*,
    IF(r.level IN ('territory', 'district', 'branch') AND r.has_targets AND r.sqme_target > 0,
       RANK() OVER (PARTITION BY r.country, r.level, r.month, r.week_key, r.has_targets AND r.sqme_target > 0
                    ORDER BY r.pct_of_sqme_target DESC, r.name),
       NULL) AS rank_sqme
  FROM ratios r
),

moved AS (
  SELECT *,
    LAG(rank_sqme) OVER w AS rank_prev_raw,
    LAG(month) OVER w AS prev_month
  FROM ranked
  WINDOW w AS (PARTITION BY country, level, name, week_key ORDER BY month)
)

SELECT
  country, level, name, parent, manager, region, n_territories,
  month, FORMAT_DATE('%B %Y', month) AS month_label,
  week_key, n_weeks, is_single_week, is_quarter, is_whole_month,
  CASE
    WHEN is_quarter THEN CONCAT('Q', CAST(EXTRACT(QUARTER FROM month) AS STRING), ' ', CAST(EXTRACT(YEAR FROM month) AS STRING))
    WHEN is_whole_month THEN FORMAT_DATE('%B %Y', month)
    ELSE CONCAT('W', ARRAY_TO_STRING(REGEXP_EXTRACT_ALL(week_key, r'\d'), '+W'), ' of ', FORMAT_DATE('%B %Y', month))
  END AS period_label,
  week_start AS period_start, week_end AS period_end, is_complete, wednesdays,
  has_targets, n_targeted, currency,
  contracts_sold, sqme_sold, sold_then_paid, pct_sold_then_paid,
  contracts_collected, sqme_collected, collected_today,
  contracts_built, sqme_built, floors_built, plasters_built, other_built,
  paint_sold, paint_sqme_sold, paint_collected, paint_sqme_collected, paint_built, paint_sqme_built,
  builds_on_time, builds_late, pct_on_time,
  revenue, cash_received, revenue_target, pct_of_revenue_target,
  qa_measured, qa_passed, pct_qa_pass,
  masons_on_timesheet, masons_assigned, masons_total, masons_onsite, masons_built,
  masons_paid, masons_productive, pct_masons_productive, mason_earnings, earnings_per_mason, weekly_threshold,
  csos_active, min_csos, csos_short, units_short_csos,
  build_target, sqme_target, sales_target, sqme_sales_target,
  min_masons, masons_to_hire, territories_short,
  pct_of_build_target, pct_of_sqme_target, pct_of_sales_target, pct_of_sqme_sales_target,
  pct_of_coll_target, pct_of_sqme_coll_target,
  builds_per_mason, usual_builds_per_mason, expected_builds, pct_build_productivity,
  pct_sales_productivity, pct_coll_productivity, contracts_per_cso, usual_contracts_per_cso,
  collected_not_built, waiting_per_mason,
  rank_sqme,
  IF(prev_month = DATE_SUB(month, INTERVAL IF(is_quarter, 3, 1) MONTH), rank_prev_raw, NULL) AS rank_prev,
  IF(prev_month = DATE_SUB(month, INTERVAL IF(is_quarter, 3, 1) MONTH) AND rank_sqme IS NOT NULL, rank_prev_raw - rank_sqme, NULL) AS rank_move,
  CURRENT_TIMESTAMP() AS built_at
FROM moved
);

-- The plain view of the same function, for ad hoc use: every country, 18
-- months back. The app calls the function (or its inline body) with the
-- selected country, month and the start of the trend.
CREATE OR REPLACE VIEW `earth-enable-main.raw_data_from_salesforce.territory_capacity_period_v2` AS
SELECT * FROM `earth-enable-main.raw_data_from_salesforce.capacity_week_v2`(NULL, NULL, NULL);
