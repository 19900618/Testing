# Consistency pass, and the two capacity planning pages

Two jobs in one pass.

**Part A** makes the six pages look and behave like one product. Three were built by one
person and three by another, and the differences show.

**Part B and C** add the two capacity planning pages.

Read `AGENTS.md` and `docs/HANDOVER.md` first. Their rules apply throughout: logic in
BigQuery views, the app only reads columns, no em dashes in UI copy, colours from CSS
tokens, mobile is a hard requirement.

Do not change any metric definition in this pass. If a number looks wrong, leave it and
say so.

---

# Part A. Consistency across all six pages

Pages: Overview, Sales and collections, Masons, Quality, Team leads, Capacity planning.

## A1. The filter bar

One row, the same order on every page:

```
[ Year ▾ ]  [ Period ▾ Month | Quarter ]  [ W1 ][ W2 ][ W3 ][ W4 ]  [ Territories | Branches ]  Rwanda / Bugesera / Bugesera A   ·····   [ Copy for Google Sheets ] [ Download CSV ]
```

- **Year** comes from the Quality and Team leads pages, which have it and the others do
  not. Adopt it everywhere. List only years with data, default to the current year. The
  period dropdown then lists months or quarters inside that year.
- **Period** keeps the month and quarter modes and the week chips already built.
- **Level toggle** shows only for Rwanda, and only when nothing is scoped.
- **Breadcrumb** shows the current scope with each level clickable, and a Show all button.
- **Exports** always sit at the right-hand end.
- Same spacing, same control heights, same label style on all six. Take whichever page
  does it best and make the others match it, rather than inventing a third way.

## A2. Type and spacing

One scale across all pages. Page title, section heading, table text, muted label. No page
introduces its own sizes. Cards, borders, radii and padding all come from the existing
tokens. If two pages differ, the one matching the shell wins.

## A3. Charts

**Keep the chart types the other pages introduced.** They are good and they stay. Two
changes, applied to every chart on every page:

- **Data labels at every point**, not just the last one. Series colour, 600 weight, small.
  Where points would collide, nudge vertically rather than dropping labels.
- **Less zoom.** Start the y axis at zero. When every value sits far above zero and zero
  would flatten the line, the floor may rise, but never above the lowest value minus a
  fifth of the range. A two-point move must not look like a cliff.

Both changes go into the shared chart component so no page can drift again.

## A4. Sub-pages live in the sidebar

Quality expands in the sidebar index when you click it, and its sub-pages appear there.
Sales and collections and Masons use tabs at the top of the page instead. Move them to
the sidebar pattern. Routes do not change, only where the links live.

## A5. Every table

- **Sorting.** Click a column header to sort, click again to reverse, with an arrow
  showing the current sort. Every table, every page. Each table keeps its existing
  default sort.
- **Copy table.** A button in the table header that copies the whole table as
  tab-separated text, headers included, for pasting straight into Sheets or Excel. Use
  the existing clipboard helper in `src/lib/export.ts`.

## A6. Wording

Replace **Bottom 5** everywhere. The tag becomes **Focus**, and the heading becomes
**Territories to focus on** or **Branches to focus on**. Same ranking, kinder word.

---

# Part B. Capacity planning, page 1, all three countries

This page is about **people**, not volume. The Overview already covers builds, sales and
collections, so do not repeat that table here.

Default period: **the current month**. The trend tables always show the last five
complete weeks whatever the period says.

## B1. Scorecards

```
Masons working          CSOs working           SQM-E built            SQM-E sold
506 of 536 needed       181 of 210 needed      10,496 of 19,037       8,900 of 21,200
57 to hire              29 to hire             55%                    42%
plus 55 assigned        contracts per CSO 2.4  8,541 SQM-E to go      12,300 SQM-E to go
```

`To hire` is always the sum of each unit's own shortfall, floored at zero, against the
**month's** requirement whatever period is selected. Label it "against the month's
requirement" so nobody reads a week against a monthly establishment.

## B2. The People table

One table, two column groups under a shared header row.

| | Masons | | | | CSOs | | | |
|---|---|---|---|---|---|---|---|---|
| **Branch** | Working | Assigned | To hire | Builds per mason | Active | Required | To hire | Contracts per CSO |

- Rows follow the level toggle. **Default to branches** on this page.
- Builds per mason carries the target of 4 a month, scaled to the period.
- Contracts per CSO carries the per-CSO standard, which is the sales target divided by the
  CSO requirement.
- Mason columns link to the Masons page for that row. CSO columns link to Sales and
  collections for that row. Scope carries across.
- Focus rows marked, ranked on the weaker of the two productivity figures.

## B3. Masons, last five weeks

A table of sparklines, laid out like the focus trend page the team already uses.

| Branch | Masons working | Earnings per mason |
|---|---|---|
| Gisagara | **6** · target 14, 8 short<br>sparkline with dashed target line, value labelled at every point | **23,702 RWF**<br>sparkline, value labelled at every point |

