-- =============================================================================
-- qb_reporting.country_financial_targets
--
-- The country-level budget for the CEO dashboard's cost to serve chart, one
-- row per country x month x metric, local currency, for the twelve months of
-- the budget year. Loaded 2026-09-28 from the VG 2026 budget workbook, sheets
-- "Rwanda P&L Budget", "Uganda P&L Budget" and "Kenya P&L Budget":
--
--   sqme              SQM-E to build in the month
--   revenue           budgeted revenue
--   cogs              budgeted cost of goods sold
--   district_expense  budgeted district (branch) expenses
--   country_expense   budgeted country overheads
--
-- The dashboard derives the budget as
--   country CTS budget = (revenue - cogs - district_expense - country_expense) / sqme
-- per country and month, numerators and denominators summed, never averaged,
-- then divides by qb_reporting.fx_rates_monthly.rate_per_usd. Global overheads
-- are not in the table and not in the chart. The actual it is compared with is
-- cts_country in qb_reporting.country_financials, closed months only.
--
-- This is a SCRIPT: run it from the BigQuery console or the connector to
-- (re)create the table. When the 2027 budget lands, add the year's twelve
-- values per country and metric below (or a second block with target_year
-- 2027 and UNION ALL) and re-run; the dashboard filters on the year in the
-- URL and needs no change.
--
-- NOTE: this table AND qb_reporting.fx_rates_monthly both stop at December
-- 2026. A 2027 month has no budget and no rate until both are extended, and
-- the chart shows no budget line for it rather than a wrong one.
--
-- Checked on load (USD, budget / rate_per_usd): Rwanda Jan 4.7 Jul 3.4,
-- Uganda Jan 41.5 Jul 8.7, Kenya Jan 93.7 Jul 13.9.
-- =============================================================================

DECLARE target_year INT64 DEFAULT 2026;

CREATE OR REPLACE TABLE `earth-enable-main.qb_reporting.country_financial_targets`
OPTIONS (description = 'Monthly country-level budget from the VG 2026 budget workbook, sheets Rwanda/Uganda/Kenya P&L Budget. Rows: sqme, revenue, cogs, district_expense, country_expense. Local currency. Country CTS budget = (revenue - cogs - district_expense - country_expense) / sqme. Built by sql/country_financial_targets.sql.')
AS
SELECT r.country, DATE(target_year, o + 1, 1) AS month, r.metric, CAST(t AS FLOAT64) AS target_value
FROM UNNEST([
    STRUCT('Rwanda' AS country, 'sqme' AS metric, [31473.33, 36593.33, 41796.33, 36593.33, 52124, 52124, 49669, 52124, 52124, 52124, 49669, 52124] AS by_month),
    STRUCT('Rwanda' AS country, 'revenue' AS metric, [42160567.8, 49030305.08, 55982737.29, 49030305.08, 69808449.15, 69808449.15, 66510491.53, 69808449.15, 69808449.15, 69808449.15, 66510491.53, 69808449.15] AS by_month),
    STRUCT('Rwanda' AS country, 'cogs' AS metric, [94795706.59, 110212949.2, 125865497.5, 110212949.2, 156948270, 156948270, 149548262.8, 156948270, 156948270, 156948270, 149548262.8, 156948270] AS by_month),
    STRUCT('Rwanda' AS country, 'district_expense' AS metric, [77707728.09, 77707728.09, 77707728.09, 77707728.09, 77707728.09, 77707728.09, 77707728.09, 77707728.09, 77707728.09, 77707728.09, 77707728.09, 77707728.09] AS by_month),
    STRUCT('Rwanda' AS country, 'country_expense' AS metric, [85565083.34, 87165083.34, 85565083.34, 85565083.34, 85565083.34, 85565083.34, 85565083.34, 85565083.34, 85565083.34, 85565083.34, 85565083.34, 164666216.1] AS by_month),
    STRUCT('Uganda' AS country, 'sqme' AS metric, [1633.33, 4450, 5399.33, 6082.67, 6823.33, 7714, 8574.67, 9197.33, 9643.33, 11422.67, 11570.67, 11422.67] AS by_month),
    STRUCT('Uganda' AS country, 'revenue' AS metric, [28967796.61, 78759322.03, 95561016.95, 107666101.7, 120752542.4, 136516949.2, 151767796.6, 162762711.9, 170694915.3, 202150847.5, 204755932.2, 202150847.5] AS by_month),
    STRUCT('Uganda' AS country, 'cogs' AS metric, [23348964.47, 63534004.78, 77087786.81, 86849751.39, 97413247.9, 110130334.1, 122427126.2, 131304861, 137691410, 163078048.4, 165184104.1, 163078048.4] AS by_month),
    STRUCT('Uganda' AS country, 'district_expense' AS metric, [113536937.4, 119086937.4, 119086937.4, 126066937.4, 127266937.4, 127266937.4, 133404937.4, 140783270.7, 140783270.7, 144723270.7, 144723270.7, 144723270.7] AS by_month),
    STRUCT('Uganda' AS country, 'country_expense' AS metric, [139430820.2, 181773191.8, 147585946.2, 145956866.1, 432009161, 201432908.5, 171288744.4, 148578130.4, 154578130.4, 148969448.5, 148969448.5, 198969448.5] AS by_month),
    STRUCT('Kenya' AS country, 'sqme' AS metric, [142.67, 428, 853, 853, 740.67, 740.67, 995.67, 1138.33, 1209.67, 1564.33, 1495, 1281] AS by_month),
    STRUCT('Kenya' AS country, 'revenue' AS metric, [74655.17, 223965.52, 446637.93, 446637.93, 387931.03, 387931.03, 521293.1, 595948.28, 633275.86, 819051.72, 782586.21, 670603.45] AS by_month),
    STRUCT('Kenya' AS country, 'cogs' AS metric, [67270.8, 201812.4, 402404.37, 402404.37, 349507.14, 349507.14, 469675.17, 536945.97, 570581.37, 737944.75, 705122.97, 604216.77] AS by_month),
    STRUCT('Kenya' AS country, 'district_expense' AS metric, [506846.55, 537039.66, 539266.38, 769166.38, 754579.31, 731579.31, 755912.93, 733659.48, 757032.76, 735890.52, 758525.86, 1159406.03] AS by_month),
    STRUCT('Kenya' AS country, 'country_expense' AS metric, [1251777.44, 993323.99, 1060437.36, 1094937.36, 1104643.82, 1149643.82, 1145310.63, 1095683.91, 1160870.55, 1096799.43, 1106617.1, 1197057.18] AS by_month)
]) AS r, UNNEST(r.by_month) AS t WITH OFFSET o;

-- The budget the dashboard reads, for a check after loading:
--
-- SELECT b.country, FORMAT_DATE('%Y-%m', b.month) AS month,
--   ROUND(ABS(b.cts_country_budget) / fx.rate_per_usd, 2) AS budget_usd
-- FROM (
--   SELECT country, month,
--     ( SUM(IF(metric = 'revenue',          target_value, 0))
--     - SUM(IF(metric = 'cogs',             target_value, 0))
--     - SUM(IF(metric = 'district_expense', target_value, 0))
--     - SUM(IF(metric = 'country_expense',  target_value, 0)) )
--     / NULLIF(SUM(IF(metric = 'sqme', target_value, 0)), 0) AS cts_country_budget
--   FROM `earth-enable-main.qb_reporting.country_financial_targets`
--   GROUP BY country, month
-- ) b
-- JOIN `earth-enable-main.qb_reporting.fx_rates_monthly` fx USING (country, month)
-- ORDER BY 1, 2;
