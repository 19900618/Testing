# CEO dashboard

Gayatri wants one page: nine line charts in a three by three grid. Rows are the metric,
columns are the country.

```
                 Rwanda            Uganda            Kenya
SQM-E            line chart        line chart        line chart
Mason earnings   line chart        line chart        line chart
Cost to serve    line chart        line chart        line chart
```

Each chart: months on the x axis, January 2026 to the current month, two lines, actual
and budget. Under the SQM-E row, one table showing paint SQM-E by country and month.
Paint stays out of the charts.

Add it as a fifth box on the workspace home page, beside Rwanda, Uganda, Kenya and
Classic frontline toolkit. Call it **CEO dashboard**. It is cross-country, so it does not
belong inside a country workspace.

Read `AGENTS.md` and `docs/HANDOVER.md` first. Logic goes in BigQuery, the app reads
columns.

**Two things to verify before writing any query.** I could not reach BigQuery when
writing this. Run `INFORMATION_SCHEMA.COLUMNS` on every table named below and confirm the
column names match. If one differs, use the real name and tell me which.

---

## The three metrics, and exactly where they come from

These definitions are settled. Do not re-derive them, and do not substitute a different
table because it looks similar.

### 1. SQM-E built

**Source:** `raw_data_from_salesforce.company_kpi_monthly`, one row per country per month.
Column names below are confirmed against the live schema.

```sql
SELECT country, month, month_label, sqme_built, sqme_target, paint_sqme, is_current_month
FROM `earth-enable-main.raw_data_from_salesforce.company_kpi_monthly`
WHERE year = 2026 AND NOT is_future_month
ORDER BY country, month
```

- `sqme_built` is the actual line, `sqme_target` is the budget line.
- SQM-E is already weighted: a floor counts its full area, plaster and paint count a
  third. It is not square metres. Never sum raw `total_square_meters`.
- The month is the month the build **completed**.
- Contractor record types are already excluded. Leave that alone.
- `sqme_built` **excludes paint by design**. `sqme_built_all` is built plus paint plus
  other, and is not what we plot.

**Paint, for the table under the row.** Use `paint_sqme` from the same view. Do not
compute it from `all_opportunities_master`. For scale: Uganda was 723 in July and 1,221
in August, Rwanda is near zero, Kenya is zero.

### 2. Average mason earnings

**Source:** `raw_data_from_salesforce.productive_masons_monthly`, one row per country per
month. This is the view the mason bonus uses. Do not compute earnings from timesheets.

The rule inside it, which must not change:

- Earnings are `amount_of_payment`, **gross**, not `net_payment`
- Only rows where `status = 'Approved'`
- Bucketed by the timesheet's **`end_date`**, not `start_date`
- The bar is the **weekly threshold times the number of Wednesdays in the month**
- Weekly thresholds: Rwanda 25,000 RWF, Uganda 62,500 UGX, Kenya 2,500 KES

`avg_pay` is the monthly average per mason paid. `threshold` is the monthly bar, and it
already moves with the calendar: Rwanda was 125,000 in July, which has five Wednesdays,
and 100,000 in August, which has four.

Gayatri's sketch is weekly with a flat target, so divide both by the Wednesday count.
**Do not hardcode the weekly thresholds.** Dividing the existing `threshold` returns them
exactly, so the numbers can never drift from the bonus rule.

```sql
WITH w AS (
  SELECT country, month, masons_paid, avg_pay, threshold,
    (SELECT COUNTIF(EXTRACT(DAYOFWEEK FROM d) = 4)
     FROM UNNEST(GENERATE_DATE_ARRAY(month, LAST_DAY(month))) d) AS wednesdays
  FROM `earth-enable-main.raw_data_from_salesforce.productive_masons_monthly`
  WHERE month BETWEEN DATE '2026-01-01' AND DATE_TRUNC(CURRENT_DATE(), MONTH)
)
SELECT country, month, masons_paid,
       avg_pay / wednesdays  AS weekly_actual,
       threshold / wednesdays AS weekly_target
FROM w
```

`weekly_target` will come out at 25,000, 62,500 and 2,500 every month. If it does not,
something upstream has changed and you should stop and tell me.

