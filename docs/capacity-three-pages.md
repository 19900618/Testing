# Capacity planning: Overview, Sales and collections, Masons

Build these three pages inside the Frontline app. A colleague is building Quality and
Team leads, so leave those alone beyond keeping their nav entries.

**Visual reference:** https://claude.ai/artifact/A4Vs2UehavgxjQJWwUKUto
That mockup is the agreed shell, layout, tone and colour. Copy it. Everything below is
either a change to it or a detail it does not show.

Read `AGENTS.md` and `docs/HANDOVER.md` first. Their rules apply in full: logic in
BigQuery views, the app only reads columns; no em dashes in UI copy; colours from CSS
tokens; mobile is a hard requirement; bump cache keys when a query changes.

---

## 1. Where this sits

Login lands on a workspace picker with four boxes: **Rwanda**, **Uganda**, **Kenya**,
**Classic frontline toolkit**. The classic toolkit keeps everything that exists today,
untouched.

Picking a country opens these pages **for that country only**.

- **There is no country filter inside the pages.** Remove it.
- **Only query the selected country.** Every view read gets `WHERE country = @country`
  pushed down. Do not load three countries and filter in the app.
- Rwanda has territories inside districts, so it keeps the Territories / Branches
  toggle. Uganda and Kenya have branches only, so the toggle is hidden for them.

---

## 2. The period control

This replaces the simple month and week chips in the mockup. It sits in the top bar on
every page and drives everything below it.

```
Period   [ Month ▾ September 2026 ]   [ W1 ][ W2 ][ W3 ][ W4 ]   ( all weeks selected )
         [ Quarter ▾ Q3 2026 ]
```

- Two modes, **Month** and **Quarter**, chosen from one control.
- **Month** mode: a dropdown of months from January 2026 to the current month, plus four
  week chips. Any combination of weeks can be on, from one to all four. All four is the
  default and means the whole month.
- **Quarter** mode: a dropdown of Q1 to the current quarter. No week chips.
- Weeks are the existing calendar windows: days 1 to 7, 8 to 14, 15 to 21, and 22 to
  month end. Do not change this.
- The choice persists across all three pages and across drill-downs.

**The quarter grain needs work in SQL.** Flows can be summed across the three months, but
distinct counts cannot: a mason or CSO working in two months of a quarter is one person.
Add a quarter grain to `territory_capacity_week_v1` with its own distinct counts, the
same way the fifteen week combinations are already precomputed. Do not sum months in the
app.

---

## 3. Data, and the definitions that change

Everything already exists. Do not invent new logic where a view has it.

| What | Where |
|---|---|
| Territory and branch flows, targets, masons, CSOs | `raw_data_from_salesforce.territory_capacity_week_v1` |
| Mason week detail, productive threshold | `raw_data_from_salesforce.territory_mason_week_v1` |
| CSO performance, standing, follow-ups | `salesforce.cso_performance_app_v1`, `cso_pending_app_v1`, `cso_headcount_app_v1` |
| Collections backlog and payment gates | `salesforce.collections_app_v1` |
| Customer journey stages | `salesforce.customer_journey_app_v1` |
| Timesheets | `raw_data_from_salesforce.mason_timesheet_readable` |
| Targets | `tl_bonus_targets` (Rwanda), `branch_capacity_targets` (Uganda, Kenya) |

### 3a. Revenue is changing. This is the important one.

Revenue is **not** cash collected. Revenue is the **total contract value of the builds
completed inside the selected period**.

```sql
revenue = SUM(total_amount) for opportunities whose completion date falls in the period
```

Use the same completion definition the capacity view already uses for `contracts_built`,
so revenue and builds always agree on which jobs count. Local currency, no USD.

Keep **cash collected** as a separate figure. The CSO page needs both, because one of the
requests is "cash received compared to revenue". Never label cash as revenue again.

### 3b. SQM-E on sales and collections

The mockup shows contracts only. Every sales and collections figure now needs SQM-E
beside it, against its own target.

```
sqme_sold_target      = sqme_target * 1.3
sqme_collected_target = sqme_target
```

That matches the existing contract rule, where the sales target is the build target times
1.3 and the collections target equals the build target.

### 3c. Targets to carry

`sqme_target`, `build_target` (contracts), `sales_target` (contracts and SQM-E),
`collections_target` (contracts and SQM-E), `min_productive_masons`, `min_csos`
(Rwanda 5 per territory, Uganda 9 per branch, Kenya 7 per branch),
`min_build_productivity` of 4 builds per mason per month.

---

## 4. Page 1, Overview

### Scorecards

Four, in this order. Each shows the percentage large, then the achieved-of-target figure,
then what is left, exactly as the mockup does. What changes is that sales, collections
and revenue now carry SQM-E too.

**1. Built**
```
55%
10,496 of 19,037 SQM-E
8,541 SQM-E to go
404 of 779 builds · 152 floors, 252 plasters
```

