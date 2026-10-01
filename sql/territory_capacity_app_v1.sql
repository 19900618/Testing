-- =============================================================================
-- salesforce.territory_capacity_app_v1
--
-- A Classic toolkit view (Individual CSOs, Rwanda: territory capacity), kept here
-- so changes to it are reviewed like the rest. The app reads it by name, so run
-- this file in the BigQuery console to deploy it.
-- Copied from the live definition on 2026-09-29, then changed so targets are the
-- month's own (not next month's), and Nyagatare C shares the district target from September 2026.
-- =============================================================================

CREATE OR REPLACE VIEW `earth-enable-main.salesforce.territory_capacity_app_v1`
AS
WITH opp AS (
  SELECT
    S.territory_c AS territory,
    L.district_c AS district,
    COALESCE(o.product_interest_c, o.new_product_interest_c) AS pi,
    o.date_associated_project_completed_c AS completed_date,
    COALESCE(o.total_square_meters_c, 0) AS raw_sqm
  FROM `earth-enable-main.salesforce.opportunity` o
  LEFT JOIN `earth-enable-main.salesforce.location_c` L ON o.umudugudu_c = L.id
  LEFT JOIN `earth-enable-main.salesforce.location_c` S ON L.sector_c = S.id
  WHERE o._fivetran_deleted = FALSE
    AND L.country_c = 'Rwanda'
    AND o.phase_c = '1'
    AND o.stage_name NOT IN ('Closed Lost','Houses meet criteria')
    AND o.date_associated_project_completed_c IS NOT NULL
),
builds AS (
  SELECT DATE_TRUNC(completed_date, MONTH) AS month, territory,
    ANY_VALUE(district) AS district,
    COUNT(*) AS builds_completed,
    ROUND(SUM(raw_sqm * IF(LOWER(pi) LIKE '%floor%' OR pi IS NULL, 1.0, 0.333))) AS sqme_built
  FROM opp
  WHERE territory IS NOT NULL AND DATE_TRUNC(completed_date, MONTH) <= DATE_TRUNC(CURRENT_DATE(), MONTH)
  GROUP BY month, territory
),
masons AS (
  SELECT DATE_TRUNC(end_date, MONTH) AS month,
    NULLIF(TRIM(territory),'') AS territory,
    COUNT(DISTINCT mason_id) AS masons_active,
    ROUND(SUM(sqm)) AS mason_sqm
  FROM `earth-enable-main.raw_data_from_salesforce.mason_timesheet_readable`
  WHERE NOT COALESCE(is_deleted, FALSE) AND NOT COALESCE(fivetran_deleted, FALSE)
    AND country = 'Rwanda' AND mason_id IS NOT NULL AND end_date IS NOT NULL
    AND NULLIF(TRIM(territory),'') IS NOT NULL
    AND DATE_TRUNC(end_date, MONTH) <= DATE_TRUNC(CURRENT_DATE(), MONTH)
  GROUP BY month, territory
),
spine AS (
  SELECT month, territory FROM builds
  UNION DISTINCT SELECT month, territory FROM masons
)
SELECT
  s.month, s.territory,
  COALESCE(b.district, 'Unassigned') AS district,
  tg.manager,
  COALESCE(b.builds_completed, 0) AS builds_completed,
  COALESCE(b.sqme_built, 0) AS sqme_built,
  COALESCE(m.masons_active, 0) AS masons_active,
  COALESCE(m.mason_sqm, 0) AS mason_sqm,
  tg.territory IS NOT NULL AS has_targets,
  tg.build_target,
  tg.sqme_target,
  tg.min_productive_masons AS min_masons,
  tg.min_build_productivity,
  5.0 AS min_csos,
  SAFE_DIVIDE(COALESCE(b.builds_completed,0), tg.build_target) AS pct_of_build_target,
  tg.min_productive_masons - COALESCE(m.masons_active, 0) AS masons_short,
  SAFE_DIVIDE(COALESCE(b.builds_completed,0), NULLIF(COALESCE(m.masons_active,0),0)) AS builds_per_mason,
  SAFE_DIVIDE(
    SAFE_DIVIDE(COALESCE(b.builds_completed,0), NULLIF(COALESCE(m.masons_active,0),0)),
    tg.min_build_productivity) AS pct_build_productivity,
  FORMAT_DATE('%B %Y', s.month) AS month_label
FROM spine s
LEFT JOIN builds b ON b.month = s.month AND b.territory = s.territory
LEFT JOIN masons m ON m.month = s.month AND m.territory = s.territory
-- The month's own target, with the Nyagatare rule: from September 2026 the
-- district target (A + B) is shared B one half, A one quarter, C one quarter;
-- before that C has no target.
LEFT JOIN (
  SELECT month, territory, district, n_territories, sqme_target, build_target, min_productive_masons, min_build_productivity, manager FROM `earth-enable-main.raw_data_from_salesforce.tl_bonus_targets`
  WHERE NOT (territory IN ('Nyagatare A', 'Nyagatare B', 'Nyagatare C') AND month >= DATE '2026-09-01')
  UNION ALL
  -- From September 2026 the Nyagatare district target (the official A + B) is
  -- shared B one half, A one quarter, C one quarter (regional manager,
  -- 2026-09-29). Nothing is added: district and country totals stay official.
  -- Before that, A and B keep their rows and C has no target.
  SELECT d.month, s.territory, d.district, 3 AS n_territories,
    d.sqme_target * s.share, d.build_target * s.share, d.min_productive_masons * s.share,
    d.min_build_productivity, d.manager
  FROM (
    SELECT month, ANY_VALUE(district) AS district, ANY_VALUE(manager) AS manager,
      SUM(sqme_target) AS sqme_target, SUM(build_target) AS build_target,
      SUM(min_productive_masons) AS min_productive_masons, ANY_VALUE(min_build_productivity) AS min_build_productivity
    FROM `earth-enable-main.raw_data_from_salesforce.tl_bonus_targets`
    WHERE territory IN ('Nyagatare A', 'Nyagatare B') AND month >= DATE '2026-09-01'
    GROUP BY month
  ) d
  CROSS JOIN UNNEST([STRUCT('Nyagatare A' AS territory, 0.25 AS share), ('Nyagatare B', 0.5), ('Nyagatare C', 0.25)]) s
) tg
  ON tg.territory = s.territory AND tg.month = s.month;
