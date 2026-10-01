# Frontline Toolkit — developer handover

Live at **https://eefrontline.vercel.app**. Next.js 16 + React 19 + Tailwind v4, reading
BigQuery, behind a Google login restricted to `@earthenable.org`.

Read this before changing anything. Most of it is hard-won and not obvious from the code.

---

## 1. Get running locally

```bash
npm install
# put gcp-key.json in this folder (ask Vinamra; it is git-ignored and must stay that way)
npm run dev
```

That is the whole setup. **You do not need any Google OAuth secrets locally.** The login gate
is opt-in: `authConfigured` in `src/auth.ts` is false unless `GOOGLE_CLIENT_ID`,
`GOOGLE_CLIENT_SECRET` and `NEXTAUTH_SECRET` are all present, and when it is false the app
skips the gate entirely and shows live data. The only secret you need is the BigQuery
service-account key.

Deploys: merge your branch into `main` and push; Vercel builds it automatically. Never deploy
from a laptop. The full Git rules, including the commit identity Vercel requires, are in `AGENTS.md`.

---

## 2. The one rule about data

**The app is a thin reader. All business logic lives in BigQuery views.** The app never
derives a stage, a target, a product category or a payment threshold. If a number is wrong,
fix the view, not the component.

Views this app owns (all in the `salesforce` dataset, all created by us):

| View | Feeds |
|---|---|
| `customer_journey_app_v2` | Customer journey page (v2 splits collected jobs on the Materials Available tick; a job is Started from the EARLIEST of first mason timesheet, first plaster evaluation, construction start or anti-termite delivery; v1 kept, unused) |
| `customer_journey_events_v1` | Customer journey flow page. One row per job per step forward (Signed, Paid enough to build, Materials ready, Build started, Varnish or paint delivered, Completed, Lost), dated from Salesforce dates only, on top of `customer_journey_app_v2`. A job's position on any date is `MAX(to_key)` up to that date. Paid date = the milestone field, else the day Paid payments crossed the gate, else the last payment |
| `collections_app_v1` | Collections backlog + follow-up list |
| `cso_performance_app_v1` | Rwanda CSO performance, per CSO per month. Source in `sql/`, on `product_class` (2026-09-29; the deployed copy still carries its own identical CASE until the file is run) |
| `cso_pending_app_v1` | Rwanda: each CSO's open follow-up load |
| `cso_headcount_app_v1` | Rwanda: distinct CSO headcount per level. Source in `sql/`, on `product_class`, same note |
| `territory_capacity_app_v1` | Rwanda: builds and masons per territory |
| `cso_performance_ugke_app_v1` | Uganda & Kenya CSO performance, per CSO per month |
| `cso_branch_ugke_app_v1` | Uganda & Kenya builds and targets, per branch per month |
| `cso_pending_ugke_app_v1` | Uganda & Kenya: each CSO's contracts awaiting payment |
| `capacity_week(country, month)` (*) | Capacity planning page, Rwanda, Uganda and Kenya. A table function: one row per country x level (territory, district, manager, country for Rwanda; branch, country for Uganda and Kenya) per week set, distinct counts taken at each level, for the month asked for and the six before it. `territory_capacity_week_v1` is the same function called with NULLs |
| `capacity_mason_week(level, name, week_end)` (*) | Capacity planning deep dive. A table function: the mason roster per week for one territory, district or branch, scored on the company's productive rule in local currency. `territory_mason_week_v1` is the same function called with NULLs |
| `branch_capacity_targets` (*) | Uganda and Kenya branch targets for the capacity page: build target (typed from the VG budget workbook), SQM-E (from `qb_reporting.branch_financial_targets`), masons and CSOs required. Rwanda keeps `tl_bonus_targets`; the two are never merged |
| `completed_value_daily` (*) | Live revenue: contract value (`total_payment_amount_c`) of the builds completed each day, by country, branch, territory, CSO, mason and product. Defined in `sql/completed_value_daily.sql`, not yet deployed; the workspaces carry the same figure inside `capacity_week_v2` (see Revenue under 2b) |

Rwanda and Uganda/Kenya are deliberately separate views and separate pages (`/cso` and
`/cso-ugke`): the business, the targets and the unit of management (territory vs branch) differ.

(*) Live in `raw_data_from_salesforce`, not `salesforce`, and are the one exception to the
rule below: they are built on `all_opportunities_master`, `mason_timesheet_readable` and
`tl_bonus_targets` (Rwanda) or `branch_capacity_targets` (Uganda, Kenya), copying the metric
definitions from `territory_capacity_monthly`. Reason:
the capacity page must tie exactly to the Looker capacity dashboard that territory leads use,
and rebuilding the week windows, the fifteen distinct-mason combinations, the earnings join
and the on-site definition on the Salesforce path is days of work with no change in output.
Revisit once the page has proved itself. Source is in `sql/`. Every threshold sits in the `params`
block at the top of each view. Three rules in those views are easy to get wrong and are there on
purpose: shortfalls are per territory, floored at zero, then summed (never `SUM(min) - SUM(actual)`,
which nets over territories against short ones); every distinct count is computed at its own level,
never added up from territories; and a mason is productive on the same rule as
`productive_masons_monthly` and the TL bonus, which is approved gross pay by end date against
25,000 RWF times the Wednesdays in the window, so week 4 doubles its bar in some months. Every
earnings figure on the capacity page, the chart, earnings per mason and the watch signal, is on that
same bonus basis (approved gross pay by end date). It will not tie to the Looker capacity dashboard's
earnings columns, which use net pay by start date; that is deliberate, one definition per page. The
newest week always reads low until approvals land, and the page prints the approval rate beside it.
Both are computed on read (table functions in `sql/capacity_week.sql` and
`sql/capacity_mason_week.sql`, each with the old view name defined over it), so the page is as
current as the Fivetran sync and nothing has to be rebuilt or scheduled. They were stored tables
for two days in September 2026; with nothing scheduled to rebuild them they were frozen within
days and nothing on screen said so, so the decision (2026-09-17) is fresh over fast. What makes them
tolerable on read is shape, not storage: BigQuery re-inlines a CTE at every reference, so an earlier
version that referenced the scored pipeline five times could not be planned at all. Now each raw
table is scanned at most twice, every fact goes through one per-person aggregate, and the four-week
comparison and focus persistence are window functions in a single pass. Even so the function takes
12 to 16 seconds for one country and month, because it runs about 170 BigQuery stages at 100 to
300 ms each; the country and month filters barely move it. The app caches each country and month
for 15 minutes, so the first visitor waits and everyone else does not, and the page prints "Data as
at" so nobody has to guess. The cold load is accepted for now and will be looked at separately.

