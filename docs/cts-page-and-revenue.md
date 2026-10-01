# Cost to serve page, live revenue, and two fixes

This supersedes `docs/live-revenue-and-fixes.md`. Everything outstanding is here.

Read `AGENTS.md` and `docs/HANDOVER.md` first. Logic in BigQuery, the app reads columns.

---

## 1. New page: Cost to serve

A **Cost to serve** page in each of the three country workspaces. Same page, same code,
country comes from the workspace.

**The numbers must match the Looker dashboard exactly.** They were argued through when
Looker was built and they are not being reopened. If a figure here disagrees with Looker,
that is a bug in this page, not a new definition.

### Sources, and which layer uses which

| Layer | Actual | Target |
|---|---|---|
| Country | `qb_reporting.country_financials` → `cts_country` | `qb_reporting.country_financial_targets` |
| Branch | `qb_reporting.branch_financials` → `cost_to_serve` | same view → `cost_to_serve_target` |

This mirrors Looker, which uses country financials for the country charts and branch
financials for the branch table. Do not compute either from raw QuickBooks.

`branch_financials` already carries `cost_to_serve`, `cost_to_serve_target`, `burn`,
`burn_target`, `books_closed` and `rate_per_usd`. Nothing needs deriving at branch level.

The country target does need deriving, from the table I loaded from the VG budget
workbook:

```sql
SELECT country, month,
  ( SUM(IF(metric = 'revenue',          target_value, 0))
  - SUM(IF(metric = 'cogs',             target_value, 0))
  - SUM(IF(metric = 'district_expense', target_value, 0))
  - SUM(IF(metric = 'country_expense',  target_value, 0)) )
  / NULLIF(SUM(IF(metric = 'sqme', target_value, 0)), 0) AS cts_country_target
FROM `earth-enable-main.qb_reporting.country_financial_targets`
GROUP BY country, month
```

Sum the numerators and denominators. Never average branch figures to get a country one.

### Rules that apply to every figure on this page

- **Currency toggle: USD or local.** A two-button control in the filter bar, `USD` and
  the country's own currency, `RWF`, `UGX` or `KES`. **Default to USD**, because that is
  what Looker shows and the acceptance figures below are in USD. The toggle drives the
  whole page: both charts, the branch table, the scorecards and the exports. Axis and
  scorecard labels change with it.

  Conversion uses `rate_per_usd`, which traces to `qb_reporting.fx_rates_monthly`, loaded
  from the VG budget workbook. These are the budget rates, not daily actuals, which is
  right here: dividing actual and target by the same rate keeps currency movement out of
  an operational cost chart. Say so in the "How these are calculated" text.

  Two things that follow. The rates only cover 2026, so if a month has no rate, show no
  point rather than dividing by null, and say so under the chart. And local currency is
  not comparable across countries, so if the page ever gains a cross-country view, that
  view stays in USD whatever the toggle says.
- **Cost to serve is negative** in the data. Plot the absolute value so the axis starts at
  zero and the chart reads as a cost. Footnote: lower is better, and a budget line above
  the actual line means we are spending less than planned.
- **Only months where `books_closed = 1`.** Leave unclosed months out rather than plotting
  zero, and name them under the chart.
- **January to the current month**, extending as months pass.
- Global overheads are in neither line at either layer.

### Layout

**Three scorecards**

```
Cost to serve, this month     Year to date              Against budget
USD 5.0                       USD 5.3                   1.6 above
per SQM-E, July               January to July           budget 3.4
```

**Chart 1, country.** Line chart, actual against target, January to the current month,
USD, data labels at every point. This is Looker's 9d.

**Chart 2, branches.** Twenty-one branches will not fit as twenty-one lines, so use a
table and let people drill:

- Rows are branches, columns are months January to current, cells are cost to serve in
  USD, shaded so the expensive branches stand out
- A **Target** column and a **Year to date** column on the right
- Sorted worst first
- **Clicking a branch row opens its own line chart** underneath, actual against that
  branch's target, same shape as chart 1

That gives the whole picture at a glance and the trend for any single branch in one click.

**Copy table** on the table, and Download CSV and Copy for Google Sheets on the page, the
same as everywhere else.

### Acceptance

With the toggle on USD. Rwanda, country level, must read: January 7.0, February 5.3, March 5.8, April 5.0,
May 5.1, June 4.9, July 5.0, and year to date 5.3. Those are the figures on the Looker
page today, and the same figures the CEO dashboard shows. If they do not match, stop and
tell me before going further.

Then switch the toggle to RWF and check one month by hand: the local figure divided by
that month's `rate_per_usd` returns the USD figure.

### One number, three places

Country cost to serve now appears in three places, and all three must return the same
figure for the same country and month:

| Where | Layer | Source | Currency |
|---|---|---|---|
| Looker, 9c and 9d | country | `country_financials.cts_country` | USD |
| CEO dashboard, cost to serve row | country | same | USD |
| This page, chart 1 | country | same | USD |

