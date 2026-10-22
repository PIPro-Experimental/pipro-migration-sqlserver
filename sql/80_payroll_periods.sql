-- ===========================================================================
-- 80_payroll_periods.sql — generate the app's payroll_periods from the
-- IMPORTED legacy calendar (settings_calendar, carried by 55) instead of
-- hand-typing the tax year into the UI. Run ONCE PER TENANT after 55.
--
-- FREQUENCY (owner 2026-10-20): payrolls.frequency is SET FROM THE CALENDAR -
-- the median gap between consecutive run dates: ~7 days weekly, ~14 biweekly,
-- 28-31 monthly; anything else stops the import. Name, currency and the rest of
-- the payrolls row stay as the user entered them. settings_user_tax.no_of_periods
-- is only cross-checked and reported: it may just be Pay280's starting value for
-- generating the calendar, so the calendar itself is the authority.
--
-- Desktop reality (2026-07-30): pay_period_from/_to and run_done_ind are
-- EMPTY in the interim calendar; run_date holds each period's end
-- (month-end on a monthly ZA tax year, March..February). So:
--   period_end   <- run_date
--   period_start <- first of that month (monthly), run_date - 6 (weekly),
--                   run_date - 13 (biweekly)
--   payday       <- run_date          CHOOSE: legacy run date = payday?
--   status       <- 'closed' for every period legacy ALREADY RAN, i.e. up to and
--                   including settings_global.current_run_date; 'open' after it.
--                   DERIVED from the data, not from :cutover - see the CASE below.
--
-- Runner variables: :tenant_schema :target_payroll_id :legacy_company_schema :cutover (payroll number: read from the data)
-- ===========================================================================
\set ON_ERROR_STOP on
-- The legacy payroll number is READ FROM THE DATA, not supplied by the runner:
-- every interim employees row carries it in payroll_f04, and one schema holds
-- one payroll. A schema with no number, or with two, stops here rather than guess.
SELECT CASE WHEN count(DISTINCT payroll_f04) = 1 AND count(payroll_f04) = count(*)
            THEN min(payroll_f04)::text
            ELSE ('no single payroll number in ' || :'legacy_company_schema' || '.employees.payroll_f04: '
                  || COALESCE(string_agg(DISTINCT payroll_f04::text, ','), 'none'))::int::text
       END AS payroll_number
FROM :"legacy_company_schema".employees \gset
BEGIN;
SET search_path TO :"tenant_schema", public;

-- ---- Frequency, from the spacing of this payroll's run dates ----------------
WITH d AS (
    SELECT c.run_date - lag(c.run_date) OVER (ORDER BY c.run_date) AS gap
    FROM settings_calendar c
    WHERE c.payroll = :payroll_number AND c.run_date IS NOT NULL)
SELECT count(*) + 1                                        AS calendar_periods,
       percentile_disc(0.5) WITHIN GROUP (ORDER BY gap)    AS median_gap,
       CASE WHEN percentile_disc(0.5) WITHIN GROUP (ORDER BY gap) BETWEEN 6 AND 8   THEN 'weekly'
            WHEN percentile_disc(0.5) WITHIN GROUP (ORDER BY gap) BETWEEN 13 AND 15 THEN 'biweekly'
            WHEN percentile_disc(0.5) WITHIN GROUP (ORDER BY gap) BETWEEN 28 AND 31 THEN 'monthly'
            -- the cast fails on purpose: no recognisable frequency stops the import
            ELSE ('cannot tell the frequency of payroll ' || :payroll_number || ' from its calendar: median gap between run dates is '
                  || COALESCE(percentile_disc(0.5) WITHIN GROUP (ORDER BY gap)::text, 'unknown (fewer than 2 run dates)') || ' days')::int::text
       END                                                 AS frequency
FROM d WHERE gap IS NOT NULL \gset

UPDATE payrolls SET frequency = :'frequency' WHERE id = :target_payroll_id;

SELECT :'frequency' AS frequency_from_calendar, :calendar_periods AS calendar_periods, :median_gap AS median_gap_days,
       t.no_of_periods AS legacy_no_of_periods,
       CASE WHEN t.no_of_periods IS NULL THEN 'no settings_user_tax row'
            WHEN t.no_of_periods = CASE :'frequency' WHEN 'monthly' THEN 12 WHEN 'biweekly' THEN 26 ELSE t.no_of_periods END
              OR (:'frequency' = 'weekly' AND t.no_of_periods IN (52, 53)) THEN 'agrees'
            ELSE 'DIFFERS - check the legacy setup (calendar wins)' END AS cross_check
FROM (SELECT 1) one
LEFT JOIN settings_user_tax t ON t.payroll = :payroll_number;

INSERT INTO payroll_periods (
    payroll_id, period_start, period_end, payday, country_code,
    status, created_at, period_kind)
SELECT
    :target_payroll_id,
    (CASE :'frequency' WHEN 'weekly'   THEN c.run_date - 6
                       WHEN 'biweekly' THEN c.run_date - 13
                       ELSE date_trunc('month', c.run_date)::date END)::text,   -- app stores dates as TEXT
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
                -- THIS payroll's pointer: a multi-payroll tenant holds one settings_global row per payroll
                (SELECT g.current_run_date::date FROM settings_global g WHERE g.payroll = :payroll_number),
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