### 3. Cost to serve

**Source:** `qb_reporting.country_financials`, one row per country per month. Confirmed
columns include `books_closed`, `sqme_built`, `sqme_target`, `burn_branch`, `burn_country`,
`burn_company`, `cts_branch`, `cts_country`, `cts_company` and `rate_per_usd`.

```
cts_branch  = (revenue - cogs - district expense) / sqme_built
cts_country = cts_branch less country overheads
cts_company = cts_country less global overheads
```

All three are **negative**, because cost to serve is a cost per SQM-E.

**Plot the absolute value**, so the chart reads as a cost and the axis starts at zero.
Label the y axis "Cost per SQM-E" and add a footnote: lower is better, and a budget line
above the actual line means we are spending less than planned.

**Only plot months where `books_closed = 1`.** A month where QuickBooks has no COGS posted
yet produces a meaningless number. Leave the point out rather than plotting zero, and name
the unclosed months under the chart.

**The budget has to be derived.** `qb_reporting.branch_financial_targets` is long format,
`country, branch, month, metric, target_value`, and holds only four metrics: `revenue`,
`cogs`, `district_expense` and `sqme`. There is no burn row and no CTS row.

```sql
SELECT country, month,
  ( SUM(IF(metric = 'revenue',          target_value, 0))
  - SUM(IF(metric = 'cogs',             target_value, 0))
  - SUM(IF(metric = 'district_expense', target_value, 0)) )
  / NULLIF(SUM(IF(metric = 'sqme', target_value, 0)), 0) AS cts_branch_budget
FROM `earth-enable-main.qb_reporting.branch_financial_targets`
GROUP BY country, month
```

Sum the numerators and denominators. Never average branch percentages.

That budget stops at district overheads, so it matches **`cts_branch`**, not `cts_company`,
which also carries country and global overheads. The two are far apart: Rwanda in July was
about −7,261 at country level and −10,062 at company level.

- **Build this now:** `cts_branch` against that budget. Apples to apples, ties to the
  workbook, nothing new needed. Label the chart "Cost to serve, branch level".
- **Follow-up, flag it to me:** the full company number needs the country and global
  expense budgets from the **Consolidated P&L Budget** sheet of the VG workbook, which is
  not in BigQuery yet.

Do not quietly plot company actuals against a branch budget. The gap would look like
overspending that has not happened.

**One performance note.** `country_financials` is a view over the QuickBooks tables and is
slow: simple queries against it did not return inside a minute. Read it once per page
load, cache it like every other page, and if the page is sluggish, tell me rather than
working around it.

---

## Country nuances that change the numbers

Each of these has bitten us before. Carry them as footnotes on the relevant chart.

**Currency.** Rwanda RWF, Uganda UGX, Kenya KES. Each chart is in its own currency, which
is fine because they are separate charts. Never mix them on one axis. `country_financials`
carries `rate_per_usd` if a USD view is ever wanted.

**Rwanda RBF.** RBF subsidy income sits in Other Income, not revenue, so it is excluded
from the cost to serve chain. Rwanda showed zero RBF in July and August against roughly
80M a month earlier, which is almost certainly a booking delay, not real. If those months
look unusual on the Rwanda CTS chart, that is why. Flag it rather than smoothing it.

**Uganda FX.** Uganda's foreign exchange gain or loss sits under Other Expenses, outside
the global overhead subtotal, and is excluded. It is large, about 148M UGX in July, so
including it by accident would move the chart badly.

**Uganda unattributed district spend.** Uganda has spend classed to "Not specified" and to
hub classes, which sits at country level rather than branch. This is why Uganda's branch
district totals do not foot to the country figure. Intended, do not fix.

**Rwanda Full House.** Rwanda's Full House section sits under Other Expenses and is
excluded from cost to serve, consistent with the data dictionary.

**Kenya's scale.** Kenya is small enough that one month swings the line hard. Keep the
data labels on every point so nobody reads a two-job month as a trend.

**The current month is partial.** Mark the last point on every chart as incomplete, or
stop the line at the last complete month and show the partial point hollow.

---

## The page

- Three by three grid. Row label on the left, country name across the top. One chart type
  throughout, no variation.