**The capacity page is one page for three countries.** Rwanda is territory inside district,
grouped by manager; Uganda and Kenya are branches only, so the territory/district toggle and
the manager chips do not appear for them and Kenya's three branches all show, ranked. The unit
is the only thing that changes: same weeks, same four-builds standard, same productive rule
(25,000 RWF, 62,500 UGX, 2,500 KES a week, copied from `productive_masons_monthly`), same focus
ranking. The CSO requirement is per country AND per unit (Rwanda 5 per territory, Uganda 9 and
Kenya 7 per branch) and lives once, in `country_rules` at the top of the capacity script; the
same figure is the headcount requirement and the divisor behind the per-CSO sales and
collections standards. Never apply one country's figure to another's unit and never compare
CSOs per unit across countries. The four older capacity views Looker reads
(`territory_capacity_monthly`, `_weekly`, `_window`, `salesforce.territory_capacity_app_v1`) still
carry 5.0 hardcoded in up to four places each. Leave them alone: every one filters Rwanda, where the
lookup returns 5.0, so their output would not change, and they are not ours. Revisit only when someone
is changing them for another reason, and take a copy of all four definitions first. Uganda's branch comes
from `location_c.branch_c` on the job's or timesheet's location, Kenya's from its district;
about 1,500 timesheet lines with no country, district or job resolve to no unit and are left
out of every mason count, which the page footnotes. Do not try to allocate them.

**Build new views straight off the raw Salesforce tables** (`salesforce.opportunity`,
`salesforce.location_c`, `salesforce.contact`). Do NOT build on
`raw_data_from_salesforce.all_opportunities_master`. That is a standing instruction from
Vinamra, and it is why the CSO views join Salesforce directly.

Pipeline: Salesforce → Fivetran → BigQuery, syncing every **15 minutes** (it was six hours
until 2026-09-28). That is the freshness ceiling for everything. The app caches for 15
minutes on top (`unstable_cache`, `REVALIDATE = 900` in every data module), matching the
sync. **When you change a query, bump its cache key** (`["cso-months-v7"]` → `v8`) or your
change will not appear for 15 minutes. QuickBooks is unaffected: those figures move only
when a month's books are closed.

---

## 2b. The country workspaces (Rwanda, Uganda, Kenya)

