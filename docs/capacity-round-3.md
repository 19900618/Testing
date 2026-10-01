# Capacity page — review round 3

Design and correctness pass after the second preview. Most of this is matching the
look of pages that already exist, so **read those first and copy from them rather
than inventing anything**:

- `src/components/CsoOverview.tsx` — weakest-territory cards, the three-bar idiom,
  the table pills
- the Uganda and Kenya CSO overview page — numbered scorecards, coloured top rules,
  the summary box
- `src/components/` individual CSO page — filter chips, standing pills, the
  five-window form guide

If something here conflicts with what those pages do, the existing pages win.

---

## 1. Two bugs first

### 1a. Mason roster is broken

Clicking through to the roster returns:

```
could not run the roster: unrecognized name at [7:11]
```

That is a BigQuery error for a column that does not exist, at line 7 column 11 of
the query. Check every column name in the roster query against
`INFORMATION_SCHEMA.COLUMNS` for the table it reads. Likely candidates are a
renamed mason field or a column that only exists on the monthly view and not the
weekly one.

### 1b. Whole numbers where people are counted

`Masons needed` and `To hire` are showing decimals. People are not fractional.
`Math.round()` both, and sweep for any other headcount field with the same problem.

---

## 2. Scorecard and card styling

### Borders

Every card gets a border, matching the existing idiom:

```
rounded-lg border p-4
style={{ background: 'var(--surface)', borderColor: 'var(--border)' }}
```

The scorecards at the top of the page take the **3px coloured top rule** used on the
UG and KE overview page, with the rule colour matching the metric.

### Bar and rule colours

Stop using orange for everything. Use the series colours already in the codebase:

| Series | Colour |
|---|---|
| Sales | `#ee7203` orange |
| Collections | `#2f6f9f` blue |
| Builds | the dark charcoal already used on `CsoOverview` |

Same three colours everywhere they appear: focus card bars, scorecard top rules,
deep dive charts. A reader should learn the colour once.

### Section numbering

Adopt the `1 · Sales`, `2 · Collections`, `3 · Builds` numbering from the UG and KE
page for the top scorecards. It makes the reading order explicit.

---

## 3. Focus cards

### Remove the bold shortfall line

Delete `1,192 SQM-E behind over 4 weeks` from the card. The bars and the takeaway
already carry the message and the bold line clutters the box. The figure still
drives the ranking, it just does not need to be printed.

### Territory name on one line

Names are wrapping to two lines and pushing cards out of alignment. Reduce the type
size or apply `truncate` with a `title` attribute so the full name is available on
hover. One line, always.

### Align the actual-numbers line

`12 of 1,204 SQM-E` sits at a different vertical position on every card because the
takeaway sentences are different lengths. Give the card a fixed grid so the bars,
the numbers line and the takeaway each occupy a consistent row across all four
cards. They should read as a set, not as four separate boxes.

### Takeaway in colour

The takeaway sentence is the point of the card and currently looks like body text.
Give it the status colour that matches the constraint: clay or orange when something
is behind, muted when the chain is balanced. Match the existing `--warning` and
`--critical` tokens rather than new hexes.

### Mason sparkline label

Show `9 → 6 over 5 weeks`, not `9 → 6`. Without the span a reader assumes it means
last week.

### Focus status as a banner, not floating text

`on focus 4 weeks` and `new this week` are currently loose text. Make them a small
pill in the top right corner of the card, using the standing-pill styling from the
individual CSO page. Colour: muted for `on focus n weeks`, accent for `new`.

---

## 4. Table

### Sorting

Add sort on `Built %`, both directions. Default stays ascending so the weakest row
is first, but a manager should be able to flip it.

If other columns sort cheaply, make them all sortable. If not, `Built %` alone is
enough for now.

---

## 5. Deep dive charts

### Axis labels

Both charts are unlabelled. Add them: masons on one, earnings on the other, with the
week labels on the x axis. Follow the chart idiom in `CsoOverview`, including
`useNarrow()` so the labels stay readable on a phone.

### Compact earnings

Earnings are printing in full. Use compact notation with one decimal:

```
26.5K   1.3M
```

Same treatment anywhere else earnings appear.

---

## 6. Export buttons

The page has no export. Add `Copy for Google Sheets` and `Download CSV` in the same
position as every other page, top right of the header block, using the shared
`ExportButtons` component and `src/lib/export.ts`. Do not write new export code.

Export the territory or district table as displayed, respecting the current filters.

---

## 7. Navigation

Capacity planning becomes its **own section** in `src/lib/nav.ts`, sitting alongside
`CSO performance & collections`, not an item inside another section. One page in it
for now. More will be added.

---

## 8. Design reference, concretely

Things to copy rather than approximate, all present on the pages named at the top:

- Summary sentence in a bordered box above the scorecards, plain prose, stating what
  the period did in one or two sentences
- Big value, then a delta beside it in green or red, then a thin progress bar, then a
  muted line giving the counts behind the percentage
- `Below standard` and similar verdicts in the status colour, inline in the muted line
- Filter chips carrying a coloured dot and a count
- The five-window form guide with the current window outlined
- Muted `text-xs` footnotes at the bottom of a card explaining what is and is not
  included

House rules that still apply: colours through CSS variables in inline `style`,
layout through Tailwind classes, no em dashes, mobile card list below `md`, nothing
clickable except the row or card that expands.

---

## 9. Acceptance

- `npx tsc --noEmit` silent
- Mason roster opens without error at territory and district level
- No decimals on any headcount
- All four focus cards align row for row
- Every territory name on one line
- Sales, collections and builds use their own colour everywhere they appear
- Export buttons present and working
- Capacity appears as its own nav section
- Usable at 390px, no horizontal scroll
