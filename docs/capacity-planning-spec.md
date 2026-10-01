# Capacity planning page — build spec

Build a new page in the Frontline app at `/capacity`. Do not modify any existing
page, component or view. Add one line to `src/lib/nav.ts` and create a new route
folder. Everything else is new files.

Read `AGENTS.md` and `docs/HANDOVER.md` first. The rules there apply in full:
thin reader, no em dashes in UI copy, colours from CSS tokens, mobile is a hard
requirement, bump cache keys when a query changes.

---

## 1. Who this is for and what it replaces

Two managers, Jadon and Ephrem, each run about 20 Rwandan territories. Today they
sit on a call with the analytics team once a week, pull mason counts and earnings
for the last four or five weeks, and pick four or five territories each to focus
on. Those become their priorities until the numbers recover.

This page replaces that call. A manager opens it and sees which of their
territories need attention this week and what to do in each. Everything else on
the page is evidence for that answer.

The test for every design decision: **can a territory lead open this on a phone and
know what to do in under ten seconds.**

---

## 2. Data

### Decision to confirm before building

All the weekly logic already exists in `raw_data_from_salesforce.territory_capacity_monthly`
(week columns, mason earnings, masons on site) and
`raw_data_from_salesforce.territory_capacity_weekly`. The app's standing rule is to
build views on raw `salesforce.*` tables instead.

**Proposal:** build one new view on the curated layer for this page, and record the
exception in `docs/HANDOVER.md`. Reason: this page must reconcile exactly with the
Looker capacity dashboard that territory leads already use, and rebuilding the week
windows, the fifteen distinct-mason combinations, the earnings join and the on-site
definition on the Salesforce path is several days of work with no change in output.
Revisit when the page has proved itself.

### The view to create

`raw_data_from_salesforce.territory_capacity_week_v1`

One row per **territory x week**, continuous across month boundaries. Week windows
are days 1-7, 8-14, 15-21, 22 to month end of each calendar month. Not Saturday to
Friday: those straddle month ends and stop weekly figures tying back to the monthly
target.

Columns:

| Column | Meaning |
|---|---|
| `territory`, `district`, `manager` | from `tl_bonus_targets` |
| `month`, `week_no`, `week_start`, `week_end`, `week_label` | the window |
| `is_complete_week` | false if `week_end >= CURRENT_DATE` |
| `contracts_sold`, `contracts_collected`, `contracts_built`, `sqme_built` | flows in the window |
| `masons_on_timesheet` | distinct masons with a timesheet starting in the window |
| `masons_onsite` | distinct masons with a live job as at `week_end` |
| `masons_built` | distinct masons who completed a build in the window |
| `mason_earnings` | sum of `net_payment` in the window |
| `earnings_per_mason` | `mason_earnings / masons_on_timesheet` |
| `csos_active` | distinct CSOs who sold or collected in the window |
| `build_target_week`, `sqme_target_week` | 25% of the monthly target |
| `min_masons`, `min_csos` | establishment levels, not scaled by week |
| `pct_of_build_target`, `pct_of_sqme_target` | actual over the weekly target |
| `build_coll_ratio` | `contracts_built / contracts_collected` |
| `collected_not_built` | contracts past the payment gate with no completion, as at `week_end` |

Source the metric definitions from `territory_capacity_monthly` so the two agree.
SQM-E is Floor x1.0, Plaster and Paint x0.333, never raw square metres.

### Focus flags, computed in SQL not in the app

Same view, four more columns. This is business logic and belongs in the view.

| Column | Rule |
|---|---|
| `trig_masons` | masons on timesheet fell 20% or more, last 4 complete weeks vs the 4 before |
| `trig_earnings` | earnings per mason fell 20% or more, same comparison |
| `trig_build` | `pct_of_build_target` below 70% over the last 4 weeks AND lower than the 4 before |
| `trigger_count` | how many of the three fired |
| `is_focus` | entered focus when `trigger_count >= 1`, stays until two consecutive complete weeks with `trigger_count = 0` |
| `focus_weeks` | consecutive weeks in focus, 0 if not in focus |
| `is_new_focus` | `focus_weeks = 1` |
| `constraint_type` | BUILD MORE if `build_coll_ratio < 0.85`, SELL MORE if `> 1.15`, otherwise BALANCED |
| `do_first` | the single action, wording below |

**Thresholds are proposals.** 20%, 70%, four weeks, two weeks to recover. Make them
easy to change in one place at the top of the view.

`do_first` wording, reusing the logic already in `territory_capacity_monthly`:

- BUILD MORE and masons below 40% of `min_masons` -> "Hire more masons"
- BUILD MORE and masons at or above `min_masons` -> "Support masons to build more"
- BUILD MORE otherwise -> "Hire more masons"
- SELL MORE and collections lagging sales -> "Follow up on payments for signed contracts"
- SELL MORE otherwise -> "Support CSOs to sell more"
- BALANCED -> whichever of building or selling is further behind

