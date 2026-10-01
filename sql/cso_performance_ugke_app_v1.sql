-- =============================================================================
-- salesforce.cso_performance_ugke_app_v1
--
-- A Classic toolkit view, kept here so changes to it are reviewed like the rest.
-- Deploy: run this file in the BigQuery console (the app reads the view by name).
-- Copied from the live definition on 2026-09-29, then changed so targets are the
-- month's own (not next month's).
-- =============================================================================

CREATE OR REPLACE VIEW `earth-enable-main.salesforce.cso_performance_ugke_app_v1`
AS
WITH base AS (
  SELECT
    o.id AS opportunity_id,
    o.country_c AS country,
    o.signed_by_employee_c AS cso_id,
    cso.name AS cso_name,
    COALESCE(cso.phone, cso.mobile_phone) AS cso_phone,
    cso.hire_date_c AS hire_date,
    cso.employee_status_c AS employee_status,
    NULLIF(TRIM(cso.staff_position_c), '') AS position,
    sup.name AS supervisor,
    -- Same branch rule as collections_app_v1: Uganda from Salesforce's own
    -- location branch, falling back to the district map; Kenya's branch is its district.
    CASE
      WHEN o.country_c = 'Uganda' THEN
        COALESCE(NULLIF(TRIM(L.branch_c), ''),
        CASE
          WHEN L.district_c IN ('Masindi','Kiryandongo','Buliisa','Hoima','Nakasongola','Nakaseke') THEN 'Masindi'
          WHEN L.district_c IN ('Masaka','Kalungu','Bukomansimbi','Sembabule','Lwengo','Kyotera','Mpigi') THEN 'Masaka'
          WHEN L.district_c IN ('Ntungamo','Rwampara','Rukungiri','Bushenyi','Isingiro') THEN 'Ntungamo'
          WHEN L.district_c IN ('Jinja','Mayuge','Kamuli','Luuka','Buyende','Buikwe') THEN 'Jinja'
          WHEN L.district_c IN ('Iganga','Namutumba','Bugweri','Namayingo','Busia','Bugiri','Tororo','Kaliro','Kibuku') THEN 'Iganga'
          WHEN L.district_c IN ('Sironko','Mbale','Butebo','Kapchorwa','Namisindwa','Bukedea') THEN 'Mbale'
          WHEN L.district_c IN ('Ibanda','Kamwenge') THEN 'Ibanda'
          WHEN L.district_c IN ('Kumi','Soroti') THEN 'Soroti'
          WHEN L.district_c = 'Luweero' THEN 'Luweero'
          WHEN L.district_c = 'Mbarara' THEN 'Mbarara'
          ELSE L.district_c END)
      ELSE L.district_c
    END AS branch,
    COALESCE(o.product_interest_c, o.new_product_interest_c) AS pi,
    COALESCE(o.total_square_meters_c, 0) AS raw_sqm,
    COALESCE(o.total_payment_amount_c, 0) AS contract_value,
    -- Phase 1 = the original contract for a job. contracts_sold / contracts_collected count
    -- phase 1 only (JOBS); the *_all columns count every phase (CONTRACTS, as Salesforce lists
    -- them). SQM-E counts every phase and is the productivity basis (decided 2026-09-17).
    COALESCE(o.phase_c = '1', FALSE) AS is_phase1,
    o.customer_signed_date_c AS signed_date,
    o.date_50_of_total_payment_is_made_c AS d50,
    o.seventyfive_payment_made_c AS d75,
    o.date_100_of_total_payment_is_made_c AS d100
  FROM `earth-enable-main.salesforce.opportunity` o
  LEFT JOIN `earth-enable-main.salesforce.location_c` L ON o.umudugudu_c = L.id
  LEFT JOIN `earth-enable-main.salesforce.contact` cso ON o.signed_by_employee_c = cso.id
  LEFT JOIN `earth-enable-main.salesforce.contact` sup ON cso.employee_s_supervisor_c = sup.id
  WHERE o._fivetran_deleted = FALSE
    AND o.country_c IN ('Uganda', 'Kenya')
    AND o.signed_by_employee_c IS NOT NULL
    AND o.stage_name NOT IN ('Closed Lost', 'Houses meet criteria')
    AND o.customer_signed_date_c IS NOT NULL
),
cls AS (
  SELECT *,
    CASE
      WHEN pi IS NULL THEN 'Unknown'
      WHEN LOWER(pi) LIKE '%repair%' OR pi IN ('Rescreed','Masking','Recompacting','Premium Redo') THEN 'Repair'
      WHEN LOWER(pi) LIKE '%paint%' THEN 'Paint'
      WHEN LOWER(pi) LIKE '%plaster%' THEN 'Plaster'
      WHEN LOWER(pi) LIKE '%floor%' OR pi IN ('Ubudehe 1 Subsidy','Ishema','Cluster','Damarara','Franchise','Free LOMA Full','Free LOMA Partial','Kwigira','Loan contract','LOMA Full Service','LOMA Partial Service','Pro Bono','Subcontract - Free LOMA Full','Subcontract - Free LOMA Partial','Subcontract - LOMA Full','Subcontract - LOMA Partial','Subcontract Institutional - Full LOMA','Subcontract Institutional - Partial LOMA') THEN 'Floor'
      WHEN LOWER(pi) LIKE '%house%' THEN 'House'
      ELSE 'Other' END AS product,
    -- Zero-value (DonateDiscount) contracts: shown, never scored.
    (LOWER(COALESCE(pi, '')) LIKE '%donatediscount%' OR COALESCE(contract_value, 0) <= 0) AS is_donated
  FROM base
),
calc AS (
  SELECT *,
    ROUND(raw_sqm * IF(product = 'Floor', 1.0, 0.333), 1) AS sqme,
    -- A gate stamped before the signature belongs to an earlier, re-signed contract.
    IF(gate_date < signed_date, NULL, gate_date) AS collected_date
  FROM (
    SELECT *,
      -- The payment gate: floor at 50%, plaster at 75%, paint at 100%. A later
      -- milestone implies the earlier one, so fall through when it was never stamped.
      CASE product
        WHEN 'Floor' THEN COALESCE(d50, d75, d100)
        WHEN 'Plaster' THEN COALESCE(d75, d100)
        ELSE d100
      END AS gate_date
    FROM cls
    WHERE product IN ('Floor', 'Plaster', 'Paint')
  )
),
ev AS (
  SELECT *,
    DATE_TRUNC(signed_date, MONTH) AS sales_month,
    DATE_TRUNC(collected_date, MONTH) AS coll_month,
    product IN ('Floor', 'Plaster') AND NOT is_donated AS is_scored
  FROM calc
),
spine AS (
  SELECT DISTINCT cso_id, month FROM (
    SELECT cso_id, sales_month AS month FROM ev
    UNION ALL
    SELECT cso_id, coll_month FROM ev WHERE coll_month IS NOT NULL
  )
  WHERE month <= DATE_TRUNC(CURRENT_DATE(), MONTH)
),
acty AS (
  SELECT s.cso_id, s.month,
    ANY_VALUE(b.country) AS country,
    ANY_VALUE(b.cso_name) AS cso_name,
    ANY_VALUE(b.cso_phone) AS cso_phone,
    ANY_VALUE(b.hire_date) AS hire_date,
    ANY_VALUE(b.employee_status) AS employee_status,
    ANY_VALUE(b.position) AS position,
    ANY_VALUE(b.supervisor) AS supervisor,
    -- Scored: floor + plaster, donated excluded.
    COUNTIF(b.sales_month = s.month AND b.is_scored AND b.is_phase1) AS contracts_sold,
    COUNTIF(b.sales_month = s.month AND b.is_scored AND b.is_phase1 AND b.product = 'Floor') AS floor_sold,
    COUNTIF(b.sales_month = s.month AND b.is_scored AND b.is_phase1 AND b.product = 'Plaster') AS plaster_sold,
    ROUND(SUM(IF(b.sales_month = s.month AND b.is_scored, b.sqme, 0)), 1) AS sqme_sold,
    ROUND(SUM(IF(b.sales_month = s.month AND b.is_scored AND b.product = 'Floor', b.sqme, 0)), 1) AS floor_sqme_sold,
    ROUND(SUM(IF(b.sales_month = s.month AND b.is_scored, b.contract_value, 0))) AS value_sold,
    COUNTIF(b.coll_month = s.month AND b.is_scored AND b.is_phase1) AS contracts_collected,
    ROUND(SUM(IF(b.coll_month = s.month AND b.is_scored, b.sqme, 0)), 1) AS sqme_collected,
    -- Paint: volume only.
    COUNTIF(b.sales_month = s.month AND b.product = 'Paint' AND NOT b.is_donated AND b.is_phase1) AS paint_sold,
    ROUND(SUM(IF(b.sales_month = s.month AND b.product = 'Paint' AND NOT b.is_donated, b.raw_sqm, 0)), 1) AS paint_m2,
    ROUND(SUM(IF(b.sales_month = s.month AND b.product = 'Paint' AND NOT b.is_donated, b.sqme, 0)), 1) AS paint_sqme,
    COUNTIF(b.coll_month = s.month AND b.product = 'Paint' AND NOT b.is_donated AND b.is_phase1) AS paint_collected,
    ROUND(SUM(IF(b.coll_month = s.month AND b.product = 'Paint' AND NOT b.is_donated, b.sqme, 0)), 1) AS paint_collected_sqme,
    ROUND(SUM(IF(b.sales_month = s.month AND b.product = 'Paint' AND NOT b.is_donated, b.contract_value, 0))) AS paint_value,
    COUNTIF(b.sales_month = s.month AND b.is_donated AND b.is_phase1) AS donated,
    -- Every phase counted: each follow-on phase is its own contract, priced, paid and
    -- collected on its own (about 45% of UG and KE contracts in 2026).
    COUNTIF(b.sales_month = s.month AND b.is_scored) AS contracts_sold_all,
    COUNTIF(b.coll_month = s.month AND b.is_scored) AS contracts_collected_all,
    COUNTIF(b.sales_month = s.month AND b.product = 'Paint' AND NOT b.is_donated) AS paint_sold_all,
    COUNTIF(b.coll_month = s.month AND b.product = 'Paint' AND NOT b.is_donated) AS paint_collected_all,
    COUNTIF(b.sales_month = s.month AND b.is_donated) AS donated_all
  FROM spine s
  JOIN ev b ON b.cso_id = s.cso_id AND (b.sales_month = s.month OR b.coll_month = s.month)
  GROUP BY 1, 2
),
branch_ranked AS (
  SELECT b.cso_id, s.month, b.branch,
    ROW_NUMBER() OVER (PARTITION BY b.cso_id, s.month ORDER BY COUNT(*) DESC, b.branch) AS rk
  FROM spine s
  JOIN ev b ON b.cso_id = s.cso_id AND (b.sales_month = s.month OR b.coll_month = s.month)
  WHERE b.branch IS NOT NULL
  GROUP BY b.cso_id, s.month, b.branch
),
prim AS (SELECT cso_id, month, branch FROM branch_ranked WHERE rk = 1),
home AS (
  -- One stable branch per CSO, so a profile does not hop between months.
  SELECT cso_id, branch AS home_branch FROM (
    SELECT cso_id, branch, ROW_NUMBER() OVER (PARTITION BY cso_id ORDER BY COUNT(*) DESC, branch) AS rk
    FROM ev WHERE branch IS NOT NULL GROUP BY cso_id, branch
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
tgt AS (
  -- branch_targets holds one row per day; the monthly figures repeat within a month.
  SELECT country, REGEXP_REPLACE(branch, r'\s*Branch$', '') AS branch, DATE_TRUNC(target_date, MONTH) AS month,
    ANY_VALUE(monthly_builds_target) AS build_target,
    ANY_VALUE(monthly_sqme_target) AS sqme_target
  FROM `earth-enable-main.raw_data_from_salesforce.branch_targets`
  WHERE country IN ('Uganda', 'Kenya')
  GROUP BY 1, 2, 3
),
joined AS (
  SELECT t2.*,
    COALESCE(p.branch, 'Unassigned') AS branch,
    COALESCE(h.home_branch, p.branch, 'Unassigned') AS home_branch,
    LEAST(SAFE_DIVIDE(t2.days_available, t2.month_days), 1.0) AS tenure_ratio,
    -- CSOs each branch should have (decided 2026-09-15).
    CASE t2.country WHEN 'Uganda' THEN 9.0 WHEN 'Kenya' THEN 7.0 END AS establishment,
    tg.build_target, tg.sqme_target,
    tg.branch IS NOT NULL AS has_targets,
    t2.month AS target_month
  FROM tenure t2
  LEFT JOIN prim p ON p.cso_id = t2.cso_id AND p.month = t2.month
  LEFT JOIN home h ON h.cso_id = t2.cso_id
  -- This month's work against this month's own target, as in Rwanda.
  LEFT JOIN tgt tg ON tg.country = t2.country AND tg.branch = p.branch AND tg.month = t2.month
),
prorated AS (
  SELECT j.*,
    SAFE_DIVIDE(build_target * 1.3, establishment) * tenure_ratio AS min_sales_contracts,
    SAFE_DIVIDE(build_target, establishment) * tenure_ratio AS min_coll_contracts,
    -- The productivity standard (SQM-E basis, 2026-09-17): branch SQM-E target x 1.3 for
    -- sales and x 1.0 for collections, shared across the establishment, pro-rated for days worked.
    SAFE_DIVIDE(sqme_target * 1.3, establishment) * tenure_ratio AS min_sales_sqme,
    SAFE_DIVIDE(sqme_target, establishment) * tenure_ratio AS min_coll_sqme
  FROM joined j
)
SELECT
  cso_id, cso_name, cso_phone, country, month, FORMAT_DATE('%B %Y', month) AS month_label,
  branch, home_branch,
  branch != home_branch AND branch != 'Unassigned' AND home_branch != 'Unassigned' AS is_away_from_home,
  position,
  -- TENTATIVE (2026-09-15, under review): who is ranked against the per-CSO standard.
  position IS NULL OR position IN ('Customer Sales Officer', 'Sales Agent', 'Sales Rep') AS is_ranked,
  supervisor, hire_date, employee_status,
  contracts_sold, floor_sold, plaster_sold, sqme_sold, floor_sqme_sold, value_sold,
  contracts_collected, sqme_collected,
  paint_sold, paint_m2, paint_sqme, paint_collected, paint_collected_sqme, paint_value, donated,
  contracts_sold_all, contracts_collected_all, paint_sold_all, paint_collected_all, donated_all,
  has_targets, establishment, build_target, sqme_target, target_month,
  min_sales_contracts, min_coll_contracts, min_sales_sqme, min_coll_sqme,
  SAFE_DIVIDE(contracts_sold, NULLIF(min_sales_contracts, 0)) AS pct_sales_productivity,
  SAFE_DIVIDE(contracts_collected, NULLIF(min_coll_contracts, 0)) AS pct_coll_productivity,
  SAFE_DIVIDE(sqme_sold, NULLIF(min_sales_sqme, 0)) AS pct_sales_sqme_productivity,
  SAFE_DIVIDE(sqme_collected, NULLIF(min_coll_sqme, 0)) AS pct_coll_sqme_productivity,
  days_available, month_days, tenure_ratio,
  tenure_ratio < 0.999 AS is_part_month,
  hire_date IS NOT NULL AND hire_date > DATE_SUB(month, INTERVAL 2 MONTH) AS is_new_cso,
  COALESCE(employee_status, '') = 'Active' AS is_active_staff,
  employee_status IS NULL AND hire_date IS NULL AS is_unverified_staff,
  month = DATE_TRUNC(CURRENT_DATE(), MONTH) AS is_current_month
FROM prorated;
