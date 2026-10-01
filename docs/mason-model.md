# Capacity page — mason headcount model, final

One change, applied everywhere on the page. The three mason columns must add up to
the month's requirement, and every piece of copy that describes them must say so.

Read this whole file before changing anything. Do not touch any page outside
`/capacity`.

---

## 1. The model

```
Working  +  Assigned  +  To hire  =  the month's requirement
```

| Field | Definition |
|---|---|
| `masons_working` | distinct masons with at least one timesheet starting in the selected weeks |
| `masons_assigned` | distinct masons with a live job at the end of the last selected week and **no** timesheet anywhere in the selection. Exclusive of Working. |
| `masons_to_hire` | `GREATEST(min_productive_masons - (working + assigned), 0)`, computed **per territory** then summed |
| requirement | `min_productive_masons` from `tl_bonus_targets`, which is `build_target / 4` |

### What is wrong today

`masons_to_hire` is `GREATEST(min_productive_masons - masons_working, 0)`. It ignores
`masons_assigned`, which is displayed in the column immediately beside it.

Bugesera district, 1 to 14 September 2026: the page shows 12 to hire. The correct
figure is 6.

### Fold the two working segments into one

Anything currently split as "completing builds" and "working, no build yet" becomes a
single `Working` column. The split only carries meaning over a full month and does not
belong in the table. Remove it from the table and from the scorecard.

### Reconciliation to check against

Bugesera, 1 to 14 September 2026:

| | Working | Assigned | To hire | Requirement |
|---|---|---|---|---|
| Bugesera A | 7 | 3 | 5 | 14.9 |
| Bugesera B | 11 | 3 | 1 | 14.9 |
| **District** | **18** | **6** | **6** | **29.8** |

District: 18 + 6 + 6 = 30, against a requirement of 29.75. The row foots.

### Two rules that point in opposite directions. Keep both.

**District and country mason counts are distinct people at that level.** Never summed
from territories, because a mason working two territories is one person.

**To hire is always summed from territory shortfalls.** Never recomputed on district
or country totals, because that nets territories that are over against territories
that are short.

Note that where a territory is above requirement, To hire floors at zero, so the three
columns can sum to more than the requirement. That is intended. Say so in the table
note.

---

## 2. Build productivity shows the target, not the observed average

The subline currently reads `usual 2`, `usual 1.1` and similar, derived from actuals.

Replace it with **`target 4`** everywhere: every territory, every district, the country
row, the scorecard and the deep dive. Four builds per mason per month is the company
standard and it is what `min_productive_masons` is derived from, so the column and the
requirement now agree.

Remove `usual_builds_per_mason` from anything displayed. Keep the column in the view if
other logic reads it.

Expect almost every row to read badly on this column. Rwanda is running about 1.1
against a target of 4. That is accurate and it is the point.

---

## 3. Every surface that must change

Do not stop at the table. Sweep all of these and list back what you changed.

**The table, both levels**
- Working, Assigned, To hire columns as defined above
- the subnote above the columns, which currently explains To hire against Working only
- Build productivity subline to `target 4`

**The scorecards**
- `4 · Masons working` card: the big number is `Working`, and the subline states the
  full model rather than only the shortfall
- the red `N to hire across N territories` line must use the corrected figure
- remove any reference to completing builds versus not

**The summary sentence at the top of the page**
- currently reads along the lines of "N masons working, N more assigned to a job but
  not on a timesheet, and N to hire across N territories"
- the To hire figure in it must be the corrected one

**The territory deep dive**
- the Working, Assigned and To hire tiles and their descriptions
- the To hire tile currently says "Against the N masons this territory needs for the
  month". Keep that phrasing, it is good, but the number changes.

**The district deep dive**
- same tiles, plus the "N of N territories are short" line

**Cards and takeaways**
- any diagnosis or takeaway sentence that mentions hiring
- a card should only say hiring is the constraint when `to_hire` is the larger gap.
  Compute `productivity_gap = GREATEST(requirement - builds / 4, 0)` and compare.
  Bugesera B: headcount gap 1, productivity gap 11.9, so the card says the masons in
  place are building 1.1 against a target of 4, not "hire 1".

**The page footnote**

**The CSV and Google Sheets export**
- column headers and values follow the same model

---

## 4. Copy to use

Table subnote:

> Working plus Assigned plus To hire equals the month's requirement. Working is anyone
> on a timesheet in the selected weeks. Assigned is anyone with a live job and no
> timesheet in those weeks. To hire is each territory's own shortfall after both, added
> up, never netted against territories that are over. Where a territory is above its
> requirement, To hire is zero, so the three columns can add to more than the
> requirement. District mason counts are distinct people across the district, not the
> sum of the territories.

Scorecard subline:

> 18 working, 6 assigned to a job with no timesheet yet, 6 to hire against the month's
> requirement of 30.

No em dashes. Neutral analyst tone. Nothing addressed at the reader as an instruction.

---

## 5. Acceptance

- `npx tsc --noEmit` silent
- Bugesera district, 1 to 14 September 2026: Working 18, Assigned 6, To hire 6,
  requirement 30. The three columns foot.
- Bugesera A: 7, 3, 5. Bugesera B: 11, 3, 1.
- Rwanda country row: To hire is materially lower than before, because Assigned is now
  counted. It was 85 for August on the old logic.
- Build productivity reads `target 4` on every row at every level, with no `usual`
  anywhere on the page.
- No text anywhere on the page describes the old model. List every file and line where
  you changed copy.