No imperatives aimed at the reader beyond these short action labels, and no em dashes.

---

## 3. The page

`src/app/(app)/capacity/page.tsx` is a server component with
`export const dynamic = "force-dynamic"`. It fetches and passes plain props to a
`"use client"` board component that owns all filter state. Same pattern as
`src/app/(app)/cso/page.tsx` and `CsoOverview.tsx`.

### Controls

Country (Rwanda only at launch), manager, month, week. Manager options come from
the `manager` column, never hardcoded. Week is a multi-select of the four windows
in the selected month, defaulting to the last complete week.

### Band 1. The answer

One sentence above everything else, in plain type:

> 4 of your 22 territories need attention this week. 2 are new.

### Band 2. Focus cards

Up to four cards per manager, ranked by `trigger_count` then by severity. If a
manager has fewer than four triggered, show fewer. Do not pad the list.

Each card carries:

- Territory name, district beneath it
- A small pill: "New this week" or "On focus 3 weeks"
- The constraint in plain words, and the `do_first` action line
- **% of build target** as a vertical fill bar. This is the cylinder idea: a tall
  thin outline filled to the percentage, so 15% reads as nearly empty at a glance
- **Masons on timesheet**, current number plus a four-week sparkline
- **Earnings per mason**, current number plus a four-week sparkline
- Both sparklines show direction, which is what triggered the card

Tapping a card opens the deep dive.

### Band 3. The table

All 42 territories, or 21 districts with a toggle. This is the evidence layer, not
the landing screen, so it sits below the cards.

Columns: Territory or District, Main gap, % built, Masons on timesheet, Masons on
site, Masons short, Build productivity, CSOs, CSOs short, Sold, Collected, Builds
to collections ratio.

Sorted by % built ascending so the weakest row is first. Conditional fill on % built
only. On phones this becomes a stacked card list, `hidden md:block print:block` plus
`md:hidden`, never horizontal scroll.

### Band 4. Deep dive, on tap

Opens inline beneath the table, expanding in place. Not a modal, not a floating
panel. The CSO individual page already moved from a floating panel to an inline
expanding row for this reason.

Contents:

1. **Two trends**, current week plus the previous four, crossing month boundaries:
   masons who completed a build, and mason earnings. Same chart idiom as the CSO
   longitudinal chart, using `useNarrow()` so labels stay readable on a phone.
2. **Collected but not built** for that territory, as a single figure. This is the
   evidence for whether Build more or Sell more is the right diagnosis.
3. **Mason roster** for the selected month. One row per mason, with a five-pill form
   guide across the last five weeks, showing the actual percentage in each pill.
   Green at or above 100% of the weekly productive threshold, amber 80 to 99, red
   below 80. Threshold is 25,000 RWF per mason per week in Rwanda. Reuse the pill
   component and thresholds from the CSO individual page rather than rebuilding.

---

## 4. House style

Copy the look from the existing pages. Do not invent a theme.

- Cards are `rounded-lg border p-4` with `background: var(--surface)` and
  `borderColor: var(--border)`
- Colours come from CSS variables through inline `style={{}}`, layout from Tailwind
  classes. The only hardcoded hexes permitted are the two chart series colours
  already in use
- Stat tile idiom: small secondary label, `text-3xl font-semibold` value, optional
  3x1px status rule, `text-xs` muted hint
- Charts are hand-rolled SVG, no chart library
- Every page is printable: `#print-area` visible, `.no-print` on controls
- Inputs `w-full min-h-11` on phones, `sm:w-auto` above
- Comments above each component say why, not what

## 5. Do not

- Do not touch any existing page, component, lib file or view
- Do not build on `raw_data_from_salesforce.all_opportunities_master`
- Do not derive stage, product, target or threshold logic in the app
- Do not use HTML5 drag and drop anywhere
- Do not use em dashes in UI copy
- Do not hardcode manager names, region names or territory lists
- Do not show three different mason counts on the landing screen. One on the cards,
  all three in the deep dive with a one-line definition each

## 6. Acceptance checks

Before saying it is done:

- `npx tsc --noEmit` is silent
- The weekly figures sum back to the monthly figures in
  `territory_capacity_monthly` for August 2026: 1,498 builds, 42 territories
- Rwanda August masons on timesheet reads 550 for the full month, 355 for week 1,
  462 for weeks 1 and 2 combined. Distinct counts never add up, so weeks 1 and 2 is
  462 and not 715
- The current week is visibly marked incomplete and is excluded from trend
  comparisons
- Every band is usable at 390px wide with no horizontal scroll
- The focus list is stable: running the page two days running does not change which
  territories are listed unless a complete week has closed

## 7. Sequence

Build in this order and stop after each for review.

1. The view, with the trigger and focus columns. Show the SQL and the output for
   August and September 2026 before deploying it.
2. The page shell, controls, and the sentence at the top.
3. Focus cards.
4. The table.
5. The deep dive.

Do not build ahead of the review. Propose and stop.
