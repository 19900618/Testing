-- =============================================================================
-- salesforce.cso_headcount_app_v1
--
-- Rwanda: distinct CSO headcount per territory, district and country per month,
-- never summed across units (one person can cover two territories). Feeds /cso.
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
-- Deploy product_class first, then this file, through the BigQuery
-- connector or the console; the app's service account cannot create views.
-- =============================================================================

CREATE OR REPLACE VIEW `earth-enable-main.salesforce.cso_headcount_app_v1` AS
WITH base AS (
  SELECT
    o.signed_by_employee_c AS cso_id,
    S.territory_c AS territory,
    L.district_c AS district,
    COALESCE(cso.employee_status_c,'') = 'Active'
      AND NOT (cso.employee_status_c IS NULL AND cso.hire_date_c IS NULL) AS current_staff,
    COALESCE(o.product_interest_c, o.new_product_interest_c) AS pi,
    o.customer_signed_date_c AS signed_date,
    o.date_50_of_total_payment_is_made_c AS d50,
    o.date_100_of_total_payment_is_made_c AS d100
  FROM `earth-enable-main.salesforce.opportunity` o
  LEFT JOIN `earth-enable-main.salesforce.location_c` L ON o.umudugudu_c = L.id
  LEFT JOIN `earth-enable-main.salesforce.location_c` S ON L.sector_c = S.id
  LEFT JOIN `earth-enable-main.salesforce.contact` cso ON o.signed_by_employee_c = cso.id
  WHERE o._fivetran_deleted = FALSE
    AND L.country_c = 'Rwanda'
    AND o.phase_c = '1'
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
ev AS (
  SELECT cso_id, territory, district, current_staff,
    CASE
      WHEN IF(product = 'Floor', COALESCE(d50, d100), d100) < signed_date THEN NULL
      ELSE IF(product = 'Floor', COALESCE(d50, d100), d100)
    END AS collected_date,
    signed_date
  FROM cls
  WHERE product IN ('Floor','Plaster','Paint')
),
presence AS (
  -- One row per CSO per territory per month they were active there.
  SELECT DISTINCT cso_id, territory, district, current_staff, month FROM (
    SELECT cso_id, territory, district, current_staff,
           DATE_TRUNC(signed_date, MONTH) AS month FROM ev WHERE signed_date IS NOT NULL
    UNION ALL
    SELECT cso_id, territory, district, current_staff,
           DATE_TRUNC(collected_date, MONTH) AS month FROM ev WHERE collected_date IS NOT NULL
  )
  WHERE month <= DATE_TRUNC(CURRENT_DATE(), MONTH)
)
SELECT 'territory' AS level, territory AS name, ANY_VALUE(district) AS parent, month, current_staff,
       COUNT(DISTINCT cso_id) AS csos
FROM presence WHERE territory IS NOT NULL GROUP BY territory, month, current_staff
UNION ALL
SELECT 'district', district, NULL, month, current_staff, COUNT(DISTINCT cso_id)
FROM presence WHERE district IS NOT NULL GROUP BY district, month, current_staff
UNION ALL
SELECT 'country', 'Rwanda', NULL, month, current_staff, COUNT(DISTINCT cso_id)
FROM presence GROUP BY month, current_staff