Login lands on a workspace picker. A country box opens the pages for that country
only, at `/<slug>`: Overview, Sales and collections (Overview, Individual CSOs, Customer
journey, which is the Classic toolkit's Journey board itself, `src/components/Dashboard.tsx`
rendered `embedded` with the country fixed and the territory taken from the filter bar; it
reads the board's own cached matrix and summary), Masons (Overview, Individual masons), Quality (Overview, Individual QA),
Territory leads, Capacity planning (People and backlog, and for Rwanda the MARGA
meeting), and Cost to serve (2c-ii). The specs are `docs/capacity-three-pages.md` and
`docs/capacity-consistency-and-marga.md`; the Classic toolkit under `/toolkit` is untouched.

**One shell, one filter bar, one table, one chart.** Every page renders inside
`src/components/ws/WorkspaceShell.tsx`: the menu (the areas of `src/lib/workspaces.ts`;
a group such as Sales and collections expands while one of its sub-pages is open, and
sub-pages reach their page as `?tab=`, so no route changed), the filter bar
(`FilterBar.tsx`: Year, Month or Quarter, the month or quarter, the week chips, Rwanda's
Territories or Branches toggle, the territory (Rwanda) or branch (Uganda, Kenya) dropdown,
the breadcrumb with each level clickable, and the page's exports at the right-hand end,
portalled in through `BarExports`; a page the period does not cut turns the period
controls off and puts its own control in the row, as Cost to serve does with its
currency toggle). The dropdown is the scope: it lists the country's units
(`unitsOf` on the period pages, `getUnitNames` on Quality and Territory leads), choosing
one sets `s=` and so narrows every page and carries across them exactly as the breadcrumb
does, the page, and the
freshness line. Tables are `DataTable` in `src/components/ws/primitives.tsx`: every
column with a `sort` sorts on a header click (again to reverse, a third time back to the
table's own order; a select does the same on phones), the Copy table button writes the
table as tab-separated text, `group` draws a shared header over a run of columns, and
`pageSize` pages a long list. The Focus mark (never "Bottom 5") is the table's `mark`.
Line charts are `TrendChart.tsx` and the five-week sparklines `Sparkline.tsx`; both print a
value at every point and start the y axis at zero unless zero would flatten the line, in
which case the floor may rise to the lowest value minus a fifth of the range. Change a
rule there and every page follows.

**There is no country filter inside the pages and only the selected country is ever
queried.** The period, the scope and Rwanda's level toggle live in the URL
(`p=2026-09&w=13`, `p=2026-Q3`, `s=district:Bugesera`, `sp=<a territory's district>`,
`d=district` or `d=territory`, `tab=csos`, `bucket=paid_not_started` for a journey link),
so they persist across every page and drill-down (`src/lib/period.ts`). On the Overview,
Sales, Masons and Capacity pages the payload holds every week set, so week, scope and
toggle changes are written with `history.replaceState` and need no server round trip; a
change of month or quarter navigates. The Quality and Territory leads pages run every
change through the server (`navigate="all"`), because their queries take one date range,
and their week chips pick a single week (`weekMode="single"`); `leadsPeriodOf` in
`src/lib/leads-period.ts` turns the shared period into that module's `from` and `to` (a
set of several weeks becomes the span from the first to the last). Every navigation runs
inside a React transition: the bar shows the choice at once with a spinner and the page
dims until the figures arrive. Quarter to Month lands on the quarter's latest started
month, which the page already holds, so that switch is instant.

**Capacity planning (`/capacity`) and the MARGA meeting (`/rwanda/marga`).** Both read the
period rows plus the current month's rows (`loadCapacity` in `workspace-page.ts`), because
the five-week sparklines always show the last five complete weeks whatever the period says,
and the current month's payload carries the single weeks of the two months before it. The
requirement and the shortfall (masons and CSOs to hire) are always read from the month's
whole row, never from a week's, so a weekly headcount is never compared with a monthly
establishment. Months of work on the backlog is the journey stock's SQM-E over the place's
own SQM-E completed in the last three whole months (`workspace-journey-v2`), computed in
the query. The MARGA page's region is the `region` column of `capacity_week_v2`: the sales
managers' two-way split (the manager column of `tl_bonus_targets`), each group named by the
compass region most of its territories carry in `bonus_tl_payout_by_month_territory`
("East and North", "South and West"). No table in BigQuery names a construction manager,
so the block heading lists the region's branches instead. Root causes and Action needed
were empty columns for the copy until 2026-09-29; they are filled in the workbook now,
so the tables carry figures only and every name stays on one line.

**Three new SQL objects, defined in `sql/`, and how they are deployed.** The app's
service account can read BigQuery but cannot create objects in any dataset
(`bigquery.tables.create` denied), and the BigQuery connector needed re-authorising
when this was built, so the objects are NOT deployed yet. Until they are, the app runs
the same SQL inline: `scripts/build-sql.mjs` (`npm run build:sql`) extracts each body
from its file, rewrites `p_<name>` to `@<name>` (dates as `CAST(@name AS DATE)`, because
the app passes every parameter as a string) and writes `src/generated/sql.ts`, which is
committed. `src/lib/workspace.ts` wraps each body as a subquery. One source, two ways to
run it, same numbers. To deploy: run the three files through the connector or the
console, set `CAPACITY_USE_FUNCTIONS=1` in Vercel, and the app calls them by name. Edit
the `.sql` file, never the generated one, and rerun `npm run build:sql`.

| Object | What |
|---|---|
| `raw_data_from_salesforce.capacity_week_v2(country, month, from)` | The period grain: one row per level x name x month x week set, the fifteen sets of `capacity_week` PLUS the quarter set (`week_key 'Q'` on the quarter's first month) with its own distinct mason and CSO counts. Adds revenue, cash received, revenue targets, SQM-E sales and collections targets, floors/plasters, on-time builds, first-QA pass rate, productive masons, signed-to-paid, collected today, contracts per CSO and its standard, Rwanda's MARGA region, and the ranking with its movement against the previous period. `from` is the first month computed, so the trend runs January to date in one call. The view `territory_capacity_period_v2` is the function with NULLs. It sits close to BigQuery's planning limit: the levels are fanned out from one scan of `dim` and the spine carries the name's attributes, because every extra reference to a CTE is another inlining |
| `raw_data_from_salesforce.capacity_mason_week_v2(country, level, name, start, end, weeks)` | One row per mason for a place (territory, district, branch or country) and period: builds, SQM-E completed, SQM-E in hand, time needed at the standard weekly rate, on time, earnings, a five-week form guide as an array, and the QA pass rate as the skills proxy (its own `skills` CTE, to be replaced by a training source) |
| `salesforce.cso_cash_daily_app_v1` | Per CSO per day: cash received, contract value completed, commission (Rwanda, provisional), and the weekly cash target where the finance targets carry a revenue target |

`capacity_week` and `capacity_mason_week` (v1) are what the Classic toolkit reads and are
never changed. v2 differs from v1 on purpose: contracts count phase 1 but SQM-E, revenue
and cash count every phase (the CSO views' rule); floor collections use
`COALESCE(date_50pct_paid, date_100pct_paid)` and ignore a collection date before
signing; the four-week comparison, focus ranking and takeaways are not carried.

**Definitions that were decided here, not in the spec, and may need confirming:**

- **Revenue** is `SUM(total_amount)` of contracts completed in the period, by
  `completed_date`, every phase. Never cash. It is live Salesforce revenue, not
  QuickBooks: `total_amount` is `opportunity.total_payment_amount_c` (confirmed by
  Vinamra as the contract value field, 2026-09-29; `total_revenue_c` is what reconciles
  to booked revenue in Kenya and finance may switch, so the field is one line in
  `sql/completed_value_daily.sql` and the same column in the capacity functions), and
  `completed_date` is `date_associated_project_completed_c`, the rule `contracts_built`
  counts on, so revenue and builds always count the same jobs. Since 2026-09-29 the
  **Contractor record type is out of every count** in `capacity_week_v2`,
  `capacity_mason_week_v2` and the cash view's revenue (about 150 jobs, all Rwanda, none
  of them placed in a territory with targets, so no figure moved). The pages label it
  "Revenue" with the line "contract value of builds completed, live from Salesforce";
  the individual masons list and the Masons table carry each mason's and unit's share.
  It will not match QuickBooks month to month (July 2026: Rwanda 38.3m against 36.1m
  booked, Uganda 62.9m against 53.7m, Kenya 429k against 614k); that is timing and is
  not to be reconciled away. One known gap: `capacity_week_v2` fans every level out from
  the units that have targets, so a Rwandan job in a territory with no `tl_bonus_targets`
  row (about 1% of value, 23 jobs in July 2026) is in `completed_value_daily`'s country
  total and in no workspace row. **Cash received** is every instalment in
  `cash_received_c` (`installment_amount_c`), in the month it was paid (`date_paid_c`),
  refunds excluded, and in `capacity_week_v2` the Contractor record type too
  (the CSO cash view still counts its cash). It is read off the opportunity and its location directly, not through
  `all_opportunities_master`, so contracts signed before 2024 count. (It used to be
  `payment_c` rows with status Paid: a payment is a plan, which turns Paid only once
  settled, so that put the whole plan in the month it closed and missed every instalment on
  an open plan. In September 2026 that showed Uganda UGX 52.7M against 71.0M received.)
  `payment_c.amount_c` is a converted figure that is wildly inconsistent month to month
  (Rwanda June 2026 reads 220M, July 250K) and must not be used.
- **Revenue targets** come from `qb_reporting.branch_financial_targets`, metric
  `revenue`, which carries them for all three countries at branch grain (Rwanda:
  district). The spec expected none for Rwanda; the table has them, so Rwanda shows a
  revenue percentage too. Territory rows carry no revenue target.
- **Commission** (Rwanda only) is Salesforce's `x_50_cso_commission_rw_c` and
  `x_100_cso_commission_rw_c`, booked on the day the customer reached that milestone
  (`date_50/100_of_total_payment_is_made_c`). Salesforce holds no commission-paid date.
  Uganda and Kenya have no commission fields. Payroll should confirm the rule.
- **QA pass rate** is the `quality_monthly` rule: first QA-staff check per job and stage
  (compaction, screed, prior paint); a job passes when none was a non-pass; dated by the
  first check. Per unit it is the checks dated in the period; per mason it is the 90
  days to the period's end, because one mason has few builds a month.
- **Masons: the standard weekly rate** for "Time needed" is the unit's next-month SQM-E
  target over its mason requirement, over 4.33 weeks (`weeks_per_month` in the function's
  `params`). Provisional; the page footnotes the rate.
- **Quarter headcount requirement** (`min_masons`) is the monthly requirement averaged
  over the quarter's targeted weeks; targets are a quarter of each month's, summed.
- **"Waiting on materials"** on the journey tab is the Collected, materials unknown
  bucket: the Salesforce tick is not set.

The period rows for a country and month are cached gzipped for 15 minutes
(`workspace-rows-v6`, bump when the query changes), like the capacity page, and the cron
(`/api/capacity/warm`, every 12 minutes) also keeps the current month and the two before it
warm for each country. A cold month takes 15 to 20 seconds. The payload for Rwanda is a few MB of JSON
(all levels, fifteen sets, every whole month since January, every quarter); floats are
rounded in the query and the manager level is dropped to keep it down.

**Dev-server quirk under Node 24:** a cold render that waits 15 seconds or more
sometimes dies in `next dev` with `TypeError: ArrayBuffer is not detachable and could
not be cloned` ("failed to pipe response"), and the browser gets the loading shell
only. Reloading, once the entry is cached, works, and the production server (`next
build && next start`) renders the same pages cold without it. It is not the data: every
value in the payload is a plain string, number or boolean.

## 2c. The CEO dashboard (`/ceo`)

The fifth box on the home page, cross-country, so it sits beside the workspaces
rather than inside one. Spec: `docs/ceo-dashboard.md`, plus three changes asked for on
2026-09-28 (a flat monthly earnings bar, cost to serve in USD, less text) and two more the same day (cost to serve at country level against the loaded country budget, and a readability pass: taller charts, full-width row headings, labels that never overlap). Nine line
charts, three metrics by three countries, January to the current month of the year in
the URL (`?y=2025`; 2026 by default, the first year with targets), actual solid and
budget dashed, one legend, a value at every point, the y axis pinned at zero, the month
in progress drawn hollow and starred. Under the SQM-E row, one table of paint SQM-E.
Every chart has Copy table; the page has Download CSV and Copy for Google Sheets. The
definitions and the country notes (Rwanda RBF, Uganda FX and unattributed spend, Kenya's
scale) sit behind the "How these are calculated" link under the title; the only chart
footnote is "Books not yet closed" where it applies.

**Three settled views, read as they are** (`src/lib/ceo.ts`); nothing is recomputed
from raw tables, and the page has no product CASE of its own:

| Metric | Source | Rule |
|---|---|---|
| SQM-E built | `raw_data_from_salesforce.company_kpi_monthly` | `sqme_built` (floor + plaster, weighted, by completion month; paint excluded by design) against `sqme_target`; `paint_sqme` feeds the table |
| Average mason earnings | `raw_data_from_salesforce.productive_masons_monthly` | `avg_pay` (gross approved pay per mason paid, by timesheet end date) against a flat monthly bar set in the query: 100,000 RWF, 250,000 UGX, 10,000 KES. The view's `threshold` column (the weekly bar times the month's Wednesdays) is deliberately not used, on the CEO's instruction; if the bonus rule changes, change the `bars` CTE in `ceo.ts` |
| Cost to serve, country level | `qb_reporting.country_financials`, `qb_reporting.country_financial_targets`, `qb_reporting.fx_rates_monthly` | `ABS(cts_country)` for months with `books_closed = 1` only, the figure Looker shows (Rwanda January 7.0 USD). The budget is `(revenue - cogs - district_expense - country_expense) / sqme` over the country targets loaded from the VG workbook by `sql/country_financial_targets.sql`, numerators and denominators summed per country and month, never averaged. Both divided by the month's `rate_per_usd` from `fx_rates_monthly`, the way the view derives `cts_country_usd`, and drawn on one shared dollar axis so the three countries compare side by side. Global overheads are in neither line. The targets and the rates both stop at December 2026; a later month shows no budget line until both are extended |

`country_financials` is a view over the QuickBooks tables and takes 20 to 30 seconds,
so the year is one cache entry (`ceo-data-v4`, 15 minutes, bump when a query changes)
built from a fixed source string like the capacity entries, and the warm cron
(`/api/capacity/warm`) keeps the current year warm. The page's `maxDuration` is 120 s
for a cold year.

Two checks made when this was built (2026-09-28), worth repeating if a source changes:
every column name in the spec matched the live schema, and the product split inside
`company_kpi_monthly` (its own `simplified_product_interest`, from
`company_opportunity_long`) matched the company CASE on every 2026 completion except two
Uganda repair jobs (17 SQM-E) classed as Floor and fifty Uganda ceiling-plaster jobs
classed as Other, which carry no SQM-E. Not fixed here; the spec says to report it.

`TrendChart` gained the options this page needed and every other chart ignores:
`dashed` on a series, `partial` (a hollow point), `legend={false}`, `floor="zero"`,
`yLabel`, `axisFormat` (short ticks beside full point labels), `compact` (the phone
width on every screen with a taller plot, for a chart in a grid column), `toolbar` and
`note`. Two rules changed for every chart: labels are measured boxes that never
overlap (a label moves below its dot, then a line further out, when it would touch a
neighbour or a line; the first, last, highest and lowest of a series are always
printed and the rest are dropped when nothing fits), and a money or count axis has at
most four gridlines at round steps (`niceAxis`, exported for a page that wants one axis
across several charts). On a phone the month labels shrink to their initial.

## 2c-ii. Cost to serve (`/<country>/cts`)

Spec: `docs/cts-page-and-revenue.md`, item 1. One page in each workspace, same code:
three scorecards (the latest closed month, year to date, against budget), the country
line against its budget, and the branches as a shaded table, worst first, with a
branch's own line opened under it on a click. **The numbers are Looker's and are not
reopened**: the country layer is `qb_reporting.country_financials.cts_country` against
the budget derived from `country_financial_targets` (the CEO dashboard's row, Rwanda
January 7.0, July 5.0, year to date 5.3 in USD), the branch layer is
`branch_financials.cost_to_serve` against `cost_to_serve_target`, both read as they are
in `src/lib/cts.ts`. The branch figure is a genuinely lower number (district costs only,
before country overheads) and every heading says so. Year to date is the closed months'
spend over their SQM-E, each month at its own rate, never an average of months (the
average would read 5.4). The currency toggle in the filter bar (USD by default, the
country's currency beside it) picks the USD or the local column of the same rows; USD is
the local figure over the month's `rate_per_usd` from `fx_rates_monthly`, the budget
rate, which keeps currency movement out of the chart. Only closed months are drawn and
the open ones are named under the chart; a month with no rate shows no point. The page
has no period controls (`periodControls={false}` on the shell); the branch dropdown is
the scope at Rwanda's district level (`unitLevel="district"`), so a branch chosen here
is the same branch on the other pages.

Both views are computed over the QuickBooks transaction tables and take about 30
seconds each, so the year for all three countries is one cache entry (`cts-data-v1`,
15 minutes, the CEO dashboard's cache so the two pages never disagree) that the warm
cron keeps fresh; the page's `maxDuration` is 120 s for a cold read. The fix is to
materialise both views daily (`sql/qb_financials_tables.sql`: the tables from the
deployed bodies, the view names kept over them, a daily schedule for the two CREATE
TABLE statements). It needs rights the app's service account does not have and was not
deployed on 2026-09-29.

## 2d. The product classification and scored SQM-E

**One classification, `sql/product_class.sql`.** The company's canonical rule
(docs/journey-filters-products.md, item 4) over `COALESCE(product_interest_c,
new_product_interest_c)`, old field first; Repair before Paint before Plaster before Floor,
so "Ceiling plaster_Interior" is Plaster (scored) and "Plaster_Paint" is Paint (not scored).
It is written as a scalar function for deployment; until the service account (or someone
with rights, through the connector) creates it, `scripts/build-sql.mjs` expands every call
to it into the CASE when it generates `src/generated/sql.ts`, and `productClass(expr)` in
`src/lib/product-class.ts` hands the same CASE to the queries written in TypeScript. Nothing
else in the repo classifies product: `capacity_week_v2`, `capacity_mason_week_v2`,
`customer_journey_app_v2` (in `sql/`), `territory.ts`, `quality-scorecards.ts` and the mason
scheduler all go through it. The deployed CSO and collections views already carried the
identical CASE (Repair branch included, checked again 2026-09-29: no contract moves);
`cso_performance_app_v1` and `cso_headcount_app_v1` now have files in `sql/` that call
`product_class` instead, waiting for the connector like the rest. The `all_opportunities_master.simplified_product_interest` column that the
capacity and territory queries used before agreed with the rule on every 2026 contract with
SQM-E (the only differences were null products called Other instead of Unknown, Full House
against House, and seven repair jobs with no area), so switching to it moved nothing; what
moved the numbers is the next paragraph. Not ours and not changed: `company_kpi_monthly`
(the CEO page; its split from `company_opportunity_long` differs from the rule on two
Uganda repair jobs and puts ceiling plaster in Other, checked 2026-09-28) and the Classic
`territory_capacity_app_v1` and `capacity_week` v1.

**Scored SQM-E is Floor plus Plaster only** (item 5). Every `sqme_*` column of
`capacity_week_v2`, and `sqme_completed` and `sqme_in_hand` of `capacity_mason_week_v2`,
count Floor and Plaster (ceiling plaster inside it) and nothing else; paint is carried
beside them as `paint_sold`, `paint_sqme_sold`, `paint_collected`, `paint_sqme_collected`,
`paint_built`, `paint_sqme_built`, and Repair, House, Other and Unknown are in neither.
Contract counts are unchanged (every product but House). On the pages: tables get one
narrow right-hand column headed Paint (`Paint` in primitives, SQM-E with contracts small
underneath), scorecards one muted line ("plus 107 SQM-E paint", `paintNote`), charts
nothing. Rwanda's paint is near zero; Uganda's is about 1,100 to 1,300 SQM-E a month sold
and built, so its scored figures dropped by that much on 2026-09-28.

**The Journey board's SQM-E is different and was left alone.** `customer_journey_app_v2`
weights `raw_sqm` at 1.0 for a floor and 0.333 for everything else, paint and repairs
included, exactly as its footnote says, so its SQM-E is not the scored figure. It is also
deployed, so its file in `sql/` (now on `product_class`) waits for the connector; until then
the live view classifies as before.

## 3. Landmines. Every one of these cost real debugging time

**`contact.termination_date_c` is garbage. Never use it.** It is populated for staff who are
Active and still selling, sometimes dated *before* their own hire date. Using it once zeroed
out 61 CSO-months that all had real activity. Use `employee_status_c` instead.

**A null milestone date does not mean unpaid.** The 50%/100% payment date fields are badly
under-stamped. Testing `collected_date IS NULL` reported 47,053 pending follow-ups; the
correct test (paid-to-threshold OR milestone date OR construction progressed) gives 6,164.
Always use the rich test, and cross-check against the Collections module.

**Never sum per-territory headcount to get a district.** A CSO can cover two territories, so
summing counts one human twice. This is exactly why the capacity planning dashboard reports
Bugesera as 10 CSOs when 9 people worked there. `cso_headcount_app_v1` counts distinct people
separately at territory, district and country level. Use it.

**Floor collections need `COALESCE(d50, d100)`.** If a customer pays 100% but the 50% date was
never stamped, a naive `IF(Floor, d50, d100)` returns null and the CSO loses the credit
entirely. That affected 68 CSOs, 24% of the roster.

**Some contracts are dated in the future**, and some payments are dated *before* the sale
(contracts re-signed without clearing old payment dates, worst case −1,002 days). Both are
guarded in `cso_performance_app_v1`. Keep the guards.

**The journey view distrusts impossible dates.** In `customer_journey_app_v2` a date in the
future never counts, and payment or start dates from before signing never count (about 5% of
first timesheets and 2% of down-payment dates are dated before the contract). A completion
date that falls before signing or before any start signal is not corrected, only flagged in
`cleanup_reason`. That affects 6% of 2024 and 3% of 2025 completions, none in 2026. A final
evaluation *after* completion is normal (a third of Rwanda floors) and is not an error.

**Uganda branch comes from `location_c.branch_c`**, Salesforce's own field, not from a
hardcoded district list. A hardcoded list drifts and leaks districts as fake branches.

**SQM-E is not square metres.** It is raw m² × weight: Floor 1.0, Plaster and Paint 0.333.
The journey board reads it from the view as well: `customer_journey_app_v2` carries `raw_sqm`
(Salesforce's `total_square_meters_c`) and `sqme` (raw × 1.0 when `product_family = 'floor'`,
× 0.333 for everything else, including the few rows with no product recorded, so an unknown
can never inflate a total). Weight it in the view, never in the app.

**Phase 1 is not "first product for a customer".** It is the original contract for a job;
phase 2+ are follow-on contracts adding area to it. Contract counts use phase 1 only (one job
= one build); SQM-E counts every phase, because the SQM-E targets are set on all phases.
In Uganda and Kenya about 45% of contracts are follow-on phases, each priced, paid and
collected on its own, so since 2026-09-17 their CSO productivity is scored in SQM-E only
(branch SQM-E target x 1.3 / establishment for sales, x 1.0 for collections). The pages show
contracts (every phase, `*_all` columns) and jobs (phase 1) beside it as volume, so the
numbers reconcile with Salesforce. Rwanda (about 10% phases) is unchanged.

**Targets are the month's own, everywhere.** September activity is compared to
September's target: the country workspaces (`capacity_week_v2`, `capacity_mason_week_v2`,
`cso_cash_daily_app_v1`), Territory Leads (reading `tl_bonus_targets` /
`branch_capacity_targets` directly) and the Classic toolkit (`capacity_week`, and the CSO
views `cso_performance_app_v1`, `cso_performance_ugke_app_v1`, `cso_branch_ugke_app_v1`,
now kept in `sql/`). It used to be *next* month's target. One exception, in
`cso_performance_app_v1` only (2026-09-30): a month with no targets at all is judged
against the next month's when that month has targets, so December 2025 reads January
2026's; it is per month, not per territory, so Nyagatare C before September 2026 still
has none. The Classic objects are read by name; all six files were run in BigQuery on
2026-09-30 (`capacity_week`, `capacity_mason_week`, `territory_capacity_app_v1` and the
three CSO views), so the deployed objects match `sql/` except that the deployed CSO view
carries its own product CASE in place of the `product_class` call.

**Nyagatare has three territories but targets for two.** `tl_bonus_targets` carries
Nyagatare A and B (identical every month) and no Nyagatare C. On the regional manager's
instruction (2026-09-29), from September 2026 the district target (the official A + B) is
shared B one half, A one quarter, C one quarter, so district and country totals stay
official (Rwanda 52,124 SQM-E, Nyagatare 2,997 in September 2026). Before September 2026
A and B keep their rows and C shows no target. C's builds, sales and cash count in the
district and country actuals in every month. The rule lives in the `tl_targets` CTE of the
four capacity SQL files, the same subquery in `cso_performance_app_v1` and
`territory_capacity_app_v1`, and `TARGETS_RW` in `src/lib/territory.ts`; change it in all
seven. Kamonyi C has no targets and stays out.

**Full House is left out of cash received**, as it is out of every other figure.

**Uganda and Kenya payment gates differ from Rwanda:** floor 50%, plaster 75%
(`seventyfive_payment_made_c`), paint 100%. Only floor and plaster are scored there, because
the branch targets are set on them; paint has no target and is shown as volume only.

**Plaster and paint are different products, never "wall" in the UI.**
`opportunity.product_interest_c` is one string shaped `Family_Variant | Sale type`, e.g.
`Plaster_Interior | DirectSale`. The families are floor, plaster, paint, ceiling plaster
(Uganda only), repair and house, and `customer_journey_app_v2.product_family` carries them.
The old `track` column (floor / wall / repair) stays, because the build steps really do split
that way: a floor is compacted and screeded, a wall is plastered. Use `track` for build logic
and `product_family` for anything a person reads or filters on.

**A donated or zero-value contract counts as PAID** (`is_free` in the view): there is nothing
to collect, so it must not sit in "Signed, not collected" or show as "started before paying".
Test both `total_payment_amount_c <= 0` and a `DonateDiscount` product, because some donated
contracts still carry a value. Only for signed contracts: a promised lead also has no value,
and it is not collected.

**The capacity page is kept warm by a cron.** `/api/capacity/warm` (protected by `CRON_SECRET`,
scheduled in `vercel.json` every 12 minutes, inside the 15-minute cache) reads the same `unstable_cache` entries the page reads,
for every country and every month the page offers, four at a time, so no visitor is the first to run
the ten-second capacity function. It runs no query of its own: a fresh entry costs nothing, a stale or
missing one computes. Two tiers decide what fresh means (`capacityTier` in `src/lib/capacity.ts`): the
last three months keep the 15-minute cache, older months refresh once a day. Same query, same numbers.
Set `CRON_SECRET` in Vercel production or the route answers 503; its JSON says which months were
skipped, refreshed or failed. Two things in `src/lib/capacity.ts` make the cache work and must stay:
the cached value is the month's data gzipped (a full Rwanda month is 2.4 MB as JSON and Next refuses to
cache anything over 2 MB, which silently left every visit to a complete month cold), and the
`unstable_cache` callback is built from a fixed source string, because Next keys entries on the
callback's text and the page and the cron route are minified into different bundles, so a normal
function gave them different keys. The page's week calendar is TypeScript
(`src/lib/capacity-calendar.ts`), not a query; `scripts/capacity-calendar-check.mjs` proves it matches
the SQL it replaced. `BQ_LOG=1` makes `src/lib/bigquery.ts` print one line per query with BigQuery's
timing, slot-ms and cache flag.

**Rwanda's branch is its district.** `all_opportunities_master.branch` equals `location_district`
on every Rwandan job, 21 names to 21 names, so the capacity page's Branch filter reads the
`district` level rows and its Territory filter the level below. Uganda and Kenya have branches and
nothing under them. The page's organisation filters cascade down that hierarchy (manager, branch,
territory) and every level is read from its own row, never added up. The deep dive's mason roster
has two windows, both ending at the last week selected and rolling across month ends: the form
guide and Approved pay always cover four weeks, so a mason's recent record reads the same however
the picker is set, while Builds and Target cover only the weeks selected, so one week selected is
one week of builds against a target of 1.