- Five weekly points, oldest left, ending at the last complete week. Week dates under the
  first and last point.
- The current value prints large to the left of each sparkline.
- The mason sparkline carries a **dashed line at the monthly requirement**. The earnings
  sparkline has no target line, because there is not one; the signal is direction and
  steadiness.
- Under the table, one line: a wobbly earnings line usually means uneven work allocation
  rather than a mason problem.

## B4. CSOs, last five weeks

The same shape.

| Branch | CSOs active | Contracts per CSO |
|---|---|---|

Both sparklines carry a dashed line: the CSO requirement, and the per-CSO contract
standard.

## B5. Backlog

Collected but not built, as agreed. Not signed and not collected.

| Branch | SQM-E waiting | Contracts | Oldest job | Months of work |
|---|---|---|---|---|

- **Months of work** is backlog SQM-E divided by that branch's build rate over the last
  three months. It is the column that makes the number mean something.
- Sorted by months of work, longest first.
- Each row links to Sales and collections, customer journey, with the "Paid, build not
  started" bucket already open for that branch.

## B6. Bottom boxes

Keep the two boxes, phrased for people rather than volume: how many are working and how
productive they are, then who to hire and where work is piling up.

---

# Part C. Capacity planning, page 2, Rwanda only

Call the page **MARGA meeting**. It exists to replace the spreadsheet that gets rebuilt
by hand every Monday. Default period: **month to date**.

Four blocks, one per audience. Each block is a heading, a table, and a Copy table button.
Columns match the workbook exactly, in this order, so a paste lands in the same shape the
team already reads.

## C1. Sales and collections

Heading: **Territories to focus on, sales and collections**

| Territory | Manager | Sold | Sales target | Sales % | Collected | Collections target | Collections % | CSOs | CSOs required | Per-CSO output | Root causes | Action needed |

Worst five on the average of sales % and collections %.

## C2. Builds, East and North

Heading: **Territories to focus on, building, East and North**, with the construction
manager's name in small muted type beside it.

| Territory | SQM-E built | SQM-E target | SQM-E % | Builds | Masons working | Masons assigned | Masons required | To hire | Builds per mason | Target per mason | Root causes | Action needed |

Worst five on SQM-E built against target, within the East and North region.

## C3. Builds, South and West

Identical, for the other region.

The region split is the same one the sales managers use. One region field serves both;
only the name shown beside the heading changes.

## C4. Quality

Two tables.

**Branches to focus on, pass rate**

| Branch | QA visits | Passed | Failed | Not ready | Pass rate | Fail rate | Not ready rate | Root causes | Action needed |

**Branches to focus on, agreement with territory leads**

| Branch | Spot checks | Matched | Match rate | Root causes | Action needed |

Both show the pass rate target as a line under the table: **90% in Q3, 95% in Q4**.

## C5. Root causes and Action needed

These two columns are filled by hand in the meeting and cannot be computed. Render them
as empty columns on every block, and include them in the copy, so the paste arrives ready
to annotate. They are easy to drop later if the team decides they only want them on
Quality.

## C6. Five-week trend cards

Under the two build blocks, the focus territories as trend cards, one per territory, two
sparklines each: masons working with the dashed target, and earnings per mason. Same
component as Part B3, card layout rather than table rows.

This is the view the team already uses on the focus trend page, and it answers the
follow-up question every time a territory appears on the list: is it getting better or
worse.

---

# Part D. Do not

- Do not change any metric definition.
- Do not change the chart types the other pages introduced.
- Do not touch the Classic frontline toolkit.
- Do not repeat the Overview table on the capacity pages.
- Do not compare a weekly headcount against a monthly requirement.
- Do not sum distinct counts across weeks, months or units.

---

# Part E. Acceptance

- `npx tsc --noEmit` silent and `npm run build` passes.
- All six pages share one filter bar layout, including the year filter.
- Every chart has data labels at every point and a y axis that starts at or near zero.
- Sales and collections and Masons sub-pages appear in the sidebar, like Quality.
- Every table sorts on every column and has a working Copy table button.
- No page says "Bottom 5".
- Capacity page 1: scorecards, People table, two five-week sparkline tables, backlog. To
  hire always reads against the month's requirement, whatever period is chosen.
- Capacity page 2 appears for Rwanda only, with four blocks whose columns match the
  workbook, blank Root causes and Action needed columns included in the copy, and the QA
  target line.
- Usable at 390px. Sparkline tables become stacked cards on phones.

---

# Part F. Order of work

1. Part A, the consistency pass. It touches every page and is the riskiest, so do it
   first while the pages are otherwise stable.
2. Capacity page 1.
3. Capacity page 2.
4. `npx tsc --noEmit`, `npm run build`, merge to main and push as EarthEnable BI.