- **Actual is a solid line, budget is dashed.** Same two colours on all nine charts, and a
  single legend at the top of the page rather than one per chart.
- **Data labels at every point**, matching the standard now used across the app.
- Y axis starts at zero on all nine.
- Below the SQM-E row, one table: country down the side, months across, paint SQM-E in the
  cells. Include it in the copy.
- Every chart and the table get a **Copy table** button, and the page gets Download CSV
  and Copy for Google Sheets, same as every other page.
- A year filter at the top, defaulting to 2026, so the page keeps working in January.
- One freshness line: when Salesforce last synced, and that QuickBooks figures move only
  when the books are closed.
- Works at 390px: the grid becomes one column, three charts per metric, in country order.

---

## Do not

- Do not recompute SQM-E, mason earnings or cost to serve from raw tables. Every one of
  these has a settled view, and every one has been reconciled to either the P&L or the
  bonus calculation.
- Do not use `net_payment` for earnings, or `start_date` for the earnings month.
- Do not average branch percentages to get a country figure. Sum the numerators and
  denominators.
- Do not plot cost to serve months where the books are not closed.
- Do not put paint into the SQM-E charts.
- Do not touch the Classic frontline toolkit or the three country workspaces.

---

## Acceptance

- `npx tsc --noEmit` silent, `npm run build` passes.
- Nine charts, three by three, January to the current month, actual and budget on each.
- SQM-E ties to `company_kpi_monthly` exactly for every country and month.
- Mason earnings use gross approved pay by end date, and the budget line is flat at
  25,000, 62,500 and 2,500 in the three countries.
- Cost to serve shows only closed months, plots the absolute cost, and its budget is
  `SUM(burn_target) / SUM(sqme_target)` per country per month, not an average.
- The paint table appears under the SQM-E row and nowhere else.
- Copy and export buttons on every chart and table.
- Usable at 390px.

Tell me which of Option A or B you built for cost to serve, and any column name that
turned out to differ from this document.

---

## Appendix. The product definition, used everywhere

This is the company's canonical product classification. It is the definition of record.
Apply it wherever a query needs to know what a contract is, and do not write a different
`LIKE` test anywhere. The order of the branches matters: repair is tested before paint,
paint before plaster, plaster before floor.

Source field is `COALESCE(product_interest_c, new_product_interest_c)`, the old field
first, because a large number of older floors only carry the legacy value.

```sql
CASE
  WHEN Product_Interest IS NULL THEN "Unknown"
  WHEN CONTAINS_TEXT(LOWER(Product_Interest), "repair")
       OR Product_Interest IN ("Rescreed","Masking","Recompacting","Premium Redo") THEN "Repair"
  WHEN CONTAINS_TEXT(LOWER(Product_Interest), "paint")   THEN "Paint"
  WHEN CONTAINS_TEXT(LOWER(Product_Interest), "plaster") THEN "Plaster"
  WHEN CONTAINS_TEXT(LOWER(Product_Interest), "floor")
       OR Product_Interest IN (
            "Ubudehe 1 Subsidy",
            "Ishema",
            "Cluster",
            "Damarara",
            "Franchise",
            "Free LOMA Full",
            "Free LOMA Partial",
            "Kwigira",
            "Loan contract",
            "LOMA Full Service",
            "LOMA Partial Service",
            "Pro Bono",
            "Subcontract - Free LOMA Full",
            "Subcontract - Free LOMA Partial",
            "Subcontract - LOMA Full",
            "Subcontract - LOMA Partial",
            "Subcontract Institutional - Full LOMA",
            "Subcontract Institutional - Partial LOMA"
       ) THEN "Floor"
  WHEN CONTAINS_TEXT(LOWER(Product_Interest), "house")    THEN "House"
  ELSE "Other"
END
```

**For this page you should not need it**, because `company_kpi_monthly` already carries
`floor_sqme`, `plaster_sqme`, `paint_sqme` and `other_sqme`. Two jobs:

1. **Verify** that the split inside `company_kpi_monthly` matches this CASE. If it does
   not, stop and tell me which products land differently, and how much SQM-E moves. Do not
   fix it inside this page.
2. Use this CASE, unchanged, in any new query on any page that classifies product.
