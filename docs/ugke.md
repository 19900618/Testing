# Capacity page — Uganda and Kenya, plus CSO columns

Extend the existing page rather than building a second one. One page, one view, the
country selector already on it. All logic identical to Rwanda: same weeks, same
four-builds standard, same productive-mason rule, same focus ranking.

Read `AGENTS.md` and `docs/HANDOVER.md` first. Do not modify any page outside
`/capacity`.

---

## 1. The unit changes, nothing else does

Rwanda is organised territory inside district. Uganda and Kenya have **branches only**.

| Country | Unit | Count | Grouping |
|---|---|---|---|
| Rwanda | territory | 42 | territory or district toggle, grouped by manager |
| Uganda | branch | 10 | branch only, no toggle, no manager grouping |
| Kenya | branch | 3 | branch only, no toggle, no manager grouping |

When Uganda or Kenya is selected, hide the territory and district toggle and hide the
manager chips. There is no manager column for these countries in any target table.

**Kenya has three branches.** Do not show "the four furthest behind" for a country with
three. Show all three, ranked, and change the heading to "3 branches, furthest behind
target" rather than a fixed four.

---

## 2. Targets

### Build target, contracts per branch per month

These are not in BigQuery yet. They live in the VG budget workbook, sheet
`UG workings` rows 14 to 23 and `KE workings` rows 14 to 16, month columns E onward.

Uganda, contracts per month:

| Branch | Jan | Feb | Mar | Apr | May | Jun | Jul | Aug | Sep | Oct | Nov | Dec |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| Jinja | 15 | 42 | 50 | 55 | 62 | 70 | 75 | 80 | 85 | 95 | 100 | 95 |
| Iganga | 15 | 42 | 50 | 55 | 62 | 70 | 75 | 80 | 85 | 95 | 100 | 95 |
| Mbale | 15 | 42 | 50 | 55 | 62 | 70 | 75 | 80 | 85 | 95 | 100 | 95 |
| Masindi | 15 | 42 | 50 | 55 | 62 | 70 | 75 | 80 | 85 | 95 | 100 | 95 |
| Masaka | 15 | 42 | 50 | 55 | 62 | 70 | 75 | 80 | 85 | 95 | 100 | 95 |
| Ntungamo | 15 | 42 | 50 | 55 | 62 | 70 | 75 | 80 | 85 | 95 | 100 | 95 |
| Soroti | 5 | 12 | 16 | 20 | 22 | 25 | 32 | 35 | 35 | 50 | 45 | 50 |
| Ibanda | 5 | 12 | 16 | 20 | 22 | 25 | 32 | 35 | 35 | 50 | 45 | 50 |
| Mbarara | 5 | 12 | 16 | 20 | 22 | 25 | 32 | 35 | 35 | 50 | 45 | 50 |
| Luweero | 5 | 12 | 16 | 20 | 22 | 25 | 32 | 35 | 35 | 50 | 45 | 50 |
| **Total** | **110** | **300** | **364** | **410** | **460** | **520** | **578** | **620** | **650** | **770** | **780** | **770** |

Kenya, contracts per month:

| Branch | Jan | Feb | Mar | Apr | May | Jun | Jul | Aug | Sep | Oct | Nov | Dec |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| Busia | 5 | 15 | 20 | 20 | 21 | 21 | 25 | 30 | 30 | 40 | 35 | 30 |
| Bungoma | 5 | 15 | 20 | 20 | 21 | 21 | 25 | 25 | 30 | 40 | 35 | 30 |
| Kakamega | 0 | 0 | 20 | 20 | 10 | 10 | 20 | 25 | 25 | 30 | 35 | 30 |
| **Total** | **10** | **30** | **60** | **60** | **52** | **52** | **70** | **80** | **85** | **110** | **105** | **90** |

Sanity check these are contracts and not SQM-E: Uganda January is 110 contracts against
an SQM-E target of 1,633, which is 14.8 SQM-E per contract. The same sheet prices a
floor at 15 SQM-E and plaster at 16.7. Kenya works out at 14.3. They tie.

### SQM-E target

Already in BigQuery: `qb_reporting.branch_financial_targets`, metric `sqme`, by country,
branch and month. Do not re-derive it from the workbook.

### Everything else, derived the same way as Rwanda

```
min_build_productivity = 4 builds per mason per month, all three countries
min_productive_masons  = build_target / 4
sales_target           = build_target * 1.3
collections target     = build_target
```

### Create a targets table

Build `raw_data_from_salesforce.branch_capacity_targets` holding country, branch, month,
build_target, sqme_target, min_productive_masons, min_build_productivity, min_csos. Load
Uganda and Kenya from the tables above joined to the existing SQM-E targets.

Rwanda keeps reading `tl_bonus_targets`. The capacity view reads whichever applies by
country. Do not merge the two tables, Rwanda is territory-grained and these are branch-grained.

---

## 3. CSO requirement, per country

