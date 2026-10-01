# Customer journey, filters, sync, and the product classification

Five changes. **Item 4 is the one that matters most.** The others are visible; that one
decides whether the numbers are right.

Two screenshots sit beside this file and are referenced below:

- `docs/img/journey-board-classic.png`
- `docs/img/paint-column-example.png`

Read `AGENTS.md` and `docs/HANDOVER.md` first.

---

## 1. The customer journey on the country pages

See `docs/img/journey-board-classic.png`. That is the Journey board in the Classic
toolkit, at `/toolkit`, and it is what the country workspaces need. Not a reduced
version, not a rebuild.

**Reuse the existing component.** Do not write a second one. If it needs a prop to take
its country from the workspace instead of its own dropdown, add the prop.

What has to come across exactly as it is today:

- The five stage cards: Signed not collected, Collected materials unknown, Collected
  materials available, Started not varnished, Varnished not evaluated
- On each card: the count, the SQM-E beside it, the money or median or "N over 30d" line,
  and the time-in-stage colour bar
- The time-in-stage legend, and the two explainer paragraphs about SQM-E and about what
  counts as Started
- The search box across name, phone and CSO
- The Show backlog and Show completed toggles, with their counts
- The territory grid underneath, with the Jobs and SQM-E toggle, the heat shading, and the
  Total column
- Every link and drill-down, including the ones that carry filters through

**It has to feel part of the toolkit, not bolted on.** Same sidebar treatment, same
filter bar as every other page in the workspace, same page header and freshness line. A
person moving between Overview and Customer journey should not notice a change in
furniture.

The country dropdown that sits on the Classic version comes out. In a country workspace
the country is already chosen.

After wiring it, click every link and toggle and confirm each one behaves as it does in
the Classic version. Copied components usually break on the links that pass state.

---

## 2. Territory and branch filter on every page

Add a dropdown to the standard filter bar on every page: **territory** for Rwanda,
**branch** for Uganda and Kenya. Default is all.

It filters the whole page and carries across pages, the same way the breadcrumb scope
does today. Keep it in the standard filter bar position so every page still looks
identical.

---

## 3. Salesforce now syncs every 15 minutes

The sync was changed from 6 hours to **15 minutes**. Update every piece of text that says
otherwise, on every page, in the sidebar, and in `docs/HANDOVER.md`.

The dashboard cache is 30 minutes, which is now longer than the sync interval, so the
faster sync buys nothing. **Reduce the cache to 15 minutes to match.** Bump the cache
keys. If that causes a load-time problem on any page, tell me rather than putting it back.

QuickBooks is unaffected. Those figures still move only when a month's books are closed,
so leave that wording as it is.

---

## 4. The product classification, used everywhere

This is the company's canonical classification and it is the definition of record. Apply
it to `COALESCE(product_interest_c, new_product_interest_c)`, **old field first**, because
a large number of older floors carry only the legacy value.

**The order of the branches matters.** Repair is tested before paint, paint before
plaster, plaster before floor. Do not reorder it.

```sql
CASE
  WHEN Product_Interest IS NULL THEN "Unknown"
  WHEN CONTAINS_TEXT(LOWER(Product_Interest), "repair")
       OR Product_Interest IN ("Rescreed","Masking","Recompacting","Premium Redo") THEN "Repair"
  WHEN CONTAINS_TEXT(LOWER(Product_Interest), "paint")   THEN "Paint"
  WHEN CONTAINS_TEXT(LOWER(Product_Interest), "plaster") THEN "Plaster"
  WHEN CONTAINS_TEXT(LOWER(Product_Interest), "floor")
       OR Product_Interest IN (
            "Ubudehe 1 Subsidy",
            "Ishema",
            "Cluster",
            "Damarara",
            "Franchise",
            "Free LOMA Full",
            "Free LOMA Partial",
            "Kwigira",
            "Loan contract",
            "LOMA Full Service",
            "LOMA Partial Service",
            "Pro Bono",
            "Subcontract - Free LOMA Full",
            "Subcontract - Free LOMA Partial",
            "Subcontract - LOMA Full",
            "Subcontract - LOMA Partial",
            "Subcontract Institutional - Full LOMA",
            "Subcontract Institutional - Partial LOMA"
       ) THEN "Floor"
  WHEN CONTAINS_TEXT(LOWER(Product_Interest), "house")    THEN "House"
  ELSE "Other"
END
```

**What to do:**

1. Put it in one place, as a SQL UDF or a single shared CTE, so no page can carry its own
   copy.
2. Audit every page and every view the app reads. Anywhere a query classifies product
   with its own `LIKE` test or its own list, replace it with this.
3. Confirm these two, because they are the ones that trip people up:
   - **Ceiling plaster interior** contains "plaster", so it is Plaster and it is scored.
   - **Plaster_Paint** contains "paint", and paint is tested first, so it is Paint and it
     is not scored.

**Numbers will move, and that is accepted.** Report what changed: which files, which
metrics, and roughly how much, so the team can be told before they notice it themselves.

---

## 5. Scored SQM-E is floor plus plaster. Paint shows separately

Every SQM-E figure measured against a target counts **Floor plus Plaster only**, with
ceiling plaster inside Plaster. Paint is never in the scored number, and neither is
Repair, House, Other or Unknown.

Paint still has to be visible, but it gets **very little room**. See
`docs/img/paint-column-example.png`, the branch breakdown on the Uganda and Kenya CSO
overview, which already does this well: one narrow right-hand column, SQM-E as the figure,
contract count and share small underneath.

Apply that idea, adapted to each page rather than copied everywhere:

- **Tables:** one narrow right-hand column headed `Paint`. SQM-E as the figure, contracts
  small underneath.
- **Scorecards:** a single muted line under the main figure, `plus 107 SQM-E paint`. No
  second big number, no extra card.
- **Charts:** paint stays out entirely.

Do not add a paint row, a paint chart, a paint toggle, or a paint filter. If a page has no
natural place for it, leave it off that page rather than making room.

**One thing to check and report, not change.** The Journey board footnote says paint and
repairs count a third inside SQM-E. If its SQM-E really does include them, it now
disagrees with every scored figure elsewhere. Tell me what it actually does before
changing anything, because those numbers are already in use.

---

## Order of work

1. Item 4, the classification. Then check what moved on every page.
2. Item 5, floor plus plaster scored, paint shown small.
3. Item 1, the customer journey.
4. Items 2 and 3, the filter and the sync text.

Then `npx tsc --noEmit`, `npm run build`, merge to main and push as EarthEnable BI.

Report back: every file where you changed a product classification, every number that
moved and by how much, and what the Journey board's SQM-E actually includes.
