-- =============================================================================
-- raw_data_from_salesforce.product_class(product_interest)
--
-- The company's canonical product classification, the definition of record
-- (docs/journey-filters-products.md, item 4). It is applied to
--   COALESCE(product_interest_c, new_product_interest_c)
-- OLD FIELD FIRST, because a large number of older floors carry only the
-- legacy value.
--
-- The order of the branches matters and must not change: Repair is tested
-- before Paint, Paint before Plaster, Plaster before Floor. So
--   "Ceiling plaster_Interior | DirectSale"  contains "plaster"  -> Plaster (scored)
--   "Plaster_Paint | DirectSale"             contains "paint"    -> Paint (not scored)
-- The source document writes CONTAINS_TEXT (Looker); STRPOS > 0 is the same
-- test in BigQuery.
--
-- ONE PLACE. Every query the app runs classifies product through this
-- function and nothing else. The app's own queries cannot call it until it
-- is deployed (the service account cannot create routines), so
-- scripts/build-sql.mjs expands every call to it into the CASE below when it
-- generates src/generated/sql.ts, and src/lib/product-class.ts hands the same
-- CASE to the queries written in TypeScript. Deploy this file first, then the
-- views that call it, through the BigQuery connector or the console.
-- =============================================================================

CREATE OR REPLACE FUNCTION `earth-enable-main.raw_data_from_salesforce.product_class`(product_interest STRING)
RETURNS STRING
AS (
  CASE
    WHEN product_interest IS NULL THEN 'Unknown'
    WHEN STRPOS(LOWER(product_interest), 'repair') > 0
         OR product_interest IN ('Rescreed', 'Masking', 'Recompacting', 'Premium Redo') THEN 'Repair'
    WHEN STRPOS(LOWER(product_interest), 'paint') > 0 THEN 'Paint'
    WHEN STRPOS(LOWER(product_interest), 'plaster') > 0 THEN 'Plaster'
    WHEN STRPOS(LOWER(product_interest), 'floor') > 0
         OR product_interest IN (
              'Ubudehe 1 Subsidy',
              'Ishema',
              'Cluster',
              'Damarara',
              'Franchise',
              'Free LOMA Full',
              'Free LOMA Partial',
              'Kwigira',
              'Loan contract',
              'LOMA Full Service',
              'LOMA Partial Service',
              'Pro Bono',
              'Subcontract - Free LOMA Full',
              'Subcontract - Free LOMA Partial',
              'Subcontract - LOMA Full',
              'Subcontract - LOMA Partial',
              'Subcontract Institutional - Full LOMA',
              'Subcontract Institutional - Partial LOMA'
         ) THEN 'Floor'
    WHEN STRPOS(LOWER(product_interest), 'house') > 0 THEN 'House'
    ELSE 'Other'
  END
);