**2. Sold**
```
42%
430 of 1,013 contracts · 8,900 of 21,200 SQM-E
583 contracts and 12,300 SQM-E to go
```

**3. Collected**
```
48%
372 of 779 contracts · 7,400 of 16,300 SQM-E
407 contracts and 8,900 SQM-E to go
35 collected today
```

**4. Revenue**
```
RWF 41.2M
Contract value of builds completed in this period
RWF 18.4M of cash received in the same period
```
If a revenue target exists for the country, show the percentage and what is left in the
usual shape. Uganda has cash targets in the budget workbook; Rwanda does not.

### Trend

Directly under the scorecards, above the table, as now. **January to the current month**,
extending automatically as months pass. Monthly points only, whatever the period control
says. Three lines: built, sold, collected, against a 100% target line.

### The table

Columns: **Ranking** · Territory or Branch · Built SQM-E · Builds · Sold · Collected ·
Revenue · Masons · Passed QA · **Movement**.

- The first column is headed `Ranking`, not `#`. 1 is best, ranked on SQM-E built against
  target.
- Every percentage keeps the achieved-of-target line underneath.
- **Movement** is the change in ranking against the previous period of the same length:
  `▲ 4`, `▼ 2`, or a dash when unchanged or when there is no previous period. Green up,
  clay down. Compute it in SQL, not in the app.
- Sorted worst first. Bottom five marked, as now.
- Tapping a name drills in. Tapping a number opens that page for that row.

### A ranking chart

Requested in the metrics tab. Under the table, a horizontal bar chart of every branch on
SQM-E built against target, best at the top, with the target line at 100%. One colour, no
legend. It is the same data as the table, for people who read a picture faster.

### Bottom boxes

Keep the two boxes, wording as in the mockup.

---

## 5. Page 2, Sales and collections

Three sub-pages under one nav entry, as tabs at the top of the page: **Overview**,
**Individual CSOs**, **Customer journey**. The period and the territory or branch scope
carry across all three.

### 5a. Overview

As the mockup, with SQM-E added everywhere:

Scorecards: Sold (contracts and SQM-E), Collected (contracts and SQM-E), Revenue with
cash received beneath it, Still to collect.

Table by territory or branch: Sold, SQM-E sold, Collected, SQM-E collected, Signed to
paid, Revenue, Cash received, Still to collect, CSOs against requirement. Bottom five on
the average of sales and collections.

Trend, January to current month, sold and collected against target.

### 5b. Individual CSOs

Model this on the existing RW individual CSO page, which already works. Same controls,
same standing chips, same five-month pill guide. Build it inside this workspace reading
the same views, do not rebuild the logic.

**Controls:** period from the top bar, District, Territory, Sort by, Current staff only,
and a search box. If a territory or branch is already selected on the Overview page, this
page opens filtered to it. The user can widen back out to the whole country from here.

**Standing chips with counts:** Everyone · Top performer · Above average · Below average ·
Needs support.

**Columns:**

| Column | Detail |
|---|---|
| CSO | name, territory, rank within territory |
| Standing | the chip, plus tags: No sales this month, Declining, N stale follow-ups |
| Sales this month | `1 of 15`, percentage, progress bar, SQM-E underneath |
| Collections this month | same shape, SQM-E underneath |
| Money collected | **new.** For the chosen day, the week against the weekly target, and the month |
| Commission | **new, and flagged red in the metrics tab.** Per day and month to date |
| Cash received vs revenue | **new.** Cash in against contract value completed |
| Open follow-ups | count, value owed, how many over a year old |
| At target | `4 of 6 months` |
| % of target, last 5 months | five pills, current outlined |

**A day picker.** The metrics tab asks for money collected on any single day, including
today. Put a date selector beside the money columns, defaulting to today. This needs a
daily grain: payments by CSO by day. Add it to the CSO view rather than querying raw
payments from the app.

Selecting a row opens that CSO's full history, as the existing page does.

### 5c. Customer journey

Keep our four buckets. Take the detail and the list treatment from the existing journey
board, which is the best thing in the app today.

**Each bucket shows:**
```
Sold, not paid
109          3,741 SQM-E
RWF 4.2M owed · 6 have paid nothing
median 41 days waiting
[ green | amber | orange | clay time-in-stage bar ]
```
with the legend underneath: `≤30 days · 31 to 60 · 61 to 90 · over 90`.

The four buckets: **Sold, not paid** · **Paid, build not started** · **Build in progress** ·
**Finished this period**. On "Build in progress", show how many are over the late
threshold in clay, as the journey board does with `12 over 30d`. On "Paid, not started",
show how many are waiting on materials, which was asked for in red in the metrics tab.

**Tapping a bucket loads its list.** Card per customer, as the journey board: name, days
in stage as a coloured chip, percentage paid, SQM-E, the CSO or mason, and a **Call**
button that dials the number. Longest wait first.

