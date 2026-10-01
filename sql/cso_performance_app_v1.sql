-- =============================================================================
-- salesforce.cso_performance_app_v1
--
-- Rwanda CSO performance, one row per CSO per month: contracts and SQM-E
-- sold and collected against the territory's targets. Feeds /cso.
--
-- The deployed definition (read back from BigQuery on 2026-09-29) with one
-- change: product is classified by raw_data_from_salesforce.product_class,
-- the company's one classification (sql/product_class.sql), instead of a
-- copy of the CASE written into the view. The deployed copy already carried
-- the Repair branch in the canonical order, so this moves no contract; it
-- only removes a second place the rule lived.
--
-- WHERE product IN ('Floor','Plaster','Paint') is kept exactly as it was:
-- a CSO who sold only paint still appears in the lists. Paint is excluded
-- from scored SQM-E, never from the people.
--
-- Targets are the month's own (September activity against September's
-- target, 2026-09-29), or the next month's when a month has no targets at all
-- (2026-09-30), and from September 2026 Nyagatare C shares the district
-- target (see the join to the targets below).
--
-- Deploy product_class first, then this file, through the BigQuery
-- connector or the console; the app's service account cannot create views.
-- =============================================================================

CREATE OR REPLACE VIEW `earth-enable-main.salesforce.cso_performance_app_v1` AS
WITH base AS (
  SELECT
    o.id AS opportunity_id,
    o.signed_by_employee_c AS cso_id,
    cso.name AS cso_name,
    COALESCE(cso.phone, cso.mobile_phone) AS cso_phone,
    cso.hire_date_c AS hire_date,
    cso.employee_status_c AS employee_status,
    cso.staff_position_c AS staff_position,
    -- The CSO's assigned patch on their staff record. 100% populated and agrees
    -- with where they actually work 99.5% of the time, unlike rw_territory_c
    -- which is filled for only 2% of CSOs.
    NULLIF(TRIM(cso.work_location_c),'') AS assigned_district,
    S.territory_c AS territory,
    L.district_c AS district,
    COALESCE(o.product_interest_c, o.new_product_interest_c) AS pi,
    COALESCE(o.total_square_meters_c, 0) AS raw_sqm,
    o.total_square_meters_c IS NULL AS sqm_missing,
    -- Phase 1 = the original contract for a job; phase 2+ = follow-on contracts
    -- adding area to it. CONTRACT counts use phase 1 only, because build_target
    -- counts jobs. SQM-E counts every phase, because sqme_target is set on all
    -- phases (confirmed 2026-09-14).
    COALESCE(o.phase_c = '1', FALSE) AS is_phase1,
    o.customer_signed_date_c AS signed_date,
    o.date_50_of_total_payment_is_made_c AS d50,
    o.date_100_of_total_payment_is_made_c AS d100
  FROM `earth-enable-main.salesforce.opportunity` o
  LEFT JOIN `earth-enable-main.salesforce.location_c` L ON o.umudugudu_c = L.id
  LEFT JOIN `earth-enable-main.salesforce.location_c` S ON L.sector_c = S.id
  LEFT JOIN `earth-enable-main.salesforce.contact` cso ON o.signed_by_employee_c = cso.id
  WHERE o._fivetran_deleted = FALSE
    AND L.country_c = 'Rwanda'
    AND o.signed_by_employee_c IS NOT NULL
    AND o.stage_name NOT IN ('Closed Lost','Houses meet criteria')
),
cls AS (
  SELECT *,
    -- The company's classification, one place (sql/product_class.sql); this
    -- view used to carry its own copy of the CASE.
    `earth-enable-main.raw_data_from_salesforce.product_class`(pi) AS product
  FROM base
),
calc AS (
  SELECT *,
    ROUND(raw_sqm * IF(product = 'Floor', 1.0, 0.333), 1) AS sqme,
    CASE
      WHEN IF(product = 'Floor', COALESCE(d50, d100), d100) < signed_date THEN NULL
      ELSE IF(product = 'Floor', COALESCE(d50, d100), d100)
    END AS collected_date
  FROM cls
  WHERE product IN ('Floor','Plaster','Paint')
),
ev AS (
  SELECT *,
    DATE_TRUNC(signed_date, MONTH) AS sales_month,
    DATE_TRUNC(collected_date, MONTH) AS coll_month
  FROM calc
),
spine AS (
  SELECT DISTINCT cso_id, month FROM (
    SELECT cso_id, sales_month AS month FROM ev WHERE sales_month IS NOT NULL
    UNION ALL
    SELECT cso_id, coll_month FROM ev WHERE coll_month IS NOT NULL
  )
  WHERE month <= DATE_TRUNC(CURRENT_DATE(), MONTH)
),
acty AS (
  SELECT s.cso_id, s.month,
    ANY_VALUE(b.cso_name) AS cso_name,
    ANY_VALUE(b.cso_phone) AS cso_phone,
    ANY_VALUE(b.hire_date) AS hire_date,
    ANY_VALUE(b.employee_status) AS employee_status,
    ANY_VALUE(b.staff_position) AS staff_position,
    ANY_VALUE(b.assigned_district) AS assigned_district,
    COUNTIF(b.sales_month = s.month AND b.is_phase1) AS contracts_sold,
    ROUND(SUM(IF(b.sales_month = s.month, b.sqme, 0)),1) AS sqme_sold,
    COUNTIF(b.coll_month = s.month AND b.is_phase1) AS contracts_collected,
    ROUND(SUM(IF(b.coll_month = s.month, b.sqme, 0)),1) AS sqme_collected,
    COUNTIF(b.sales_month = s.month AND b.sqm_missing) AS sold_missing_sqm
  FROM spine s
  JOIN ev b ON b.cso_id = s.cso_id AND (b.sales_month = s.month OR b.coll_month = s.month)
  GROUP BY 1,2
),
terr_ranked AS (
  SELECT b.cso_id, s.month, b.territory, ANY_VALUE(b.district) AS district,
    ROW_NUMBER() OVER (PARTITION BY b.cso_id, s.month ORDER BY COUNT(*) DESC, b.territory) AS rk
  FROM spine s
  JOIN ev b ON b.cso_id = s.cso_id AND (b.sales_month = s.month OR b.coll_month = s.month)
  WHERE b.territory IS NOT NULL
  GROUP BY b.cso_id, s.month, b.territory
),
terr AS (SELECT cso_id, month, territory, district FROM terr_ranked WHERE rk = 1),
home AS (
  -- One stable territory per CSO so a profile does not appear to move between
  -- months. 91% of CSOs only ever work one territory; this settles the rest on
  -- whichever territory holds most of their work.
  SELECT cso_id, territory AS home_territory, district AS home_district FROM (
    SELECT cso_id, territory, ANY_VALUE(district) AS district,
      ROW_NUMBER() OVER (PARTITION BY cso_id ORDER BY COUNT(*) DESC, territory) AS rk
    FROM ev WHERE territory IS NOT NULL GROUP BY cso_id, territory
  ) WHERE rk = 1
),
tenure AS (
  SELECT a.*,
    DATE_DIFF(LAST_DAY(a.month), a.month, DAY) + 1 AS month_days,
    GREATEST(
      DATE_DIFF(
        LEAST(LAST_DAY(a.month), GREATEST(CURRENT_DATE(), a.month)),
        CASE WHEN a.hire_date IS NULL OR a.hire_date <= a.month OR a.hire_date > LAST_DAY(a.month)
             THEN a.month ELSE a.hire_date END,
        DAY) + 1,
      1) AS days_available
  FROM acty a
),
joined AS (
  SELECT
    t2.cso_id, t2.cso_name, t2.cso_phone, t2.month,
    t2.hire_date, t2.employee_status, t2.staff_position, t2.assigned_district,
    h.home_territory, h.home_district,
    t2.month_days, t2.days_available, t2.sold_missing_sqm,
    LEAST(SAFE_DIVIDE(t2.days_available, t2.month_days), 1.0) AS tenure_ratio,
    te.territory, te.district, tg.manager,
    t2.contracts_sold, t2.sqme_sold, t2.contracts_collected, t2.sqme_collected,
    tg.territory IS NOT NULL AS has_targets,
    IF(tm.month IS NULL AND tn.month IS NOT NULL, DATE_ADD(t2.month, INTERVAL 1 MONTH), t2.month) AS target_month,
    SAFE_DIVIDE(tg.build_target * 1.3, 5.0) AS min_sales_contracts_full,
    SAFE_DIVIDE(tg.build_target, 5.0) AS min_coll_contracts_full,
    SAFE_DIVIDE(tg.sqme_target * 1.3, 5.0) AS min_sales_sqme_full,
    SAFE_DIVIDE(tg.sqme_target, 5.0) AS min_coll_sqme_full
  FROM tenure t2
  LEFT JOIN terr te ON te.cso_id = t2.cso_id AND te.month = t2.month
  LEFT JOIN home h ON h.cso_id = t2.cso_id
  -- A month with no targets at all (December 2025, before the targets table
  -- starts) is judged against the next month's instead, when the next month has
  -- targets; older months keep their own month and no target. This is per month, not
  -- per territory, so a territory with no target of its own in a month that has
  -- targets (Nyagatare C before September 2026) still has none.
  LEFT JOIN (SELECT DISTINCT month FROM `earth-enable-main.raw_data_from_salesforce.tl_bonus_targets`) tm
    ON tm.month = t2.month
  LEFT JOIN (SELECT DISTINCT month FROM `earth-enable-main.raw_data_from_salesforce.tl_bonus_targets`) tn
    ON tn.month = DATE_ADD(t2.month, INTERVAL 1 MONTH)
  -- The month's own target, with the Nyagatare rule: from September 2026 the
  -- district target (A + B) is shared B one half, A one quarter, C one quarter;
  -- before that C has no target.
  LEFT JOIN (
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
  ) tg
    ON tg.territory = te.territory AND tg.month = IF(tm.month IS NULL AND tn.month IS NOT NULL, DATE_ADD(t2.month, INTERVAL 1 MONTH), t2.month)
),
prorated AS (
  SELECT j.*,
    min_sales_contracts_full * tenure_ratio AS min_sales_contracts,
    min_coll_contracts_full  * tenure_ratio AS min_coll_contracts,
    min_sales_sqme_full      * tenure_ratio AS min_sales_sqme,
    min_coll_sqme_full       * tenure_ratio AS min_coll_sqme
  FROM joined j
)
SELECT p.*,
  SAFE_DIVIDE(contracts_sold, NULLIF(min_sales_contracts,0)) AS pct_sales_productivity,
  SAFE_DIVIDE(contracts_collected, NULLIF(min_coll_contracts,0)) AS pct_coll_productivity,
  SAFE_DIVIDE(sqme_sold, NULLIF(min_sales_sqme,0)) AS pct_sales_sqme_productivity,
  SAFE_DIVIDE(sqme_collected, NULLIF(min_coll_sqme,0)) AS pct_coll_sqme_productivity,
  territory IS NOT NULL AND home_territory IS NOT NULL AND territory != home_territory AS is_away_from_home,
  assigned_district IS NOT NULL AND district IS NOT NULL AND assigned_district != district AS is_outside_assigned_district,
  tenure_ratio < 0.999 AS is_part_month,
  hire_date IS NOT NULL AND hire_date > DATE_SUB(month, INTERVAL 2 MONTH) AS is_new_cso,
  COALESCE(employee_status,'') = 'Active' AS is_active_staff,
  employee_status IS NULL AND hire_date IS NULL AS is_unverified_staff,
  FORMAT_DATE('%B %Y', p.month) AS month_label,
  p.month = DATE_TRUNC(CURRENT_DATE(), MONTH) AS is_current_month
FROM prorated p
