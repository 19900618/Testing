-- =============================================================================
-- raw_data_from_salesforce.branch_capacity_targets
--
-- Uganda and Kenya targets for the capacity page, one row per country x
-- branch x month. Rwanda keeps reading tl_bonus_targets, which is territory
-- grained; the two are never merged, the capacity script reads whichever
-- applies by country.
--
-- Build targets (contracts per month) are typed in from the VG budget
-- workbook, sheet "UG workings" rows 14 to 23 and "KE workings" rows 14 to
-- 16, month columns E onward, for 2026. They are contracts, not SQM-E:
-- Uganda January is 110 contracts against 1,633 SQM-E, 14.8 per contract,
-- which ties to the sheet's 15 SQM-E floor and 16.7 plaster.
--
-- SQM-E targets are already in BigQuery (qb_reporting.branch_financial_targets,
-- metric 'sqme') and are joined, never re-derived from the workbook.
--
-- Everything else is derived the same way as Rwanda:
--   min_build_productivity = 4 builds per mason per month
--   min_productive_masons  = build_target / 4
--   min_csos               = the country's CSOs per branch (Uganda 9, Kenya 7)
-- Sales and collections targets are derived in the capacity script
-- (build_target x 1.3 and build_target), the same as Rwanda.
--
-- This is a SCRIPT: run it once from the BigQuery console or the connector
-- to (re)create the table. Change a target here and re-run.
-- =============================================================================

DECLARE builds_per_mason_month FLOAT64 DEFAULT 4.0;
DECLARE target_year INT64 DEFAULT 2026;

CREATE OR REPLACE TABLE `earth-enable-main.raw_data_from_salesforce.branch_capacity_targets`
OPTIONS (description = 'Uganda and Kenya branch targets for the capacity page. Build targets typed from the VG budget workbook, SQM-E from qb_reporting.branch_financial_targets. Built by sql/branch_capacity_targets.sql.')
AS
WITH build AS (
  SELECT r.country, r.branch, DATE(target_year, o + 1, 1) AS month, CAST(t AS FLOAT64) AS build_target
  FROM UNNEST([
    STRUCT('Uganda' AS country, 'Jinja'    AS branch, [15, 42, 50, 55, 62, 70, 75, 80, 85, 95, 100, 95] AS by_month),
    STRUCT('Uganda', 'Iganga',   [15, 42, 50, 55, 62, 70, 75, 80, 85, 95, 100, 95]),
    STRUCT('Uganda', 'Mbale',    [15, 42, 50, 55, 62, 70, 75, 80, 85, 95, 100, 95]),
    STRUCT('Uganda', 'Masindi',  [15, 42, 50, 55, 62, 70, 75, 80, 85, 95, 100, 95]),
    STRUCT('Uganda', 'Masaka',   [15, 42, 50, 55, 62, 70, 75, 80, 85, 95, 100, 95]),
    STRUCT('Uganda', 'Ntungamo', [15, 42, 50, 55, 62, 70, 75, 80, 85, 95, 100, 95]),
    STRUCT('Uganda', 'Soroti',   [ 5, 12, 16, 20, 22, 25, 32, 35, 35, 50,  45, 50]),
    STRUCT('Uganda', 'Ibanda',   [ 5, 12, 16, 20, 22, 25, 32, 35, 35, 50,  45, 50]),
    STRUCT('Uganda', 'Mbarara',  [ 5, 12, 16, 20, 22, 25, 32, 35, 35, 50,  45, 50]),
    STRUCT('Uganda', 'Luweero',  [ 5, 12, 16, 20, 22, 25, 32, 35, 35, 50,  45, 50]),
    STRUCT('Kenya',  'Busia',    [ 5, 15, 20, 20, 21, 21, 25, 30, 30, 40,  35, 30]),
    STRUCT('Kenya',  'Bungoma',  [ 5, 15, 20, 20, 21, 21, 25, 25, 30, 40,  35, 30]),
    STRUCT('Kenya',  'Kakamega', [ 0,  0, 20, 20, 10, 10, 20, 25, 25, 30,  35, 30])
  ]) r, UNNEST(r.by_month) t WITH OFFSET o
),
-- CSOs each branch should have. The operating standard from the September
-- 2026 workshops (the budget workbook's 10 and 5 are not used).
csos AS (
  SELECT * FROM UNNEST([STRUCT('Uganda' AS country, 9.0 AS min_csos), STRUCT('Kenya', 7.0)])
),
sqme AS (
  SELECT country, branch, month, target_value AS sqme_target
  FROM `earth-enable-main.qb_reporting.branch_financial_targets`
  WHERE metric = 'sqme' AND country IN ('Uganda', 'Kenya')
)
SELECT
  b.country, b.branch, b.month,
  b.build_target,
  s.sqme_target,
  b.build_target / builds_per_mason_month AS min_productive_masons,
  builds_per_mason_month AS min_build_productivity,
  c.min_csos
FROM build b
JOIN csos c ON c.country = b.country
LEFT JOIN sqme s ON s.country = b.country AND s.branch = b.branch AND s.month = b.month;
