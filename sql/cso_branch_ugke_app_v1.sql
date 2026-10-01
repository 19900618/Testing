-- =============================================================================
-- salesforce.cso_branch_ugke_app_v1
--
-- A Classic toolkit view, kept here so changes to it are reviewed like the rest.
-- Deploy: run this file in the BigQuery console (the app reads the view by name).
-- Copied from the live definition on 2026-09-29, then changed so targets are the
-- month's own (not next month's).
-- =============================================================================

CREATE OR REPLACE VIEW `earth-enable-main.salesforce.cso_branch_ugke_app_v1`
AS
WITH base AS (
  SELECT
    o.country_c AS country,
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
    COALESCE(o.phase_c = '1', FALSE) AS is_phase1,
    o.date_associated_project_completed_c AS completed_date
  FROM `earth-enable-main.salesforce.opportunity` o
  LEFT JOIN `earth-enable-main.salesforce.location_c` L ON o.umudugudu_c = L.id
  WHERE o._fivetran_deleted = FALSE
    AND o.country_c IN ('Uganda', 'Kenya')
    AND o.stage_name NOT IN ('Closed Lost', 'Houses meet criteria')
    AND o.date_associated_project_completed_c IS NOT NULL
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
      ELSE 'Other' END AS product
  FROM base
),
built AS (
  SELECT country, COALESCE(branch, 'Unassigned') AS branch, DATE_TRUNC(completed_date, MONTH) AS month,
    -- builds / paint_builds = JOBS (phase 1); *_all = every phase completed. SQM-E is the basis.
    COUNTIF(product IN ('Floor', 'Plaster') AND is_phase1) AS builds,
    ROUND(SUM(IF(product IN ('Floor', 'Plaster'), raw_sqm * IF(product = 'Floor', 1.0, 0.333), 0)), 1) AS builds_sqme,
    COUNTIF(product = 'Paint' AND is_phase1) AS paint_builds,
    ROUND(SUM(IF(product = 'Paint', raw_sqm * 0.333, 0)), 1) AS paint_builds_sqme,
    COUNTIF(product IN ('Floor', 'Plaster')) AS builds_all,
    COUNTIF(product = 'Paint') AS paint_builds_all
  FROM cls
  WHERE product IN ('Floor', 'Plaster', 'Paint')
    AND DATE_TRUNC(completed_date, MONTH) <= DATE_TRUNC(CURRENT_DATE(), MONTH)
  GROUP BY 1, 2, 3
),
tgt AS (
  SELECT country, REGEXP_REPLACE(branch, r'\s*Branch$', '') AS branch, DATE_TRUNC(target_date, MONTH) AS month,
    ANY_VALUE(monthly_builds_target) AS build_target,
    ANY_VALUE(monthly_sqme_target) AS sqme_target
  FROM `earth-enable-main.raw_data_from_salesforce.branch_targets`
  WHERE country IN ('Uganda', 'Kenya')
  GROUP BY 1, 2, 3
),
spine AS (
  SELECT country, branch, month FROM built
  UNION DISTINCT
  SELECT country, branch, month FROM tgt WHERE month <= DATE_TRUNC(CURRENT_DATE(), MONTH)
)
SELECT
  s.country, s.branch, s.month, FORMAT_DATE('%B %Y', s.month) AS month_label,
  COALESCE(b.builds, 0) AS builds,
  COALESCE(b.builds_sqme, 0) AS builds_sqme,
  COALESCE(b.paint_builds, 0) AS paint_builds,
  COALESCE(b.paint_builds_sqme, 0) AS paint_builds_sqme,
  COALESCE(b.builds_all, 0) AS builds_all,
  COALESCE(b.paint_builds_all, 0) AS paint_builds_all,
  t.build_target, t.sqme_target,
  s.month AS target_month,
  t.branch IS NOT NULL AS has_targets
FROM spine s
LEFT JOIN built b ON b.country = s.country AND b.branch = s.branch AND b.month = s.month
-- Builds this month against this month's own target, as in Rwanda's capacity model.
LEFT JOIN tgt t ON t.country = s.country AND t.branch = s.branch AND t.month = s.month;
