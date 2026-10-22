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

-- employee_code is "<payroll>/<EmpNo>", so the payroll a value belongs to is
-- recoverable from it. Returns NULL for a code that does not carry the prefix
-- (a user who renamed theirs), which makes the promoted-ordinal match simply not
-- apply - reporting the row as a difference rather than silently excluding it.
CREATE OR REPLACE FUNCTION compare.code_payroll(code text) RETURNS integer
LANGUAGE sql IMMUTABLE AS $fn$
    SELECT CASE WHEN code ~ '^[0-9]+/' THEN split_part(code, '/', 1)::int END
$fn$;

-- ONE ROW PER (snapshot pair, value): the comparison runs inside one ordered pair
-- of snapshots at a time. It used to FULL JOIN every row against EVERY other
-- snapshot (ON ... b.snap <> a.snap). Once compare held more than two snapshots,
-- a value missing from B but present in some third snapshot paired with that
-- third one instead, the snap_b filter then dropped the row, and the loss
-- vanished - no only_in_a, and no 'promoted' either. snap_a / snap_b are always
-- real labels now, never '(absent)': filter on BOTH, or a query sums every pair.
CREATE OR REPLACE VIEW compare.value_diff AS
SELECT
    pr.snap_a,
    pr.snap_b,
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
                        AND p.ordinal_no = COALESCE(a.ordinal_no, b.ordinal_no)
                        AND p.payroll = compare.code_payroll(COALESCE(a.employee_code, b.employee_code)))
             AND (a.snap IS NULL OR b.snap IS NULL) THEN 'promoted'
        WHEN a.snap IS NULL THEN 'only_in_b'
        WHEN b.snap IS NULL THEN 'only_in_a'
        WHEN COALESCE(a.bank, b.bank) = 'Q'
             AND a.value_num IS DISTINCT FROM b.value_num THEN 'value_differs'
        WHEN COALESCE(a.bank, b.bank) <> 'Q'
             AND btrim(COALESCE(a.value_text,'')) IS DISTINCT FROM btrim(COALESCE(b.value_text,'')) THEN 'value_differs'
        ELSE 'match'
    END AS verdict
FROM (SELECT sa.snap AS snap_a, sb.snap AS snap_b
        FROM compare.snapshot sa JOIN compare.snapshot sb ON sb.snap <> sa.snap) pr
-- Every key either side of THIS pair holds, then each side looked up on it: a
-- FULL JOIN scoped to the pair.
CROSS JOIN LATERAL (
    SELECT k.employee_code, k.bank, k.ordinal_no
      FROM compare.employee_value k
     WHERE k.snap IN (pr.snap_a, pr.snap_b)
     GROUP BY k.employee_code, k.bank, k.ordinal_no) key
LEFT JOIN compare.employee_value a
       ON  a.snap = pr.snap_a AND a.employee_code = key.employee_code
      AND  a.bank = key.bank  AND a.ordinal_no    = key.ordinal_no
LEFT JOIN compare.employee_value b
       ON  b.snap = pr.snap_b AND b.employee_code = key.employee_code
      AND  b.bank = key.bank  AND b.ordinal_no    = key.ordinal_no;

-- PROMOTED VALUES, column against column. The 'promoted' verdict above excludes
-- the promoted slots from the value diff, so without this check a value that
-- reached neither the slot NOR the column it was promoted to - the passport, for
-- the whole of the first client - is reported as nothing at all. Compares the
-- two snapshots' compare.employee_promoted rows (93 files legacy's from the
-- slots, 91 files interim's and pipro's from the employee columns).
-- Normalised before comparing: pipro spells gender out (male -> M) and writes
-- 'unspecified' where legacy simply has no indicator; blanks are absent.
-- Category and the identifiers compare exactly (trimmed), case included.
CREATE OR REPLACE FUNCTION compare.promoted_norm(field text, value text) RETURNS text
LANGUAGE sql IMMUTABLE AS $fn$
    SELECT CASE
        WHEN btrim(COALESCE(value, '')) = '' THEN NULL
        WHEN field = 'gender' THEN
            CASE lower(btrim(value)) WHEN 'male' THEN 'M' WHEN 'female' THEN 'F' WHEN 'other' THEN 'O'
                                     WHEN 'unspecified' THEN NULL ELSE upper(btrim(value)) END
        WHEN field = 'passport_country' THEN upper(btrim(value))
        ELSE btrim(value)
    END
$fn$;

CREATE OR REPLACE FUNCTION compare.promoted_diff(a text, b text)
RETURNS TABLE (employee_code text, field text, a_value text, b_value text,
               a_origin text, b_origin text, verdict text)
LANGUAGE sql STABLE AS $fn$
    WITH pa AS (SELECT p.employee_code, p.field, compare.promoted_norm(p.field, p.value_text) AS v, p.origin
                  FROM compare.employee_promoted p WHERE p.snap = a),
         pb AS (SELECT p.employee_code, p.field, compare.promoted_norm(p.field, p.value_text) AS v, p.origin
                  FROM compare.employee_promoted p WHERE p.snap = b)
    SELECT COALESCE(pa.employee_code, pb.employee_code), COALESCE(pa.field, pb.field),
           pa.v, pb.v, pa.origin, pb.origin,
           CASE WHEN pa.v IS NULL THEN 'only_in_b'
                WHEN pb.v IS NULL THEN 'only_in_a'
                WHEN pa.v = pb.v  THEN 'match'
                ELSE 'value_differs' END
    FROM (SELECT * FROM pa WHERE v IS NOT NULL) pa
    FULL JOIN (SELECT * FROM pb WHERE v IS NOT NULL) pb
      ON pb.employee_code = pa.employee_code AND pb.field = pa.field
$fn$;

\echo ''
\echo '=== 1. Verdict summary by bank ============================================'
SELECT bank, verdict, count(*) AS rows, count(DISTINCT employee_code) AS employees
FROM compare.value_diff
WHERE snap_a = :'a' AND snap_b = :'b'
GROUP BY bank, verdict
ORDER BY bank, verdict;

\echo ''
\echo '=== 2. Present in A but missing from B (values lost) ======================='
SELECT bank, ordinal_no, a_origin, count(*) AS rows, count(DISTINCT employee_code) AS employees
FROM compare.value_diff
WHERE verdict = 'only_in_a' AND snap_a = :'a' AND snap_b = :'b'
GROUP BY bank, ordinal_no, a_origin
ORDER BY rows DESC, bank, ordinal_no
LIMIT 40;

\echo ''
\echo '=== 3. Present in B but missing from A (values invented) ==================='
SELECT bank, ordinal_no, b_origin, count(*) AS rows, count(DISTINCT employee_code) AS employees
FROM compare.value_diff
WHERE verdict = 'only_in_b' AND snap_a = :'a' AND snap_b = :'b'
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

\echo ''
\echo '=== 6. Promoted values vs the employee columns they became ================'
-- PASS = only 'match'. only_in_a = the value was lost on the way to its column.
-- A snapshot taken before this check existed has no promoted rows; re-capture it.
SELECT field, verdict, count(*) AS employees
FROM compare.promoted_diff(:'a', :'b')
GROUP BY field, verdict
ORDER BY field, verdict;

\echo ''
\echo '=== 7. Promoted values that do not match =================================='
SELECT employee_code, field, a_value, b_value, verdict, a_origin, b_origin
FROM compare.promoted_diff(:'a', :'b')
WHERE verdict <> 'match'
ORDER BY field, employee_code
LIMIT 40;