They agree only if the CEO dashboard change was actually applied. It was specified as
country level against `country_financial_targets`, but it shipped originally at branch
level, which reads about 2 USD lower in Rwanda.

**Check the CEO dashboard first.** If it is still on `cts_branch`, fix it before building
this page, then confirm Rwanda July reads 5.0 on both. Two pages in the same app
disagreeing about cost to serve is worse than either being late.

The branch layer is a genuinely different number and is expected to be lower. Label it
clearly wherever it appears so nobody compares the two by accident.

### One thing to fix while you are in here

`country_financials` and `branch_financials` are views over the QuickBooks transaction
tables and they are slow: simple queries against them did not return inside a minute.
A user-facing page cannot sit on that.

Materialise both into tables refreshed on a schedule, the way `capacity_week` was handled.
QuickBooks data only changes when books close, so a daily refresh is plenty. Keep the
existing view names pointing at the tables so nothing else breaks, and save the SQL in
`sql/`.

---

## 2. Live revenue from Salesforce

Every revenue figure in the app comes from `pl_kpi_v2`, which is QuickBooks. It only moves
when a month's books close and it cannot be cut below country level.

### The field

**`salesforce.opportunity.total_payment_amount_c`**, local currency. Confirmed by Vinamra
as the contract value field. Fully populated, zero nulls, all three countries.

**Known and accepted.** A second field, `total_revenue_c`, is what actually reconciles to
booked revenue in Kenya: May 313,698 against QuickBooks 313,697, July 613,946 against
613,945. `total_payment_amount_c` runs 30 to 50% below in Kenya, about 6% below in Rwanda,
and is identical in Uganda. Vinamra is working through this on the finance side and will
say if the field should change. **Build with `total_payment_amount_c` and make the field
easy to swap**, one named constant or one line in the view.

### The view

Create `raw_data_from_salesforce.completed_value_daily`.

- **Grain:** country, branch, territory, CSO, mason, product, completion date
- **Measure:** `SUM(total_payment_amount_c)` for opportunities completing on that date
- **Completion rule:** the same one `contracts_built` uses in the capacity views. Revenue
  and builds must always count the same set of jobs.
- **Exclude** the Contractor record type
- **Product:** the canonical CASE from `docs/journey-filters-products.md`

Save the SQL in `sql/`.

### In the app

Replace the QuickBooks revenue figure on Overview, Sales and collections, Masons and
Capacity planning. Label it **Revenue**, with a muted sub-line: *contract value of builds
completed, live from Salesforce*. Against target, use the existing `revenue_target`.

It now cuts by territory, branch, CSO and mason, so add it where those tables benefit. Use
judgement; not every table needs a revenue column.

**Leave the CEO dashboard and the new Cost to serve page alone.** Both need real posted
revenue and real posted costs from QuickBooks. Mixing a Salesforce revenue line into a
QuickBooks cost calculation produces a number that means nothing.

Figures will not match QuickBooks month to month. July: Rwanda 38.3m against 36.1m booked,
Uganda 62.9m against 53.7m, Kenya 429k against 614k. Timing, and expected. Do not
reconcile it away. Where both could be seen together, label them clearly.

---

## 3. Two CSO views still carry their own product CASE

`salesforce.cso_headcount_app_v1` and `salesforce.cso_performance_app_v1` classify product
inline, and their CASE is **missing the Repair branch**, so a product named like "Plaster
repair" is scored as a plaster sale.

Replace both with the canonical CASE. **Keep `WHERE product IN ('Floor','Plaster','Paint')`
exactly as it is**, so a CSO who sold only paint still appears in the lists. Paint is
excluded from scored SQM-E, never from the people.

Report how many contracts move into Repair, by country.

---

## 4. Confirm these are done

If any is not, say so rather than fixing it silently.

- [ ] CEO dashboard cost to serve is country level, in USD, against
      `country_financial_targets`, and Rwanda July reads 5.0 there and on the new page
- [ ] Mason earnings use a flat monthly target: 100,000 RWF, 250,000 UGX, 10,000 KES
- [ ] Every page says Salesforce syncs every 15 minutes, cache is 15 minutes
- [ ] Scored SQM-E is floor plus plaster, ceiling plaster inside plaster, paint shown
      small and never on a chart
- [ ] Customer journey on the country pages is the reused Classic component
- [ ] Territory and branch dropdown is in the filter bar on every page
- [ ] What the Journey board's SQM-E actually includes

---

## Order

1. Item 3, the classification fix. Report what moved.
2. Item 1, the Cost to serve page, including materialising the two slow views.
3. Item 2, live revenue.
4. Item 4, report the checklist.

`npx tsc --noEmit`, `npm run build`, merge to main and push as EarthEnable BI.
