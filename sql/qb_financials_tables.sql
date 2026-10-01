-- =============================================================================
-- qb_reporting.country_financials and qb_reporting.branch_financials as
-- tables refreshed daily (docs/cts-page-and-revenue.md, item 1, "one thing
-- to fix while you are in here").
--
-- Both are views over the QuickBooks transaction tables (pl_branch_monthly,
-- itself a union of the three countries' P&L summaries) and take about 30
-- seconds each: the Cost to serve page and the CEO dashboard cannot sit on
-- that. QuickBooks figures only change when a month's books close, so a
-- daily rebuild is plenty.
--
-- What this script does, in order, and why the order matters:
--   1. Creates the two tables from the deployed view definitions (read back
--      from BigQuery on 2026-09-29 and copied below unchanged).
--   2. Repoints the two view names at the tables, so Looker, the CEO
--      dashboard and the Cost to serve page keep reading the same names and
--      nothing else breaks. Same columns, same figures.
--   3. Is what the daily scheduled query runs: step 1 again. Step 1 must
--      keep the original bodies (below), because once step 2 has run, the
--      view names resolve to the tables and a rebuild "from the view" would
--      copy the table onto itself.
--
-- Deployment: the app's service account cannot create tables or views, so
-- run this through the BigQuery connector or the console, then schedule
-- "RUN ONLY THE TWO CREATE OR REPLACE TABLE statements" daily (03:00 Africa/
-- Kigali is after the accountants' day). Until it is deployed the app caches
-- each read for 15 minutes and the cron keeps the entry warm, so a visitor
-- rarely waits, and the first visitor after a deploy waits about 30 seconds.
--
-- Not changed: the arithmetic. If a figure here disagrees with Looker, the
-- bug is in the reader, not here.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1. The tables (the daily scheduled query runs these two statements).
-- ---------------------------------------------------------------------------

CREATE OR REPLACE TABLE `earth-enable-main.qb_reporting.country_financials_daily`
OPTIONS (description = "country_financials materialised once a day from the QuickBooks P&L tables; the view country_financials reads this table.")
AS
WITH
act AS (
SELECT p.country, p.month_start AS month, SUM(IF(p.pl_group='Income', p.amount_local,0)) AS revenue, SUM(IF(p.pl_group='Cost of Goods Sold', p.amount_local,0)) AS cogs, SUM(IF(p.pl_group='District Overheads', p.amount_local,0)) AS district_expense, SUM(IF(p.pl_group='Country Overheads', p.amount_local,0)) AS country_expense, SUM(IF(p.pl_group='Global Overheads', p.amount_local,0)) AS global_expense, SUM(IF(p.pl_group='Other Income', p.amount_local,0)) AS other_income
FROM `earth-enable-main.qb_reporting.pl_branch_monthly` p
GROUP BY p.country, p.month_start),
sq AS (
SELECT country, period_start AS month, SUM(sqme_built) AS sqme_built
FROM `earth-enable-main.raw_data_from_salesforce.company_geo`
WHERE grain='month'
GROUP BY country, period_start),
tg AS (
SELECT country, month, SUM(IF(metric='sqme', target_value,0)) AS sqme_target
FROM `earth-enable-main.qb_reporting.branch_financial_targets`
GROUP BY country, month)
SELECT a.country, a.month, FORMAT_DATE('%Y-%m (%b)', a.month) AS month_label, EXTRACT(YEAR
FROM a.month) AS year, IF(a.cogs = 0, 0, 1) AS books_closed, a.revenue, a.cogs, a.district_expense, a.country_expense, a.global_expense, a.other_income, s.sqme_built, tg.sqme_target, fx.rate_per_usd, a.revenue - a.cogs - a.district_expense AS burn_branch, a.revenue - a.cogs - a.district_expense - a.country_expense AS burn_country, a.revenue - a.cogs - a.district_expense - a.country_expense - a.global_expense AS burn_company, SAFE_DIVIDE(a.revenue - a.cogs - a.district_expense - a.country_expense - a.global_expense, fx.rate_per_usd) AS burn_company_usd, SAFE_DIVIDE(a.revenue - a.cogs - a.district_expense - a.country_expense, fx.rate_per_usd) AS burn_country_usd, SAFE_DIVIDE(a.revenue - a.cogs - a.district_expense, s.sqme_built) AS cts_branch, SAFE_DIVIDE(a.revenue - a.cogs - a.district_expense - a.country_expense, s.sqme_built) AS cts_country, SAFE_DIVIDE(a.revenue - a.cogs - a.district_expense - a.country_expense - a.global_expense, s.sqme_built) AS cts_company, SAFE_DIVIDE(SAFE_DIVIDE(a.revenue - a.cogs - a.district_expense - a.country_expense - a.global_expense, s.sqme_built),
fx.rate_per_usd) AS cts_company_usd, SAFE_DIVIDE(SAFE_DIVIDE(a.revenue - a.cogs - a.district_expense - a.country_expense, s.sqme_built),
fx.rate_per_usd) AS cts_country_usd
FROM act a
LEFT JOIN sq s ON s.country=a.country AND s.month=a.month
LEFT JOIN tg ON tg.country=a.country AND tg.month=a.month
LEFT JOIN `earth-enable-main.qb_reporting.fx_rates_monthly` fx ON fx.country=a.country AND fx.month=a.month
WHERE a.month <= DATE_TRUNC(CURRENT_DATE(),
MONTH);

CREATE OR REPLACE TABLE `earth-enable-main.qb_reporting.branch_financials_daily`
OPTIONS (description = "branch_financials materialised once a day from the QuickBooks P&L tables; the view branch_financials reads this table.")
AS
WITH
act AS (
SELECT country, branch, month_start AS month, SUM(IF(pl_group='Income', amount_local,0)) AS revenue, SUM(IF(pl_group='Cost of Goods Sold', amount_local,0)) AS cogs, SUM(IF(pl_group='District Overheads', amount_local,0)) AS district_expense, SUM(IF(pl_group='Other Income', amount_local,0)) AS other_income
FROM `earth-enable-main.qb_reporting.pl_branch_monthly`
GROUP BY country, branch, month_start),
closed AS (
SELECT country, month_start AS month, IF(SUM(IF(pl_group='Cost of Goods Sold', amount_local,0)) = 0, 0, 1) AS books_closed
FROM `earth-enable-main.qb_reporting.pl_branch_monthly`
GROUP BY country, month_start),
tgt AS (
SELECT country, branch, month, SUM(IF(metric='revenue', target_value,0)) AS revenue_target, SUM(IF(metric='cogs', target_value,0)) AS cogs_target, SUM(IF(metric='district_expense', target_value,0)) AS district_expense_target, SUM(IF(metric='sqme', target_value,0)) AS sqme_target
FROM `earth-enable-main.qb_reporting.branch_financial_targets`
GROUP BY country, branch, month),
sq AS (
SELECT country, branch, period_start AS month, SUM(sqme_built) AS sqme_built
FROM `earth-enable-main.raw_data_from_salesforce.company_geo`
WHERE grain='month'
GROUP BY country, branch, period_start),
base AS (
SELECT COALESCE(t.country, a.country) AS country, COALESCE(t.branch, a.branch) AS branch, COALESCE(t.month, a.month) AS month, IFNULL(a.revenue,0) AS revenue, IFNULL(a.cogs,0) AS cogs, IFNULL(a.district_expense,0) AS district_expense, IFNULL(a.other_income,0) AS other_income, t.revenue_target, t.cogs_target, t.district_expense_target, t.sqme_target, s.sqme_built
FROM tgt t
FULL OUTER JOIN act a ON a.country=t.country AND a.branch=t.branch AND a.month=t.month
LEFT JOIN sq s ON s.country=COALESCE(t.country,a.country) AND s.branch=COALESCE(t.branch, a.branch) AND s.month=COALESCE(t.month, a.month))
SELECT b.*, FORMAT_DATE('%Y-%m (%b)', b.month) AS month_label, EXTRACT(YEAR
FROM b.month) AS year, IFNULL(c.books_closed, 0) AS books_closed, b.revenue - b.cogs - b.district_expense AS burn, b.revenue_target - b.cogs_target - b.district_expense_target AS burn_target, SAFE_DIVIDE(b.revenue - b.cogs - b.district_expense, b.sqme_built) AS cost_to_serve,SAFE_DIVIDE(b.revenue - b.cogs - b.district_expense, fx.rate_per_usd) AS burn_usd,SAFE_DIVIDE(b.revenue_target - b.cogs_target - b.district_expense_target, fx.rate_per_usd) AS burn_target_usd, SAFE_DIVIDE(b.revenue_target - b.cogs_target - b.district_expense_target, b.sqme_target) AS cost_to_serve_target, fx.rate_per_usd
FROM base b
LEFT JOIN closed c ON c.country=b.country AND c.month=b.month
LEFT JOIN `earth-enable-main.qb_reporting.fx_rates_monthly` fx ON fx.country=b.country AND fx.month=b.month
WHERE b.branch IN (
SELECT DISTINCT branch
FROM `earth-enable-main.qb_reporting.branch_financial_targets`) AND b.month <= DATE_TRUNC(CURRENT_DATE(),
MONTH);

-- ---------------------------------------------------------------------------
-- 2. The view names, kept, now over the tables (run once).
-- ---------------------------------------------------------------------------

CREATE OR REPLACE VIEW `earth-enable-main.qb_reporting.country_financials` AS
SELECT * FROM `earth-enable-main.qb_reporting.country_financials_daily`;

CREATE OR REPLACE VIEW `earth-enable-main.qb_reporting.branch_financials` AS
SELECT * FROM `earth-enable-main.qb_reporting.branch_financials_daily`;

-- ---------------------------------------------------------------------------
-- Check after deploying: both read in under a second and Rwanda January
-- still reads 7.0 USD at country level.
-- ---------------------------------------------------------------------------
-- SELECT month, ROUND(cts_country_usd, 1) AS cts_usd
-- FROM `earth-enable-main.qb_reporting.country_financials`
-- WHERE country = 'Rwanda' AND year = 2026 AND books_closed = 1 ORDER BY month;
