-- ===========================================================================
-- 80_payroll_periods.sql — generate the app's payroll_periods from the
-- IMPORTED legacy calendar (settings_calendar, carried by 55) instead of
-- hand-typing the tax year into the UI. Run ONCE PER TENANT after 55.
--
-- Desktop reality (2026-07-30): pay_period_from/_to and run_done_ind are
-- EMPTY in the interim calendar; run_date holds each period's month-end
-- (ZA tax year, March..February). So:
--   period_end   <- run_date
--   period_start <- first of that month
--   payday       <- run_date          CHOOSE: legacy run date = payday?
--   status       <- 'closed' for every period legacy ALREADY RAN, i.e. up to and
--                   including settings_global.current_run_date; 'open' after it.
--                   DERIVED from the data, not from :cutover - see the CASE below.
--
-- Runner variables: :tenant_schema :target_payroll_id :payroll_number :cutover
-- ===========================================================================
\set ON_ERROR_STOP on
BEGIN;
SET search_path TO :"tenant_schema", public;

INSERT INTO payroll_periods (
    payroll_id, period_start, period_end, payday, country_code,
    status, created_at, period_kind)
SELECT
    :target_payroll_id,
    date_trunc('month', c.run_date)::date::text,     -- app stores dates as TEXT
    c.run_date::text,
    c.run_date::text,
    p.country_code,
    -- DERIVED, not taken from :cutover. settings_global.current_run_date is the
    -- period legacy last actually ran (carried by 55), so anything up to and
    -- including it is history and anything after it is pipro's to run. Passing a
    -- cutover instead was wrong in a way that was easy to miss: convert.ps1 hands
    -- it TODAY's date, so converting in October closed July, August and September
    -- as well - periods legacy had never run and pipro then could not.
    -- Falls back to :cutover only if the pointer is missing.
    CASE WHEN c.run_date <= COALESCE(
                (SELECT g.current_run_date::date FROM settings_global g LIMIT 1),
                date_trunc('month', :'cutover'::date)::date - 1)
         THEN 'closed' ELSE 'open' END,
    :'cutover',
    'regular'
FROM settings_calendar c
JOIN payrolls p ON p.id = :target_payroll_id
WHERE c.payroll = :payroll_number
  AND c.run_date IS NOT NULL
  AND NOT EXISTS (                                   -- idempotency
    SELECT 1 FROM payroll_periods x
     WHERE x.payroll_id = :target_payroll_id AND x.period_end = c.run_date::text);

COMMIT;
\echo 'Done (payroll periods from legacy calendar):' :tenant_schema