**Country pages filter in the query, never in the browser.** The home page is the workspace
picker; a country opens `/<slug>` and its pages live under it, so `/rwanda/quality` says in the URL
which country is on screen and an unknown slug 404s before anything is read. The Classic Frontline
Toolkit keeps every older page under `/toolkit`, unchanged, covering all countries together.
`Country.name` in `src/lib/workspaces.ts` is a typed union, so a country cannot reach a query as a
bare string, and `/api/quality/rows` accepts only those names and a fixed set of cuts. Quality reads
the company's own cleaned evaluation table, `raw_data_from_salesforce.all_qa_evaluations_clean`: a
decision of Pass is a pass, "Not Ready for Evaluation" is a wasted visit rather than a fail, and
every other decision (Repair minor issues, Redo, Repair Masking, Repair VX, Intervention is needed,
Red line house) is rework. Uganda's rows carry the branch as "Jinja Branch" and some districts as
"<district>-TBD"; the suffix is stripped so branch names match every other page. Quality and Territory
Leads take their window from the shared filter bar (`src/lib/period.ts`), turned into the date range
their queries take by `leadsPeriodOf` in `src/lib/leads-period.ts` on the server, so a page and its
drill-downs always read the same one.

**The journey board's pending cards are not app_bucket.** "Started, not varnished" is one
column of the funnel (it stays in the territory grid) but as a card it is replaced by four:
pending prior paint, compaction, screed, and varnish or paint movement. Those read the
Territory Leads waiting-for rule (`getWaitingByUnit` in `src/lib/territory.ts`, the same
`WAITING_FOR` the Territory Leads page uses, on the QA evaluation records), so the two pages
count the same houses. Clicking one opens a drawer (`PendingDrawer.tsx`) with two sides that
are different sets on purpose: Territory lead is the houses waiting (`/api/journey/pending`
with `role=tl`, through `getTerritoryBuilds` with an empty territory for the whole country;
rows with no territory or branch are left out, as the card leaves them out). QA officer is the
open QA tasks (`role=qa`, `src/lib/journey-pending.ts`, on `QA Tasks Only`): open, status Not
Started or In Progress (Not Ready for Evaluation is left out), every age. It loads all three
types (compaction, screed, prior paint) and a Type filter starts on the card's own. The note
under it counts tasks on a house already evaluated at that step BY QA (a district or
construction evaluation does not count, by the department on `qa_evals_all`) or no longer
live. The stock movement card has no QA task, so its drawer has no role tabs. The cards are
numbered 1 to 8 and snake on wide screens (1 to 4 on top, 8 back at bottom left); the backlog
and Completed cards, when shown, sit in their own rows above and below.

