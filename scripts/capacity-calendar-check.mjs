// Proves src/lib/capacity-calendar.ts matches the BigQuery calendar query it
// replaced. The old query is transcribed below with CURRENT_DATE() swapped
// for a generated `today`, so one query yields the calendar as at every day
// from 2025-12-01 to a year from now; each is compared with the TypeScript.
//   node scripts/capacity-calendar-check.mjs        (needs gcp-key.json)
import { BigQuery } from "@google-cloud/bigquery";
import { capacityCalendar, CAPACITY_CALENDAR_FROM } from "../src/lib/capacity-calendar.ts";

const SQL = `
    SELECT
      CAST(today AS STRING) AS today,
      CAST(mth AS STRING) AS month, FORMAT_DATE('%B %Y', mth) AS month_label, w AS week_no,
      CONCAT('W', CAST(w AS STRING), ' (', FORMAT_DATE('%d', ws), '-', FORMAT_DATE('%d %b', we), ')') AS week_label,
      CAST(ws AS STRING) AS week_start, CAST(we AS STRING) AS week_end,
      we < today AS is_complete_week,
      ws <= today AND we >= today AS is_current_week
    FROM UNNEST(GENERATE_DATE_ARRAY(DATE '2025-12-01', DATE_ADD(CURRENT_DATE(), INTERVAL 365 DAY))) today,
      UNNEST(GENERATE_DATE_ARRAY(DATE '${CAPACITY_CALENDAR_FROM}', DATE_TRUNC(today, MONTH), INTERVAL 1 MONTH)) mth,
      UNNEST([1, 2, 3, 4]) w,
      UNNEST([DATE_ADD(mth, INTERVAL (w - 1) * 7 DAY)]) ws,
      UNNEST([IF(w = 4, LAST_DAY(mth), DATE_ADD(mth, INTERVAL w * 7 - 1 DAY))]) we
    WHERE ws <= today
    ORDER BY today, mth, w`;

const bq = new BigQuery({ projectId: "earth-enable-main", keyFilename: "gcp-key.json" });
const [rows] = await bq.query({ query: SQL, location: "US" });
const byDay = new Map();
for (const r of rows) {
  if (!byDay.has(r.today)) byDay.set(r.today, []);
  byDay.get(r.today).push({
    month: r.month, monthLabel: r.month_label, weekNo: Number(r.week_no), weekLabel: r.week_label,
    weekStart: r.week_start, weekEnd: r.week_end, isComplete: Boolean(r.is_complete_week), isCurrent: Boolean(r.is_current_week),
  });
}

const dates = [];
for (let d = new Date("2025-12-01T00:00:00Z"); d <= new Date(Date.now() + 365 * 86400000); d = new Date(d.getTime() + 86400000)) dates.push(d.toISOString().slice(0, 10));
let failures = 0, weeks = 0;
for (const d of dates) {
  const sql = JSON.stringify(byDay.get(d) ?? []);
  const ts = JSON.stringify(capacityCalendar(d));
  weeks += (byDay.get(d) ?? []).length;
  if (sql !== ts && ++failures <= 5) console.log(`MISMATCH for today=${d}\n  sql: ${sql.slice(0, 240)}\n  ts : ${ts.slice(0, 240)}`);
}
console.log(`${dates.length} dates compared (${dates[0]} to ${dates[dates.length - 1]}), ${weeks} week rows from SQL, ${failures} mismatches`);
process.exit(failures ? 1 : 0);
