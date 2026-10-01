# Capacity page — back to live views

The capacity page reads two stored tables, `territory_capacity_week_v1_data` and
`territory_mason_week_v1_data`, wrapped in one-line views. Nothing rebuilds them, so the
page serves whatever was written the last time the build script ran. Every other module
in the app reads real views and is current with the Fivetran sync.

Convert both back to real views, computed on read, and make them fast enough that the
page loads. No scheduled queries, nothing to rebuild, nothing to go stale.

Read `AGENTS.md` and `docs/HANDOVER.md` first. Do not change any page outside
`/capacity`.

---

## 1. Why they were slow, and what to fix

Materialising was the right fix for the symptom and the wrong fix for the cause. The
views are slow because they do all their expensive work **before** any filter applies:

- four-week and prior-four-week comparisons for six metrics
- focus persistence, which needs window functions ordered across every week
- all of it at three levels, territory, district and country
- across all history, when the page only ever shows a selected month plus four
  trailing weeks

A page request for Rwanda, September, weeks 1 and 2 causes every territory in every
country to be computed for every week since 2024, and then almost all of it is thrown
away.

Fix the shape, not the storage.

---

## 2. Two changes, in this order

### 2a. Put a date floor inside the view

Add a floor to the base CTEs so nothing earlier than 18 months before the current month
is scanned. Apply it as early as possible, in the CTEs that read
`all_opportunities_master` and `mason_timesheet_readable`, not in a later filter.

```sql
DECLARE floor_month DATE DEFAULT DATE_TRUNC(DATE_SUB(CURRENT_DATE(), INTERVAL 18 MONTH), MONTH);
```

Or inline the expression if a view cannot carry a DECLARE.

The page shows a selected month plus four trailing weeks. Eighteen months is generous
and leaves room for the month selector to go back a year.

Measure after this change alone. It may be enough on its own.

### 2b. If still slow, make them table functions

BigQuery supports `CREATE TABLE FUNCTION` with parameters. That lets the country and
month filter apply before the expensive work rather than after.

```sql
CREATE OR REPLACE TABLE FUNCTION
  `earth-enable-main.raw_data_from_salesforce.capacity_week`(
    p_country STRING, p_month DATE)
AS (
  -- same logic, with p_country and p_month pushed into the base CTEs
);
```

Called as:

```sql
SELECT * FROM `earth-enable-main.raw_data_from_salesforce.capacity_week`('Rwanda', DATE '2026-09-01')
```

The app passes the selected country and month. Note the four-week comparison reaches
back before the selected month, so the base CTEs need `p_month` minus about two months,
not `p_month` exactly. Get that boundary right or the trend and the direction badges
break silently at month starts.

If you go this route, `src/lib/capacity.ts` changes from selecting from a view to
calling the function with parameters. Nothing else in the app changes.

---

## 3. What to delete once the views are live

- `territory_capacity_week_v1_data` and `territory_mason_week_v1_data`
- the one-line wrapper views over them
- the scheduling instructions at the bottom of both `sql/` files, which are no longer
  needed

Keep the view names `territory_capacity_week_v1` and `territory_mason_week_v1` if you
stay with views, so the app does not change. If you move to table functions, name them
`capacity_week` and `capacity_mason_week` and update the app.

---

## 4. Do not run the CSO lookup script

`sql/capacity_legacy_views_cso_lookup.sql` rewrites four views that the live Looker
capacity dashboard reads. Every one of them filters `location_country = 'Rwanda'` and
the lookup joins on Rwanda, which returns 5.0. The output does not change.

It also runs four `EXECUTE IMMEDIATE` statements in sequence with no transaction, so a
failed assertion on the third leaves the first two already rewritten with no rollback.

Leave those views alone. The real fix is already in the capacity view, which carries the
country lookup, and that is what the app reads. Revisit only when someone is changing
those views for another reason, and take a copy of all four definitions first.

---

## 5. Show the data freshness on the page regardless

Both scripts already emit `CURRENT_TIMESTAMP() AS built_at`. Once these are real views
that timestamp becomes the query time, which is what you want.

Add a muted line under the page header:

> Data as at 16 Sep, 10:30

Salesforce reaches BigQuery through Fivetran every six hours, so name that too rather
than implying the number is real-time:

> Data as at 16 Sep, 10:30. Salesforce syncs to BigQuery every six hours.

---

## 6. Acceptance

- `npx tsc --noEmit` silent
- `SELECT COUNT(*)` on both views returns in under ten seconds
- The capacity page loads in under three seconds on a cold request
- No table named `*_data` remains, and nothing in `sql/` refers to scheduled queries
- Rwanda August 2026 still reconciles: 1,498 builds across 42 territories
- Bugesera district, 1 to 14 September: Working 18, Assigned 6, To hire 6, requirement 30
- Uganda September build target totals 650 contracts across 10 branches, Kenya 85 across 3
- The four-week comparison still works correctly in the first week of a month, when it
  reaches back into the previous month
- The page shows the data timestamp and names the six-hour sync

Report the query time before and after each of 2a and 2b, so we know whether the date
floor alone was enough.