**`src/app/api/_diag/...` will never route.** The App Router treats `_`-prefixed folders as
private. Cost 15 minutes once.

---

## 4. Auth has a deliberate workaround in it

`src/auth.ts` contains a `[customFetch]` on the Google provider that deletes
`authorization_response_iss_parameter_supported` from Google's OIDC discovery document.

**Do not remove it without testing a real login.** Google advertises RFC 9207 support but does
not return an `iss` parameter on the callback, so `oauth4webapi` rejects every single login
with `OAUTH_INVALID_RESPONSE`. This took the whole company off the app for a day. Auth.js
reports every callback failure as the generic "Configuration" error page, which tells you
nothing, so the `logger.error` hook is there to surface the real cause in Vercel logs.

Debug recipe if login breaks again: POST `/api/auth/signin/google` with a CSRF token, then GET
`/api/auth/callback/google?code=BOGUS` with the returned cookies, and read the thrown error.

---

## 5. House style

- **No em dashes anywhere in the UI.** Vinamra's standing rule.
- Plain professional language. Not "crushing it", not consultant-speak.
- Colours come from CSS tokens in `globals.css` (`--accent`, `--good`, `--warning`,
  `--critical`, `--text-primary` …). Never hardcode a hex except the validated chart colours:
  `#ee7203` sales, `#2f6f9f` collections, `#1baf7a` builds, and on the UG & KE product mix
  `#4a3aa7` floor, `#e87ba4` plaster (paint is neutral grey). Validate any new series colour
  with the dataviz palette checker before using it.
