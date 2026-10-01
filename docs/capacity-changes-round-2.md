# Capacity page — review round 2

Changes to `/capacity` after reviewing the first preview. Work through these in
order. Several are corrections to logic that is currently wrong, not preferences.

Read `AGENTS.md` and `docs/HANDOVER.md` first. Their rules apply in full. Do not
modify any page, component or view outside `/capacity` and its own view.

---

## 1. Shortfall must never be netted. This is a bug.

`to hire` is currently computed on totals. That is wrong at every grain above a
single territory, because it nets territories that are over against territories
that are short.

Rwanda, August 2026, 42 territories:

| | Masons |
|---|---|
| Target (`min_masons`) | 536 |
| Actual | 547 |
| Netted | 11 over |
| **Sum of shortfalls only** | **85 short** |
| Sum of surpluses | 96 over |
| Territories short | 21 of 42 |

Half of Rwanda is 85 masons short. Netting hides it completely. You cannot move a
mason from Nyagatare to Nyabihu by subtraction.

**Fix:** compute the gap per territory, floor it at zero, then sum.

```sql
SUM(GREATEST(min_masons - masons_working, 0)) AS masons_to_hire
```

Never `SUM(min_masons) - SUM(masons_working)`.

Apply this to every aggregation: district rows, manager rollups, the country line
at the top of the page. Sweep for any other metric computed on netted totals and
fix those in the same pass.

Rename the column from `Masons short` to **`To hire`**.

---

## 2. Working and Assigned overlap. Make Assigned exclusive.

Rwanda, August 2026:

| | Masons |
|---|---|
| On a timesheet | 527 |
| Has a live job (on site) | 449 |
| **In both** | **398** |
| On timesheet only | 145 |
| On site only | 54 |

These are not nested. Shown side by side as 527 and 449, a reader who adds them
gets 976 people who do not exist.

**Fix:** redefine the second column as *on site AND NOT on timesheet in the same
window*.

| Column | Definition | Rwanda Aug |
|---|---|---|
| `Working` | distinct masons with a timesheet in the window | 527 |
| `Assigned` | distinct masons with a live job but no timesheet in the window | 54 |
| `Total masons` | Working + Assigned | 581 |
| `To hire` | per-territory shortfall, summed, floored at zero | see §1 |

Working plus Assigned now adds up correctly.

**Do not add a "no work lined up" column.** 145 masons worked but have nothing live,
which looks like idle capacity, but we cannot tell an idle mason from one who has
left. There is no employment roster. Put it in the page footnote instead:

> Masons who worked but have no job currently assigned are not shown separately.
> Without an employment roster we cannot tell an idle mason from one who has left.

---

## 3. The mason form guide is scoring the wrong period. This is a bug.

Every pill currently reads 100 to 200%. That is a unit mismatch, not real
performance.

Rwanda masons, August 2026:

| Comparison | Median | % passing |
|---|---|---|
| One week of earnings vs 25,000 | 24,247 | **48%** |
| One month of earnings vs 25,000 | 74,913 | **86%** |

A month is roughly three weeks of threshold, so scoring a month against a weekly
bar makes almost everyone green.

**Fix: use the company's existing rule. Do not invent one.** It is already deployed
in `raw_data_from_salesforce.productive_masons_monthly` and it is the same rule the
TL bonus uses. Copy it exactly:

```sql
-- weekly_threshold: Rwanda 25000, Uganda 62500, Kenya 2500
-- threshold for any window = weekly_threshold * (number of Wednesdays in the window)

earnings = SUM(amount_of_payment)          -- gross, NOT net_payment
  FROM raw_data_from_salesforce.mason_timesheet_readable
  WHERE status = 'Approved' AND NOT is_deleted
  bucketed by DATE_TRUNC(end_date, ...)    -- end_date, NOT start_date

productive = earnings >= weekly_threshold * wednesdays_in_window
pill value = earnings / (weekly_threshold * wednesdays_in_window)
```