**Also carry over from the journey board:** the search box across name, phone and CSO, and
the three export buttons, Copy for Google Sheets, Download CSV, Download Excel with a tab
per bucket. Use the shared `ExportButtons` component.

Add the explainer lines the journey board has, in the same muted style: what SQM-E means,
and what counts as started. People trust the numbers more when the rule is written down.

---

## 6. Page 3, Masons

Two sub-pages as tabs: **Overview** and **Individual masons**.

### 6a. Overview

As the mockup. Scorecards: Built, Masons working and assigned against requirement, To
hire, Builds per mason against target with late builds and on-time percentage.

Table by territory or branch: Built SQM-E, Working, Assigned, To hire, Builds per mason,
On time, Waiting per mason, Earning enough.

Trend, January to current month, builds per mason against the target of 4.

### 6b. Individual masons

The same idea as Individual CSOs. Opens filtered to whatever territory or branch is
selected, and can widen to the whole country. A territory, a branch or everything.

**Columns:**

| Column | Detail |
|---|---|
| Mason | name, territory |
| Status | Working, or Assigned not started |
| Builds | completed in the period |
| **SQM-E completed** | **new, flagged blue in the metrics tab** |
| **SQM-E in hand** | **new.** The SQM-E of jobs assigned and not finished |
| **Time needed** | **new.** SQM-E in hand ÷ the standard weekly rate, shown in weeks |
| On time | finished within the threshold, of their builds |
| Earned | approved pay in the period |
| Productive, last 5 weeks | five pills against the weekly bar, current outlined |
| **QA pass rate** | **new.** The mason's first-check pass rate, as the skills proxy |

**The standard weekly rate**, for Time needed:
```
monthly SQM-E per mason = sqme_target / min_productive_masons
weekly rate             = monthly rate / 4.33
time needed in weeks    = SQM-E in hand / weekly rate
```
This derives from targets already in the table, so nothing new has to be entered.

**Provisional.** The field teams may use a different rate. Put the weekly rate in one
named constant at the top of the view so changing it is a one-line edit, and show the
rate in the column footnote: "Standard is N SQM-E a week for one mason".

**Mason skills and training.** The metrics tab asks for masons trained and improving
skills. There are no training records in Salesforce, so build the QA pass rate column now
as the skills measure, and leave a greyed "Masons trained, coming later" tile that says
what it is waiting on.

**Provisional.** Training records may turn out to live outside Salesforce. Keep the
skills column behind a single function so a real training source can replace the QA proxy
without touching the page.

---

## 7. Design rules

Copy the mockup. Where it is silent, copy `CsoOverview.tsx` and the individual CSO page.

- Four scorecards across the top, then the trend, then the table, then the two boxes.
- Every percentage carries its achieved-of-target figure underneath.
- One idea per element. Two type sizes per card. Space, not borders.
- Status is a word plus a colour plus a shape, never colour alone.
- Series colours: sales `#ee7203`, collections `#2f6f9f`, builds charcoal, QA violet.
- Green, amber and clay are for performance against target only, never as category colours.
- Tables become stacked cards below `md`. No horizontal scrolling, ever.
- Plain language. No em dashes. No instructions aimed at the reader.
- Every page carries the freshness line: when Salesforce last synced, and the 30-minute
  cache, as the journey board already shows it.

---

## 8. Do not

- Do not touch the Quality or Team leads pages. A colleague is building those.
- Do not touch the Classic frontline toolkit.
- Do not recompute metrics in React. If a number is wrong, fix the view.
- Do not load more than one country.
- Do not sum distinct counts across months, weeks or territories.
- Do not label cash collected as revenue.

---

## 9. Acceptance

- `npx tsc --noEmit` silent.
- Period control: month with any combination of the four weeks, and quarter. Numbers
  change correctly, including distinct mason and CSO counts at quarter grain.
- Revenue equals the contract value of builds completed in the period, and reconciles to
  the same set of builds the Built scorecard counts.
- SQM-E appears on sold, collected and their targets everywhere.
- The trend runs January to the current month on every page.
- Ranking column is headed Ranking, and Movement matches the change against the previous
  period.
- Individual CSOs opens filtered when a territory is already selected, and can widen to
  the country.
- Every journey bucket opens a list with a working Call button and the three exports.
- Individual masons shows SQM-E completed, SQM-E in hand, time needed and QA pass rate.
- Usable at 390px on all three pages and all sub-pages.

---

## 10. Order of work

1. The view changes: quarter grain, SQM-E targets, revenue on completion, daily CSO
   collections, ranking movement, mason SQM-E and QA pass rate. Show me the SQL and the
   numbers before any page work.
2. Period control and the removal of the country filter.
3. Overview.
4. Sales and collections, all three sub-pages.
5. Masons, both sub-pages.

Stop after step 1 and show the numbers.