| Country | Unit | CSOs per unit | Country requirement |
|---|---|---|---|
| Rwanda | territory | 5 | 210 |
| Uganda | branch | 9 | 90 |
| Kenya | branch | 7 | 21 |

The unit differs. Rwanda is per territory, Uganda and Kenya per branch. Never apply one
country's figure to another country's unit and never compare CSOs-per-unit across
countries on one chart.

**This number is currently hardcoded as 5.0 in four views**, and in each it appears in up
to four places: `min_csos`, `csos_short`, and as the divisor inside
`min_sales_productivity` and `min_coll_productivity`. The views are
`territory_capacity_monthly`, `territory_capacity_weekly`, `territory_capacity_window`
and `salesforce.territory_capacity_app_v1`, plus the build script behind
`territory_capacity_week_v1_data`.

Replace all of them with the country lookup, defined once at the top of the capacity view
alongside the mason thresholds.

The two productivity divisors matter as much as the headcount. They convert a unit target
into a per-CSO standard. If `min_csos` becomes 9 for Uganda while those divisors stay at
5.0, Uganda's sales and collections productivity is scored against a Rwandan assumption
and nothing looks wrong on screen.

Note for the record: the budget workbook assumes Uganda 10 and Kenya 5, which disagrees
with these. The figures above are the operating standard from the September workshops and
are the ones to use.

---

## 4. Productive-mason thresholds

Already deployed in `raw_data_from_salesforce.productive_masons_monthly`. Copy, do not
re-derive.

```
Rwanda 25,000   Uganda 62,500   Kenya 2,500
```

Per week, local currency. Threshold for any window is the weekly figure times the number
of Wednesdays in that window. Earnings are `SUM(amount_of_payment)` where
`status = 'Approved'`, bucketed by `end_date`.

---

## 5. Mason and CSO data for the new countries

Mason timesheets carry `district` at 100% for both countries, 177 masons in Uganda and 41
in Kenya, approval rates 95% and 98%. Territory is null, which is correct, they do not
have territories.

Uganda's 53 districts map to 10 branches. Use `location_c.branch_c`, Salesforce's own
branch field, not a hardcoded district-to-branch CASE. That is the standing decision in
the data spine and the collections module already moved to it.

Kenya's 3 districts are the 3 branches.

**Known gap, do not chase:** 1,514 timesheet lines across all countries have no country,
district or opportunity, covering 159 masons. They are excluded from every mason count.
Footnote it, do not try to allocate them.

---

## 6. CSO columns on the table

Add two things to the table at every level and for every country.

**A CSOs column** showing the count for that unit, with the shortfall in small muted type
beneath it, exactly like the mason `To hire` cell:

```
7
2 short
```

Shortfall is `GREATEST(min_csos - csos_active, 0)`, computed per unit, floored at zero,
then summed. Never netted against units that are over. Same rule as masons.

**District and country CSO counts are distinct people**, not the sum of territories. A CSO
covering two territories is one person. The CSO module hit this exact problem and solved
it in `cso_headcount_app_v1`. Do the same here.

Show the "N short" subnote at every level including territory. It was removed from
territory rows earlier because the count could only be 0 or 1, but with a CSO shortfall
the number is meaningful at every grain.

---

## 7. Diagnosis must name people versus performance

Do **not** change the focus ranking. Cards stay ranked on SQM-E behind target. A CSO
shortage already shows up there through its effect on sales, collections and builds.
Ranking on an input would surface units that are short on paper but performing fine.

Change the takeaway sentence instead, so it can say the constraint is headcount rather
than output. For each side of the chain compute both gaps and name whichever is larger:

```
cso_headcount_gap   = GREATEST(min_csos - csos_active, 0)
cso_output_gap      = the CSOs you would not need if each hit the per-CSO standard
mason_headcount_gap = GREATEST(min_masons - (working + assigned), 0)
mason_output_gap    = GREATEST(min_masons - builds / 4, 0)
```

Resulting sentences:

| Situation | Sentence |
|---|---|
| Selling behind, CSOs short | Not enough CSOs. 4 against a requirement of 5. |
| Selling behind, CSOs in place | Enough CSOs, each signing fewer contracts than the standard. |
| Building behind, masons short | Not enough masons. 10 against a requirement of 15. |
| Building behind, masons in place | Enough masons, each building 1.1 against a target of 4. |

Plain language, no imperatives at the reader, no em dashes.

---

## 8. Acceptance

- `npx tsc --noEmit` silent
- Country selector switches Rwanda, Uganda, Kenya. Territory toggle and manager chips
  hidden for Uganda and Kenya
- Kenya shows all 3 branches, not a fixed four
- Uganda September build target totals 650 contracts across 10 branches, Kenya 85 across 3
- CSO requirement reads 5, 9 and 7 per unit by country, and the same figure drives the
  productivity divisors
- Productive pills use 25,000, 62,500 and 2,500 by country
- CSOs column shows count with "N short" beneath, at every level and every country
- Country and district CSO counts are distinct people, not summed from units
- No hardcoded 5.0 anywhere in any capacity view
