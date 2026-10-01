-- =============================================================================
-- salesforce.cso_cash_daily_app_v1
--
-- The daily grain of the CSO module, for the Individual CSOs page of the
-- country workspaces: one row per CSO per day (2026 on) with the money that
-- arrived, the contract value they completed and the commission they earned.
-- The page asks for one day, the week around it and the month; sums of these
-- rows are correct at every grain because they are flows, not people.
--
--   cash_received       every instalment (cash_received_c), dated by the day
--                       it was paid (date_paid_c), whether or not its payment
--                       plan is settled; refunds excluded. Every phase and
--                       product except Full House, including contracts signed
--                       before 2024. The
--                       CSO is the contract's signing employee, the same
--                       attribution as cso_performance_app_v1.
--   revenue_completed   contract value (total_amount) of the contracts (not
--                       the Contractor record type: completed_value_daily's rule)
--                       completed that day, every phase: the revenue
--                       definition of capacity_week_v2, per CSO. NOT cash.
--   commission          Rwanda only, and PROVISIONAL: Salesforce holds a 50%
--                       commission and a 100% commission per contract
--                       (x_50_cso_commission_rw_c, x_100_cso_commission_rw_c)
--                       but no date they were paid. Each is booked on the day
--                       the customer reached that payment milestone. Uganda
--                       and Kenya carry no commission fields, so they read 0.
--   weekly_cash_target  where the country's finance targets carry a revenue
--                       target for the CSO's unit (branch, or district in
--                       Rwanda), that month's target over the CSOs the unit
--                       should have, over 4.33 weeks, from the same month. Null elsewhere.
--
-- Built straight off the Salesforce tables for the attribution, the unit and
-- the cash, the way capacity_week_v2 places cash, so the two agree (except
-- the Contractor record type, whose cash counts here and not there). The
-- contract value and the commission come from all_opportunities_master and
-- stay limited to the contracts it holds.
-- =============================================================================