Four details that differ from the current implementation and all four matter:
gross not net, `end_date` not `start_date`, `status = 'Approved'` only, and the bar
scales by Wednesdays rather than by calendar days.

Pill colours: green at or above 100%, amber 80 to 99, red below 80. Label the column
**Productive**, which is the company's own term for this.

**Expected result after the fix: roughly half the pills are green.** If almost all
are still green, the period and the bar are still mismatched.

Note for the footnote: weeks 1 to 3 are always exactly seven days and always contain
one Wednesday, so their bar is always 25,000 in Rwanda. Week 4 runs from day 22 to
month end and contains two Wednesdays in four months of 2026 (April, July, September,
December), so its bar doubles in those months. This is correct and matches the bonus
calculation.

> Each week's target scales to the Wednesdays it contains, matching the bonus
> calculation. Week 4 is longer than the others, so in some months its target is
> double.

---

## 4. Focus cards: ranking, contents and layout

### Ranking

Rank by **absolute SQM-E shortfall against target over the last four complete weeks**,
largest first. Take the top four per manager. Remove the trigger-based eligibility
logic entirely: triggers decide nothing about who appears.

Comparisons are always **four-week blocks against the previous four weeks**, never
week against week. Average builds per territory run 3.0 in week 1 and 15.2 in week 4
because of the month-end push, so a week-on-week comparison measures the calendar,
not performance.

### Card contents

```
Gicumbi B                                  Gicumbi
1,192 SQM-E behind over 4 weeks      on focus 3 weeks
                                     was 1,402 behind, now 1,192

Built       ▏░░░░░░░░░░░░░░░    1%
                                 12 of 1,204 SQM-E
Sold        ▓▓▓▓░░░░░░░░░░░░   38%
Collected   ▓▓▓░░░░░░░░░░░░░   29%

Masons      ╲╲__                9 → 6

Customers are signing and paying, but almost nothing is being built
```

- Three horizontal bars using the existing `MiniBar` component. Built, Sold,
  Collected, all against their own targets, all on the same 0 to 100 scale so the
  weak link is visible at a glance.
- **Actual numbers appear under Built only** (`12 of 1,204 SQM-E`, `text-xs` muted).
  Sold and Collected show the percentage alone. Three sets of numbers is clutter.
- One mason sparkline, no axes, first and last values only (`9 → 6`).
- No earnings on the card. Earnings live in the deep dive.
- The recovery line (`was 1,402 behind, now 1,192`) appears from week two on focus.
  It is what makes the page self-serving instead of a prompt to ask for numbers.
- The takeaway sentence at the bottom names whichever part of the chain is furthest
  behind, so cards do not all say the same thing.

### Watch line, below the cards

One sentence naming territories outside the top four whose masons or earnings fell
20% or more over the four-week comparison. Real numbers, no threshold language:

> Also worth watching: Nyabihu A, masons down from 12 to 8.

The 20% rule stays in SQL and never appears in the interface.

---

## 5. Table columns

Remove the CSO counts. The CSO page owns headcount and duplicating it here invites
two different answers to the same question.

Final column set:

| Column | Note |
|---|---|
| Territory or District | toggle |
| Built % | with actual SQM-E beneath in `text-xs` muted |
| Sold % | percentage only |
| Collected % | percentage only |
| Working | masons on timesheet |
| Assigned | on site, not on timesheet |
| To hire | per-territory shortfall, summed |
| Build productivity | builds per mason against standard |
| Builds to collections | ratio |

Sort by Built % ascending. Conditional fill on Built % only. Below `md`, replace the
table with stacked cards. No horizontal scroll at any width.

---

## 6. Language

The audience is field supervisors, not analysts. Every line should be readable
without knowing what a metric is called.