- **Mobile is a first-class target.** Field staff use phones. Wide tables are
  `hidden md:block print:block` with a stacked card list `md:hidden` beside them. Never rely on
  horizontal scrolling. Filters are `w-full min-h-11` on phones.
- Charts: an SVG viewBox scales its text down with the drawing, so a laptop-sized chart renders
  ~5px labels on a phone. Use the `useNarrow()` hook to switch geometry.
- **The menu is two levels** (`src/lib/nav.ts`): a section is a heading, and a module with
  several views sits in a group that expands (the four CSO pages are two country groups).
  Labels inside a group can be short because the group names the country. `hidden: true`
  parks a finished page without deleting its route or its line; the mason scheduler is
  parked that way.
- **Every wait shows a spinner.** `Spinner.tsx` is the single loading signal:
  `(app)/loading.tsx` covers page navigation, the sidebar spins the link that was clicked
  until the new page arrives, and in-page fetches swap their text for it. Every page reads
  BigQuery on demand and takes seconds, so silence reads as broken.
- Fix things everywhere in one pass, not just the case that was reported.

---

## 6. Known open items

- **Nothing persists.** The mason board's drag-and-drop and any allocation edits are lost on
  refresh. A write layer (Supabase) is the next big piece.
- Uganda & Kenya: which roles are ranked (CSO, Sales Agent, Sales Rep, blank position) is
  tentative, and establishment is a flat 9 per branch (UG) / 7 (KE) in the view.
- `raw_data_from_salesforce.bonus_metrics_by_branch` (not ours) misses "Ceiling plaster"
  products, so Uganda's bonus SQM-E built is understated from July 2026.
- A CSO who neither sold nor collected has no row at all, so genuinely idle staff are invisible.
  Needs a payroll roster to fix.
- Open policy questions for the business, not bugs: whether repair work earns CSO credit
  (154 contracts in 2026 get none), whether `d50` really means "half paid" (it equals `d100` on
  the same day for 50% of floors), and Kamonyi C has no targets set so its CSOs are unscored.
