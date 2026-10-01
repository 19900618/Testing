CREATE OR REPLACE VIEW `earth-enable-main.salesforce.customer_journey_app_v2`
OPTIONS (description = """Customer journey for the Frontline app (thin reader). v2: collected jobs split on Materials Available; Started = earliest start signal; date guards with impossible dates flagged in cleanup_reason; product_family (floor / plaster / paint / ceiling plaster / repair / house); paint gate 100% in UG and KE; a signed donated contract, or a zero-value contract for a known product, counts as paid (is_free). 2026-09-16 b: contracts saved with no product and no price are NOT free, they are flagged 'no product or price recorded'; loan contracts are not flagged as completed-but-not-fully-paid. 2026-09-18: raw_sqm and sqme (floor 1.0, other 0.333) so the board can show size, not only counts.""")
AS WITH opp_signed AS (
  SELECT id, customer_signed_date_c AS sd FROM `earth-enable-main.salesforce.opportunity` WHERE _fivetran_deleted = FALSE
),
ts AS (
  -- First mason timesheet, ignoring any dated in the future or before the contract was signed.
  SELECT t.opportunity_id, MIN(t.start_date) AS first_ts
  FROM `earth-enable-main.raw_data_from_salesforce.mason_timesheet_readable` t
  LEFT JOIN opp_signed os ON os.id = t.opportunity_id
  WHERE NOT COALESCE(t.is_deleted, FALSE) AND NOT COALESCE(t.fivetran_deleted, FALSE)
    AND t.opportunity_id IS NOT NULL AND t.start_date IS NOT NULL
    AND t.start_date <= CURRENT_DATE() AND (os.sd IS NULL OR t.start_date >= os.sd)
  GROUP BY 1
),
plaster_qa AS (
  -- First plaster evaluation, same guards.
  SELECT q.opportunity_name_c AS opp, MIN(q.date_c) AS first_plaster_eval
  FROM `earth-enable-main.salesforce.quality_assurance_survey_c` q
  JOIN `earth-enable-main.salesforce.record_type` rt ON rt.id = q.record_type_id
  LEFT JOIN opp_signed os ON os.id = q.opportunity_name_c
  WHERE rt.name IN ('Prior Paint Evaluation', 'Mud plaster evaluation', 'Final plaster evaluation')
    AND q.date_c IS NOT NULL AND NOT COALESCE(q.is_deleted, FALSE) AND NOT COALESCE(q._fivetran_deleted, FALSE)
    AND q.date_c <= CURRENT_DATE() AND (os.sd IS NULL OR q.date_c >= os.sd)
  GROUP BY 1
),
base AS (
  SELECT
    o.id AS opportunity_id, o.name AS opportunity_label,
    o.customer_signed_date_c AS signed_date, DATE(o.created_date) AS created_date,
    o.stage_name, o.type_c,
    COALESCE(o.total_cash_paid_c,0) AS cash_paid,
    COALESCE(o.total_payment_amount_c,0) AS total_amount,
    COALESCE(SAFE_DIVIDE(o.total_cash_paid_c, NULLIF(o.total_payment_amount_c,0)),0) AS pct_paid,
    LOWER(COALESCE(o.product_interest_c, o.new_product_interest_c,'')) AS prod,
    `earth-enable-main.raw_data_from_salesforce.product_class`(COALESCE(o.product_interest_c, o.new_product_interest_c)) AS product_class,
    COALESCE(o.total_square_meters_c, 0) AS raw_sqm,
    o.materials_available_c,
    -- DATE GUARDS. A date in the future never counts. Payment and start dates from before
    -- the contract was signed never count either (left over from an earlier contract or mistyped).
    IF(o.date_materials_confirmed_c <= CURRENT_DATE(), o.date_materials_confirmed_c, NULL) AS date_materials_confirmed_c,
    IF(o.dp_date_c <= CURRENT_DATE() AND (o.customer_signed_date_c IS NULL OR o.dp_date_c >= o.customer_signed_date_c),
       o.dp_date_c, NULL) AS dp_date_c,
    IF(o.last_payment_date_c <= CURRENT_DATE() AND (o.customer_signed_date_c IS NULL OR o.last_payment_date_c >= o.customer_signed_date_c),
       o.last_payment_date_c, NULL) AS last_payment_date_c,
    IF(o.date_50_of_total_payment_is_made_c <= CURRENT_DATE() AND (o.customer_signed_date_c IS NULL OR o.date_50_of_total_payment_is_made_c >= o.customer_signed_date_c),
       o.date_50_of_total_payment_is_made_c, NULL) AS d50,
    IF(o.date_100_of_total_payment_is_made_c <= CURRENT_DATE() AND (o.customer_signed_date_c IS NULL OR o.date_100_of_total_payment_is_made_c >= o.customer_signed_date_c),
       o.date_100_of_total_payment_is_made_c, NULL) AS d100,
    o.pre_house_assessment_result_c AS prehouse_res,
    IF(o.pre_house_evaluation_date_c <= CURRENT_DATE(), o.pre_house_evaluation_date_c, NULL) AS prehouse_dt,
    IF(o.insecticide_movement_date_c <= CURRENT_DATE() AND (o.customer_signed_date_c IS NULL OR o.insecticide_movement_date_c >= o.customer_signed_date_c),
       o.insecticide_movement_date_c, NULL) AS insect_mv,
    IF(o.anti_termite_movement_date_c <= CURRENT_DATE() AND (o.customer_signed_date_c IS NULL OR o.anti_termite_movement_date_c >= o.customer_signed_date_c),
       o.anti_termite_movement_date_c, NULL) AS termite_mv,
    o.compaction_evaluation_results_c AS compaction_res,
    IF(o.compaction_evaluation_date_c <= CURRENT_DATE(), o.compaction_evaluation_date_c, NULL) AS compaction_dt,
    o.screed_evaluation_results_c AS screed_res,
    IF(o.max_screed_evaluation_date_c <= CURRENT_DATE(), o.max_screed_evaluation_date_c, NULL) AS screed_dt,
    o.prior_paint_varnish_evaluation_result_c AS priorpaint_res,
    IF(o.varnish_movement_date_c <= CURRENT_DATE(), o.varnish_movement_date_c, NULL) AS varnish_mv,
    IF(o.plaster_paint_movement_date_c <= CURRENT_DATE(), o.plaster_paint_movement_date_c, NULL) AS paint_mv,
    o.final_floor_evaluation_result_c AS final_res,
    IF(o.final_evaluation_date_c <= CURRENT_DATE(), o.final_evaluation_date_c, NULL) AS final_eval_dt,
    IF(o.date_associated_project_completed_c <= CURRENT_DATE(), o.date_associated_project_completed_c, NULL) AS completed_date,
    o.date_associated_project_completed_c AS completed_date_raw,
    o.close_date,
    IF(o.actual_construction_start_date_c <= CURRENT_DATE() AND (o.customer_signed_date_c IS NULL OR o.actual_construction_start_date_c >= o.customer_signed_date_c),
       o.actual_construction_start_date_c, NULL) AS acs,
    T.first_ts, PQ.first_plaster_eval,
    L.country_c AS country,
    CASE
      WHEN L.country_c = 'Uganda' THEN
        COALESCE(NULLIF(TRIM(L.branch_c),''),
        CASE
          WHEN L.district_c IN ('Jinja','Kamuli','Kampala','Mayuge','Buyende','Luuka','Buikwe') THEN 'Jinja'
          WHEN L.district_c IN ('Sironko','Mbale','Qween','Buyaga','Kapchorwa','Bulambuli','Kadama','Tirinyi','Butebo','Budadiri','Budaka','Butaleja','Namisindwa','Manafwa','Bukedea') THEN 'Mbale'
          WHEN L.district_c IN ('Masaka','Bukomansimbi','Kalungu','Mpigi','Sembabule','Rakai','Lwengo','Kyotera') THEN 'Masaka'
          WHEN L.district_c IN ('Masindi','Hoima','Buliisa','Kikuube','Kiryandongo') THEN 'Masindi'
          WHEN L.district_c IN ('Iganga','Bugiri','Namutumba','Kaliro','Bugweri','Namayingo','Tororo','Busia','Kibuku') THEN 'Iganga'
          WHEN L.district_c IN ('Ntungamo','Sheema','Mitoma','Bushenyi','Rukungiri','Rukiga') THEN 'Ntungamo'
          WHEN L.district_c IN ('Luweero','Nakasongola','Nakaseke') THEN 'Luweero'
          WHEN L.district_c IN ('Mbarara','Rwampala','Isingiro','Kiruhuura','Lyantonde','Rwampara') THEN 'Mbarara'
          WHEN L.district_c IN ('Soroti','Serere','Kalaki','Kaberamaido','Amuria','Amuru','Kapelebyong','Katakwi','Ngora','Kumi') THEN 'Soroti'
          WHEN L.district_c IN ('Ibanda','Kamwenge','Kazo','Kitagwenda') THEN 'Ibanda'
          ELSE L.district_c END)
      ELSE L.district_c
    END AS branch,
    L.district_c AS district, S.territory_c AS territory
  FROM `earth-enable-main.salesforce.opportunity` o
  LEFT JOIN `earth-enable-main.salesforce.location_c` L ON o.umudugudu_c = L.id
  LEFT JOIN `earth-enable-main.salesforce.location_c` S ON L.sector_c = S.id
  LEFT JOIN ts T ON T.opportunity_id = o.id
  LEFT JOIN plaster_qa PQ ON PQ.opp = o.id
  WHERE o._fivetran_deleted = FALSE
    AND (o.customer_signed_date_c >= DATE '2024-01-01'
         OR (o.customer_signed_date_c IS NULL AND DATE(o.created_date) >= DATE '2024-01-01'))
),
cls AS (
  SELECT *,
    -- track drives the build steps (a floor is compacted and screeded, a wall is plastered).
    CASE WHEN product_class = 'Repair' THEN 'repair'
         WHEN product_class IN ('Plaster', 'Paint') THEN 'wall' ELSE 'floor' END AS track,
    -- product_family is what the business sells: the company's classification
    -- (product_class(), sql/product_class.sql) in lower case: floor, plaster (ceiling
    -- plaster inside it), paint, repair, house, other, unknown. Use this for anything a
    -- person reads or filters on; use track for build logic.
    LOWER(product_class) AS product_family,
    type_c IN ('Demonstration','Demonstrations Floor') AS is_demo,
    -- Nothing to collect: a signed donation, or a zero-value contract FOR A KNOWN PRODUCT.
    -- A contract saved with no product and no price is unfinished data entry, not a donation.
    (signed_date IS NOT NULL AND (prod LIKE '%donatediscount%' OR prod LIKE '%donate discount%'
      OR (COALESCE(total_amount,0) <= 0 AND prod != ''))) AS is_free,
    -- Payment gate: floor 50%; plaster and ceiling plaster 75% in UG/KE and 100% in RW; paint 100% everywhere.
    CASE WHEN country='Rwanda' THEN 1.00 WHEN prod LIKE 'paint%' THEN 1.00 ELSE 0.75 END AS wall_threshold
  FROM base
),
staged AS (
  SELECT *,
    -- Started = the EARLIEST of every start signal Salesforce holds (already cleaned of future
    -- and pre-signing dates in base).
    (SELECT MIN(d) FROM UNNEST([acs, insect_mv, termite_mv, first_ts, IF(track = 'wall', first_plaster_eval, NULL)]) AS d) AS started_date,
    CASE
      WHEN stage_name='Closed Lost' THEN 'Q'
      WHEN track='repair' AND completed_date IS NOT NULL AND completed_date >= created_date THEN 'N'
      WHEN track='repair' THEN 'M'
      WHEN completed_date IS NOT NULL THEN 'L'
      WHEN COALESCE(final_res,'')='Pass' THEN 'P'
      WHEN varnish_mv IS NOT NULL OR paint_mv IS NOT NULL THEN 'K'
      WHEN (track='floor' AND COALESCE(screed_res,'')='Pass') OR (track='wall' AND COALESCE(priorpaint_res,'')='Pass') THEN 'J'
      WHEN track='floor' AND COALESCE(compaction_res,'')='Pass' AND screed_res IN ('Failed','Redo','Repair minor issues') THEN 'I'
      WHEN track='floor' AND COALESCE(compaction_res,'')='Pass' THEN 'H'
      WHEN track='wall' AND priorpaint_res IN ('Failed','Redo','Repair minor issues') THEN 'I'
      WHEN track='wall' AND priorpaint_res IS NOT NULL THEN 'H'
      WHEN track='floor' AND (insect_mv IS NOT NULL OR termite_mv IS NOT NULL) AND compaction_res IN ('Failed','Redo','Repair minor issues') THEN 'G'
      WHEN track='floor' AND (insect_mv IS NOT NULL OR termite_mv IS NOT NULL) THEN 'F'
      WHEN acs IS NOT NULL THEN 'F'
      -- Masons have logged time, or QA has evaluated the plaster: the build has started.
      WHEN first_ts IS NOT NULL OR (track='wall' AND first_plaster_eval IS NOT NULL) THEN 'F'
      -- Collected, not started: split on Salesforce's Materials Available tick, for floor and wall alike.
      -- A demo or a signed donated / zero-value contract has nothing to collect, so it counts as paid.
      WHEN ((track='floor' AND (pct_paid >= 0.5 OR is_demo OR is_free)) OR (track='wall' AND (pct_paid >= wall_threshold OR is_demo OR is_free)))
           AND materials_available_c = TRUE THEN 'D'
      WHEN track='wall' AND (pct_paid >= wall_threshold OR is_demo OR is_free) THEN 'C'
      WHEN track='floor' AND (pct_paid >= 0.5 OR is_demo OR is_free) THEN 'C'
      WHEN signed_date IS NOT NULL AND EXTRACT(YEAR FROM signed_date) >= 2026 THEN 'B'
      WHEN signed_date IS NOT NULL THEN 'A'
      WHEN signed_date IS NULL THEN 'O'
      ELSE 'Z' END AS stage_code
  FROM cls
),
flagged AS (
  SELECT *,
    -- Impossible dates and unfinished records come first: they need fixing in Salesforce before anything else.
    CASE
      WHEN signed_date > CURRENT_DATE() THEN 'signed date in the future'
      WHEN signed_date IS NOT NULL AND prod = '' AND COALESCE(total_amount,0) <= 0 THEN 'no product or price recorded'
      WHEN track <> 'repair' AND completed_date_raw > CURRENT_DATE() THEN 'completion date in the future'
      WHEN track <> 'repair' AND completed_date_raw < signed_date THEN 'completed before signing'
      WHEN track <> 'repair' AND completed_date < started_date THEN 'completion date before work started'
      WHEN stage_code = 'P' THEN 'final eval pass but no completion date'
      WHEN stage_code = 'L' AND signed_date IS NULL THEN 'completed but never contracted'
      WHEN stage_code = 'L' AND track = 'floor' AND COALESCE(final_res,'') <> 'Pass' THEN 'completed without final eval record'
      -- A loan contract is paid over years, so being part-paid at completion is the design.
      WHEN stage_code IN ('L','N') AND pct_paid < 1.0 AND NOT is_free AND COALESCE(type_c,'') != 'Loan Contract' THEN 'completed but not fully paid'
      ELSE NULL END AS cleanup_reason
  FROM staged
)
SELECT
  s.opportunity_id, s.opportunity_label,
  cj.Customer_Name AS customer_name,
  COALESCE(cj.Customer_phone, cj.Customer_mobile_phone) AS customer_phone,
  cj.Customer_Sales_Officer_Name AS cso_name,
  s.country, s.branch, s.district, s.territory,
  s.track, s.product_family, s.is_demo, s.is_free, s.pct_paid, s.cash_paid, s.total_amount,
  -- Size of the job. SQM-E is the company's equivalent-square-metre unit, the same weight
  -- the CSO views use: a floor counts 1.0, everything else (plaster, paint, ceiling plaster,
  -- repair) 0.333. Jobs with no product recorded are weighted 0.333 so they cannot inflate.
  ROUND(s.raw_sqm, 1) AS raw_sqm,
  ROUND(s.raw_sqm * IF(s.product_family = 'floor', 1.0, 0.333), 1) AS sqme,
  GREATEST(s.total_amount - s.cash_paid, 0) AS outstanding_amount,
  (s.cash_paid = 0) AS is_zero_paid,
  s.signed_date, s.created_date, s.completed_date,
  s.stage_code,
  CASE s.stage_code
    WHEN 'O' THEN 'O Promised - not contracted'
    WHEN 'A' THEN 'A Sale/DP paid, below threshold (2024/25)'
    WHEN 'B' THEN 'B Sale/DP paid, collecting (2026)'
    WHEN 'C' THEN 'C Cash collected - materials unknown'
    WHEN 'D' THEN 'D Cash collected - materials available'
    WHEN 'F' THEN 'F Started: timesheet/anti-termite/first evaluation'
    WHEN 'G' THEN 'G Compaction eval (redo/fail)'
    WHEN 'H' THEN 'H Wood float/screed OR plastering underway'
    WHEN 'I' THEN 'I Screed / prior-paint eval (redo/fail)'
    WHEN 'J' THEN 'J Evals passed: 100% payment / delivery pending'
    WHEN 'K' THEN 'K Paint/varnish delivered'
    WHEN 'L' THEN 'L Completed'
    WHEN 'M' THEN 'M Need repairs'
    WHEN 'N' THEN 'N Repair completed'
    WHEN 'P' THEN 'P Final eval pass, no completion date'
    WHEN 'Q' THEN 'Q Lost client'
    ELSE 'Z Uncategorized' END AS journey_stage,
  CASE
    WHEN s.stage_code IN ('L','N','P','Q') THEN 'terminal'
    WHEN s.stage_code = 'M' THEN 'repairs'
    WHEN s.stage_code IN ('J','K') THEN 'finishing'
    WHEN s.stage_code IN ('F','G','H','I') THEN 'building'
    WHEN s.stage_code IN ('C','D') THEN 'ready_to_build'
    WHEN s.stage_code = 'B' THEN 'collecting'
    WHEN s.stage_code = 'A' THEN 'backlog'
    WHEN s.stage_code = 'O' THEN 'promised'
    ELSE 'unclassified' END AS stage_class,
  CASE
    WHEN s.stage_code = 'A' THEN '1 Signed, not collected (2024/25)'
    WHEN s.stage_code = 'B' THEN '2 Signed, not collected (2026)'
    WHEN s.stage_code = 'C' THEN '3 Collected, materials unknown'
    WHEN s.stage_code = 'D' THEN '4 Collected, materials available'
    WHEN s.stage_code IN ('F','G','H','I','J') THEN '5 Started, not varnished'
    WHEN s.stage_code = 'K' THEN '6 Varnished, not evaluated'
    ELSE NULL END AS tl_simple_bucket,
  CASE
    WHEN s.stage_code = 'A' THEN '1 Signed, not collected (pre-2026)'
    -- Materials available is actionable whatever the signing year, so it wins over the pre-2026 cohort.
    WHEN s.stage_code = 'D' THEN '5 Collected, materials available'
    WHEN EXTRACT(YEAR FROM s.signed_date) < 2026 AND s.stage_code IN ('C','F','G','H','I','J','K','P') THEN '2 Collected, not completed (pre-2026)'
    WHEN s.stage_code = 'B' THEN '3 Signed, not collected (2026)'
    WHEN s.stage_code = 'C' THEN '4 Collected, materials unknown (2026)'
    WHEN s.stage_code IN ('F','G','H','I','J') THEN '6 Started, not varnished (2026)'
    WHEN s.stage_code = 'K' THEN '7 Varnished, not evaluated (2026)'
    WHEN s.stage_code IN ('L','N') THEN '8 Completed'
    ELSE NULL END AS app_bucket,
  CASE
    WHEN s.stage_code = 'B' THEN 'DOL'
    WHEN s.stage_code = 'A' THEN 'DOL_campaign'
    WHEN s.stage_code IN ('C','D') THEN 'branch_ops'
    WHEN s.stage_code IN ('G','I') THEN 'QA'
    WHEN s.stage_code IN ('F','H','J','K','M') THEN 'TL'
    ELSE 'none' END AS queue_owner,
  -- Floored at zero: a stage date in the future is a data-entry error, not negative waiting.
  GREATEST(DATE_DIFF(CURRENT_DATE(), CASE s.stage_code
    WHEN 'O' THEN s.created_date
    WHEN 'A' THEN COALESCE(s.last_payment_date_c, s.dp_date_c, s.signed_date)
    WHEN 'B' THEN COALESCE(s.last_payment_date_c, s.dp_date_c, s.signed_date)
    WHEN 'C' THEN COALESCE(IF(s.track='floor', s.d50, s.d100), s.last_payment_date_c, s.signed_date)
    WHEN 'D' THEN COALESCE(s.date_materials_confirmed_c, IF(s.track='floor', s.d50, s.d100), s.last_payment_date_c, s.signed_date)
    WHEN 'F' THEN COALESCE(s.started_date, s.acs, s.insect_mv, s.termite_mv)
    WHEN 'G' THEN COALESCE(s.compaction_dt, s.insect_mv, s.termite_mv)
    WHEN 'H' THEN COALESCE(IF(s.track='floor', s.compaction_dt, s.started_date), s.d100, s.signed_date)
    WHEN 'I' THEN COALESCE(IF(s.track='floor', s.screed_dt, s.first_plaster_eval), s.d100, s.signed_date)
    WHEN 'J' THEN COALESCE(IF(s.track='floor', s.screed_dt, s.first_plaster_eval), s.d100, s.signed_date)
    WHEN 'K' THEN COALESCE(s.varnish_mv, s.paint_mv)
    WHEN 'L' THEN s.completed_date
    WHEN 'M' THEN COALESCE(s.dp_date_c, s.signed_date, s.created_date)
    WHEN 'N' THEN s.completed_date
    WHEN 'P' THEN s.final_eval_dt
    WHEN 'Q' THEN s.close_date
    ELSE COALESCE(s.signed_date, s.created_date) END, DAY), 0) AS days_in_stage,
  s.cleanup_reason,
  s.cleanup_reason IS NOT NULL AS needs_data_cleanup,
  COALESCE(s.materials_available_c, FALSE) AS materials_available,
  s.date_materials_confirmed_c AS materials_confirmed_date,
  s.started_date,
  s.first_ts AS first_timesheet_date,
  s.first_plaster_eval AS first_plaster_eval_date
FROM flagged s
LEFT JOIN `earth-enable-main.salesforce.Customer Journey Category` cj ON s.opportunity_id = cj.opportunity_id
