-- ===========================================================================
-- 92_employee_diff.sql — diff any two snapshots captured by 91.
--
-- Runner variables:  :a  :b   (snapshot labels; b is read as "the new side")
--
-- The same script serves all four comparisons, because they differ only in
-- which two snapshots you name:
--
--   interim-before  vs pipro-before   IMPORT FIDELITY  — did hop 2 carry every
--                                     value faithfully? Both sides pre-run, so
--                                     any difference is an import defect.
--   legacy-before   vs interim-before hop 1, same logic.
--   legacy-before   vs legacy-after   WHAT THE RUN TOUCHES — the empirical
--                                     answer to whether a run writes back into
--                                     pw_amts, and to which banks/ordinals.
--   legacy-after    vs pipro-after    RUN PARITY on the employee master.
--
-- Values are compared in the canonical shape (employee_code, bank, ordinal_no),
-- numerically for bank Q and textually for V/D. Money was normalised to major
-- units at capture, so no scaling happens here.
-- ===========================================================================
\set ON_ERROR_STOP on

CREATE OR REPLACE VIEW compare.value_diff AS
SELECT
    COALESCE(a.snap, '(absent)')          AS snap_a,
    COALESCE(b.snap, '(absent)')          AS snap_b,
    COALESCE(a.employee_code, b.employee_code) AS employee_code,
    COALESCE(a.bank, b.bank)              AS bank,
    COALESCE(a.ordinal_no, b.ordinal_no)  AS ordinal_no,
    a.value_num                           AS a_num,
    b.value_num                           AS b_num,
    a.value_text                          AS a_text,
    b.value_text                          AS b_text,
    b.value_num - a.value_num             AS delta,
    a.origin                              AS a_origin,
    b.origin                              AS b_origin,
    CASE
        -- Promoted slots (93) became first-class employee columns during hop 1,
        -- so they are absent downstream BY DESIGN. Classified, never counted as
        -- a loss — otherwise every run reports 563 phantom missing values.
        WHEN EXISTS (SELECT 1 FROM compare.promoted_ordinal p
                      WHERE p.bank = COALESCE(a.bank, b.bank)
                        AND p.ordinal_no = COALESCE(a.ordinal_no, b.ordinal_no))
             AND (a.snap IS NULL OR b.snap IS NULL) THEN 'promoted'
        WHEN a.snap IS NULL THEN 'only_in_b'
        WHEN b.snap IS NULL THEN 'only_in_a'
        WHEN COALESCE(a.bank, b.bank) = 'Q'
             AND a.value_num IS DISTINCT FROM b.value_num THEN 'value_differs'
        WHEN COALESCE(a.bank, b.bank) <> 'Q'
             AND btrim(COALESCE(a.value_text,'')) IS DISTINCT FROM btrim(COALESCE(b.value_text,'')) THEN 'value_differs'
        ELSE 'match'
    END AS verdict
FROM       compare.employee_value a
FULL JOIN  compare.employee_value b
       ON  b.employee_code = a.employee_code
      AND  b.bank          = a.bank
      AND  b.ordinal_no    = a.ordinal_no
      AND  b.snap <> a.snap;

\echo ''
\echo '=== 1. Verdict summary by bank ============================================'
SELECT bank, verdict, count(*) AS rows, count(DISTINCT employee_code) AS employees
FROM compare.value_diff
WHERE snap_a IN (:'a','(absent)') AND snap_b IN (:'b','(absent)')
GROUP BY bank, verdict
ORDER BY bank, verdict;

\echo ''
\echo '=== 2. Present in A but missing from B (values lost) ======================='
SELECT bank, ordinal_no, a_origin, count(*) AS rows, count(DISTINCT employee_code) AS employees
FROM compare.value_diff
WHERE verdict = 'only_in_a' AND snap_a = :'a'
GROUP BY bank, ordinal_no, a_origin
ORDER BY rows DESC, bank, ordinal_no
LIMIT 40;

\echo ''
\echo '=== 3. Present in B but missing from A (values invented) ==================='
SELECT bank, ordinal_no, b_origin, count(*) AS rows, count(DISTINCT employee_code) AS employees
FROM compare.value_diff
WHERE verdict = 'only_in_b' AND snap_b = :'b'
GROUP BY bank, ordinal_no, b_origin
ORDER BY rows DESC, bank, ordinal_no
LIMIT 40;

\echo ''
\echo '=== 4. Differing values, worst ordinals first =============================='
SELECT bank, ordinal_no, COALESCE(a_origin, b_origin) AS origin,
       count(*) AS rows,
       sum(abs(COALESCE(delta,0))) AS total_abs_delta,
       max(abs(COALESCE(delta,0))) AS worst_delta
FROM compare.value_diff
WHERE verdict = 'value_differs' AND snap_a = :'a' AND snap_b = :'b'
GROUP BY bank, ordinal_no, COALESCE(a_origin, b_origin)
ORDER BY rows DESC, total_abs_delta DESC
LIMIT 40;

\echo ''
\echo '=== 5. Sample rows behind the worst ordinal ==============================='
SELECT employee_code, bank, ordinal_no, a_num, b_num, delta, a_text, b_text
FROM compare.value_diff
WHERE verdict = 'value_differs' AND snap_a = :'a' AND snap_b = :'b'
ORDER BY abs(COALESCE(delta,0)) DESC NULLS LAST, employee_code
LIMIT 20;