CREATE OR REPLACE VIEW `earth-enable-main.salesforce.cso_cash_daily_app_v1`
OPTIONS (description = "Per CSO per day: cash received (every instalment by the day it was paid), contract value completed and (Rwanda, provisional) commission booked at the 50% and 100% milestones. 2026 on. Feeds the country workspaces' Individual CSOs page.")
AS
WITH
country_rules AS (
  SELECT * FROM UNNEST([
    STRUCT('Rwanda' AS country, 5.0 AS csos_per_unit, 'district' AS rev_level),
    STRUCT('Uganda', 9.0, 'branch'),
    STRUCT('Kenya', 7.0, 'branch')
  ])
),
opp AS (
  SELECT
    o.id AS opportunity_id,
    o.signed_by_employee_c AS cso_id,
    c.name AS cso_name,
    l.country_c AS country,
    CASE l.country_c
      WHEN 'Rwanda' THEN l.district_c
      WHEN 'Uganda' THEN COALESCE(NULLIF(TRIM(l.branch_c), ''), REGEXP_EXTRACT(m.branch, r'^(.+) Branch$'))
      WHEN 'Kenya' THEN COALESCE(NULLIF(TRIM(l.branch_c), ''), NULLIF(TRIM(l.district_c), ''), m.location_district)
    END AS rev_unit,
    sec.territory_c AS territory,
    `earth-enable-main.raw_data_from_salesforce.product_class`(COALESCE(o.product_interest_c, o.new_product_interest_c)) AS product,
    -- In the master view: the contract value and commission rows read only these.
    m.opportunity_id IS NOT NULL AS in_master,
    IFNULL(m.total_amount, 0) AS total_amount,
    m.completed_date,
    -- The Contractor record type is out of revenue (the rule of completed_value_daily); its cash still counts.
    COALESCE(rt.name, '') = 'Contractor' AS is_contractor,
    o.x_50_cso_commission_rw_c AS commission_50,
    o.x_100_cso_commission_rw_c AS commission_100,
    o.date_50_of_total_payment_is_made_c AS d50,
    o.date_100_of_total_payment_is_made_c AS d100
  FROM `earth-enable-main.salesforce.opportunity` o
  JOIN `earth-enable-main.salesforce.location_c` l ON l.id = o.umudugudu_c
  LEFT JOIN `earth-enable-main.salesforce.location_c` sec ON sec.id = l.sector_c
  LEFT JOIN `earth-enable-main.raw_data_from_salesforce.all_opportunities_master` m ON m.opportunity_id = o.id
  LEFT JOIN `earth-enable-main.salesforce.contact` c ON c.id = o.signed_by_employee_c
  LEFT JOIN `earth-enable-main.salesforce.record_type` rt ON rt.id = o.record_type_id
  WHERE NOT o._fivetran_deleted
    AND o.signed_by_employee_c IS NOT NULL
    AND l.country_c IN ('Rwanda', 'Uganda', 'Kenya')
),
events AS (
  -- Cash, one row per instalment, by the day it was paid.
  SELECT o.country, o.cso_id, o.cso_name, o.rev_unit, o.territory, cr.date_paid_c AS day,
    IFNULL(cr.installment_amount_c, 0) AS cash_received, 0.0 AS revenue_completed, 0.0 AS commission
  FROM `earth-enable-main.salesforce.cash_received_c` cr
  JOIN `earth-enable-main.salesforce.payment_c` p ON p.id = cr.payment_c
  JOIN opp o ON o.opportunity_id = p.opportunity_c
  WHERE o.product != 'House'
    AND NOT cr._fivetran_deleted AND NOT COALESCE(cr.is_deleted, FALSE)
    AND COALESCE(cr.status_c, '') != 'Refunded'
    AND NOT p._fivetran_deleted AND NOT COALESCE(p.is_deleted, FALSE)
    AND cr.date_paid_c >= DATE '2026-01-01' AND cr.date_paid_c <= CURRENT_DATE()
  UNION ALL
  -- Contract value completed, by completion date.
  SELECT country, cso_id, cso_name, rev_unit, territory, completed_date, 0.0, total_amount, 0.0
  FROM opp
  WHERE in_master AND completed_date >= DATE '2026-01-01' AND completed_date <= CURRENT_DATE() AND NOT is_contractor
  UNION ALL
  -- Commission, on the day of each milestone (Rwanda fields; 0 elsewhere).
  SELECT country, cso_id, cso_name, rev_unit, territory, d50, 0.0, 0.0, commission_50
  FROM opp WHERE in_master AND commission_50 > 0 AND d50 >= DATE '2026-01-01' AND d50 <= CURRENT_DATE()
  UNION ALL
  SELECT country, cso_id, cso_name, rev_unit, territory, d100, 0.0, 0.0, commission_100
  FROM opp WHERE in_master AND commission_100 > 0 AND d100 >= DATE '2026-01-01' AND d100 <= CURRENT_DATE()
),
daily AS (
  SELECT country, cso_id, ANY_VALUE(cso_name) AS cso_name, day,
    -- The unit most of the day's money came from, for the target.
    ARRAY_AGG(rev_unit IGNORE NULLS ORDER BY cash_received DESC LIMIT 1)[SAFE_OFFSET(0)] AS rev_unit,
    ARRAY_AGG(territory IGNORE NULLS ORDER BY cash_received DESC LIMIT 1)[SAFE_OFFSET(0)] AS territory,
    SUM(cash_received) AS cash_received,
    SUM(revenue_completed) AS revenue_completed,
    SUM(commission) AS commission
  FROM events
  GROUP BY 1, 2, 4
),
rev_targets AS (
  SELECT country, branch AS rev_unit, month, target_value AS revenue_target
  FROM `earth-enable-main.qb_reporting.branch_financial_targets`
  WHERE metric = 'revenue'
)
SELECT
  d.country, d.cso_id, d.cso_name, d.day, DATE_TRUNC(d.day, MONTH) AS month,
  d.rev_unit AS unit, d.territory,
  d.cash_received, d.revenue_completed, d.commission,
  SAFE_DIVIDE(SAFE_DIVIDE(rt.revenue_target, cr.csos_per_unit), 4.33) AS weekly_cash_target,
  cr.csos_per_unit
FROM daily d
JOIN country_rules cr ON cr.country = d.country
-- The same month's target.
LEFT JOIN rev_targets rt ON rt.country = d.country AND rt.rev_unit = d.rev_unit AND rt.month = DATE_TRUNC(d.day, MONTH);
