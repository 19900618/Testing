-- =============================================================================
-- raw_data_from_salesforce.completed_value_daily
--
-- Live revenue from Salesforce (docs/cts-page-and-revenue.md, item 2): the
-- contract value of the builds completed each day, at the grain the country
-- workspaces cut by: country, branch, territory, CSO, mason, product and
-- completion date. It is what the workspaces call Revenue. It is not
-- QuickBooks revenue and will not match it month to month (timing); the CEO
-- dashboard and the Cost to serve page keep the posted QuickBooks figures.
--
-- Rules, and where each comes from:
--   The field         REVENUE_FIELD below, one line: total_payment_amount_c,
--                     confirmed by Vinamra as the contract value field. A
--                     second field, total_revenue_c, reconciles to booked
--                     revenue in Kenya and runs higher there and in Rwanda;
--                     if finance decides the field should change, change
--                     that one line and nothing else.
--   Completion        date_associated_project_completed_c, the same date
--                     contracts_built counts on in capacity_week_v2 and
--                     capacity_mason_week_v2 (all_opportunities_master's
--                     completed_date is that field). Revenue and builds
--                     always count the same set of jobs.
--   Excluded          deleted rows, Closed Lost and "Houses meet criteria"
--                     (the master view's filter), and the Contractor record
--                     type. Every phase counts, as SQM-E does.
--   Product           the company's classification, product_class
--                     (sql/product_class.sql), old field first.
--   Place             Rwanda: territory from the sector, branch is the
--                     district. Uganda: branch from the location's own
--                     branch_c. Kenya: branch_c, else the district. The
--                     rule of capacity_week_v2.
--
-- Built straight off the raw Salesforce tables, never on
-- all_opportunities_master (standing instruction). Deploy product_class
-- first, then this file; the app's service account cannot create views.
-- =============================================================================

CREATE OR REPLACE VIEW `earth-enable-main.raw_data_from_salesforce.completed_value_daily`
OPTIONS (description = "Contract value (total_payment_amount_c) of the builds completed each day, by country, branch, territory, CSO, mason and product. Completion is date_associated_project_completed_c, the capacity views' rule; Contractor record type excluded. Feeds Revenue in the country workspaces. Not QuickBooks revenue.")
AS
SELECT
  loc.country_c AS country,
  CASE loc.country_c
    WHEN 'Rwanda' THEN loc.district_c
    WHEN 'Uganda' THEN NULLIF(TRIM(loc.branch_c), '')
    WHEN 'Kenya'  THEN COALESCE(NULLIF(TRIM(loc.branch_c), ''), NULLIF(TRIM(loc.district_c), ''))
  END AS branch,
  IF(loc.country_c = 'Rwanda', sec.territory_c, NULL) AS territory,
  o.signed_by_employee_c AS cso_id,
  cso.name AS cso_name,
  o.franchisee_mason_building_the_asset_c AS mason_id,
  mason.name AS mason_name,
  `earth-enable-main.raw_data_from_salesforce.product_class`(COALESCE(o.product_interest_c, o.new_product_interest_c)) AS product,
  o.date_associated_project_completed_c AS completed_date,
  COUNT(*) AS contracts,
  COUNTIF(o.phase_c = '1') AS jobs,
  -- REVENUE_FIELD: the one line to change if finance moves to total_revenue_c.
  SUM(IFNULL(o.total_payment_amount_c, 0)) AS completed_value
FROM `earth-enable-main.salesforce.opportunity` o
LEFT JOIN `earth-enable-main.salesforce.location_c` loc ON loc.id = o.umudugudu_c
LEFT JOIN `earth-enable-main.salesforce.location_c` sec ON sec.id = loc.sector_c
LEFT JOIN `earth-enable-main.salesforce.contact` cso ON cso.id = o.signed_by_employee_c
LEFT JOIN `earth-enable-main.salesforce.contact` mason ON mason.id = o.franchisee_mason_building_the_asset_c
LEFT JOIN `earth-enable-main.salesforce.record_type` rt ON rt.id = o.record_type_id
WHERE o._fivetran_deleted = FALSE
  AND o.date_associated_project_completed_c IS NOT NULL
  AND o.stage_name NOT IN ('Closed Lost', 'Houses meet criteria')
  AND COALESCE(rt.name, '') != 'Contractor'
  AND loc.country_c IN ('Rwanda', 'Uganda', 'Kenya')
GROUP BY 1, 2, 3, 4, 5, 6, 7, 8, 9;
