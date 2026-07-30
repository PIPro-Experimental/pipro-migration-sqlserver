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
--   status       <- 'closed' for months fully before the cutover month
--                   (legacy already ran them; their history came via
--                   run_history), 'open' for the cutover month onward
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
    CASE WHEN c.run_date < date_trunc('month', :'cutover'::date)::date
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