| Replace | With |
|---|---|
| 18 of 42 territories are lagging | Rwanda built 61% of its build target in the last 4 weeks |
| Hire more masons | Fewer masons than this territory needs |
| Support masons to build more | Enough masons, but each is building less than usual |
| Support CSOs to sell more | Not enough new customers signed |
| Follow up on payments for signed contracts | Customers signed but have not paid yet |
| Build productivity 67% | Each mason completed 2 builds. The usual is 3. |

Three rules behind those.

**State the comparison in the same sentence as the number.** Never leave `67%`
standing alone for the reader to work out what it is a percentage of.

**Never convert a unit we do not hold.** SQM-E mixes floor and plaster at different
weights, so it cannot be described as a number of floors. `contracts_built` counts
completed jobs of any product, so it is "builds", not "floors". Leave SQM-E as SQM-E
and simplify the sentence around it instead.

**Diagnose, do not instruct.** The page shows, the manager decides. Section headers
read `Jadon · 22 territories · furthest behind target`, not `Jadon must start with
these four`. Other people read this page too.

No em dashes anywhere, per the house rule.

---

## 7. Deep dive

**Expand in place.** Clicking a row opens the detail directly beneath that row and
clicking again collapses it. It currently opens at the bottom of the table. The CSO
individual page already made this change for the same reason, so match that pattern.

**District level must work too.** The deep dive is currently territory only.

**Distinct counts cannot be summed from territory to district.** A mason working two
territories is one person. The CSO module hit this exact problem and solved it with
`cso_headcount_app_v1`, computing distinct counts separately at each level. Do the
same here: compute mason and CSO counts independently at territory, district and
country grain. Never roll them up by addition.

Deep dive contents:

1. Two trends, current week plus the previous four, crossing month boundaries:
   masons who completed a build, and mason earnings. Use `useNarrow()`.
2. Collected but not built for that territory, as one figure. This is the evidence
   for whether the problem is building or selling.
3. Mason roster for the period, with the five-window Productive pills from §3.

---

## 8. Design constraints

"Not cluttered" needs to be specific or it will not happen.

- **One idea per element.** A card carries one set of bars, one trend, one sentence.
  Anything needing a second chart belongs in the deep dive.
- **Two type sizes per card.** The value, and a muted `text-xs` context line. Nothing
  else competes.
- **Colour carries meaning only.** Orange is brand and the single headline series.
  Green, amber and clay are reserved for performance against target and appear
  nowhere else. A card showing four colours has failed.
- **Space, not borders.** Separate blocks with whitespace. The existing pages do this
  and it is why they read calmly.
- **Sparklines have no axes.** Two end values and the shape between them.
- **One interaction.** Tap a row or card to expand in place, tap again to close.
  Nothing else on the page is clickable.

---

## 9. Acceptance checks

Run these before saying it is done.

- `npx tsc --noEmit` is silent.
- Weekly flow columns sum back to the monthly figures in
  `territory_capacity_monthly`. August 2026 Rwanda: 1,498 builds across 42
  territories.
- Distinct counts do not sum. Weeks 1 and 2 combined give fewer masons than week 1
  plus week 2. If they are equal, the aggregation is wrong.
- August 2026 Rwanda `To hire` reads about 85, not 0 and not 11.
- Working plus Assigned equals total masons, with no double counting.
- Roughly half the Productive pills are green. If nearly all are green, §3 is not
  fixed.
- The current week is visibly marked incomplete and excluded from the four-week
  comparisons.
- Every band is usable at 390px with no horizontal scroll.
- Deep dive opens beneath the clicked row at both territory and district level.

---

## 10. Order of work

1. Fix the two bugs first: netted shortfall (§1) and the productive pill period (§3).
   Show me the corrected numbers before touching the interface.
2. Mason column definitions (§2).
3. Card ranking, layout and copy (§4, §6).
4. Table columns (§5).
5. Deep dive placement and district level (§7).
6. Design pass (§8).

Stop after step 1 and show the numbers. Do not rebuild the interface before the
logic is right.
