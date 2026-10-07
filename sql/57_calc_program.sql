-- ===========================================================================
-- 57_calc_program.sql — import the client's legacy calc program into the
-- engine's program store, calc_program. Run ONCE PER TENANT after 55 (which
-- carries settings_calculations into the tenant).
--
-- WHY: the calc program IS the client's pay logic (package splits, birthday
-- bonuses, bursaries, pro-rating, leave rates ...). Every system in the product
-- line runs it per employee; until it is in calc_program the engine only runs
-- the 2-line salary-only seed and the imported earning lines are frozen copies
-- of legacy's last results. After cutover calc_program is the live program
-- (edited there, never re-imported); settings_calculations is only the source.
--
-- SCOPE: calc set 1 only - the pay run's set (help P006.1: the default set;
-- the interim's PayRunProcess hard-codes it too). Sets 2+ serve special runs,
-- manual payments and pay reversals, none of which this system supports yet;
-- mid-run payments will be designed from scratch. (Owner decision 2026-10-07.)
--
-- LOSSLESS: one calc_program row per legacy line, legacy semantics untouched.
--   ordinal          <- OrdinalNo
--   calc_time        <- CalcCode (10/20/30/35/40/45/50/60), verbatim
--   mnemonic         <- OpCode, upper-cased ('' for a blank line - legacy and
--                       the interim skip those; the engine must too)
--   ind_number/_expected <- IndSub / IndVal; a blank IndVal under a real IndSub
--                       is kept as '' (13 airplane lines run only when the
--                       indicator is BLANK), no indicator when IndSub = 0
--   op<n>_type       <- Op<n>A, the legacy letter as written (NULL if blank)
--   op<n>_n          <- Op<n>N (a code number, a literal, a jump target ...)
--   op<n>_text       <- Op<n>X
-- No translation of letters or code numbers here: what a letter means depends
-- on the opcode and on legacy semantics (S = Current- AND Quantities-Store, M =
-- master file register, a blank letter's N = GO's jump target ...), so the
-- engine decodes rows whose calc_time is set the legacy way.
--
-- STAGED: program_key 'legacy:payroll-<id>', which the engine does not resolve,
-- so importing does not switch the payroll onto a program the engine cannot run
-- yet. Promoting it is a rename to 'payroll-<id>' once the engine runs legacy
-- programs. Effective from 2000-01-01 like the seed, so re-running any imported
-- period resolves the same program.
--
-- Runner variables: :tenant_schema :target_payroll_id :payroll_number :cutover
-- ===========================================================================
\set ON_ERROR_STOP on
BEGIN;
SET search_path TO :"tenant_schema", public;

INSERT INTO calc_program (
    id, program_key, ordinal, stage, calc_time, mnemonic, ind_number, ind_expected,
    op1_type, op1_n, op1_text,
    op2_type, op2_n, op2_text,
    op3_type, op3_n,
    effective_from, recorded_at, created_by_user_id)
SELECT
    (SELECT COALESCE(MAX(id), 0) FROM calc_program) + ROW_NUMBER() OVER (ORDER BY s.ordinal_no),
    'legacy:payroll-' || :target_payroll_id,
    s.ordinal_no,
    'MAIN',
    s.calc_code,
    UPPER(TRIM(COALESCE(s.op_code, ''))),
    CASE WHEN COALESCE(s.ind_sub, 0) = 0 THEN NULL ELSE s.ind_sub END,
    CASE WHEN COALESCE(s.ind_sub, 0) = 0 THEN NULL ELSE COALESCE(TRIM(s.ind_val), '') END,
    NULLIF(TRIM(s.op1_a), ''), s.op1_n, NULLIF(TRIM(s.op1_x), ''),
    NULLIF(TRIM(s.op2_a), ''), s.op2_n, NULLIF(TRIM(s.op2_x), ''),
    NULLIF(TRIM(s.op3_a), ''), s.op3_n,
    '2000-01-01',
    to_char(now() AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'),
    NULL
FROM settings_calculations s
WHERE s.payroll = :payroll_number
  AND s.calc_set = 1
  AND NOT EXISTS (                                   -- idempotency: imported once
    SELECT 1 FROM calc_program x
     WHERE x.program_key = 'legacy:payroll-' || :target_payroll_id);

COMMIT;
\echo 'Done (legacy calc program, calc set 1 -> calc_program, staged):' :tenant_schema
