-- ===========================================================================
-- 96_run_diff.sql — diff two run snapshots, with the noise gates that keep a
-- structurally-different pair from printing thousands of useless rows.
--
-- Runner variables:  :a  :b   (run snapshot labels, a = legacy, b = pipro)
--                    :master_a  :master_b  (the 91 master snapshots, for gate 2)
--                    :tolerance (percent; default 10)
--
-- THE GATES, in the order they fire:
--
--   1. ONE SIDE EMPTY -> say so and stop.
--      3000 rows against 0 is not a diff, it is "the run has not been done".
--      Printing 3000 differences would bury that one fact.
--
--   2. MASTER DATA DIFFERS -> totals only, no line detail.
--      If the two systems disagree about what an employee IS, they will
--      disagree about every figure calculated from it. The line detail would
--      be thousands of consequences of a cause already reported by 92. Totals
--      still show, because the SIZE of the divergence is worth seeing.
--
--   3. ROW COUNTS DIFFER BY MORE THAN :tolerance -> summary only.
--      A structural mismatch (different code set, different employee set) is
--      not readable as a row list. Report the shape of it instead.
--
--   4. Otherwise -> full per-row detail, which is the case worth reading.
--
-- Totals are ALWAYS reported, at every gate. They are the one thing that is
-- meaningful whatever else is wrong.
-- ===========================================================================
\set ON_ERROR_STOP on

CREATE OR REPLACE VIEW compare.run_value_diff AS
SELECT
    COALESCE(a.snap, '(absent)')               AS snap_a,
    COALESCE(b.snap, '(absent)')               AS snap_b,
    COALESCE(a.employee_code, b.employee_code) AS employee_code,
    COALESCE(a.bank, b.bank)                   AS bank,
    COALESCE(a.ordinal_no, b.ordinal_no)       AS ordinal_no,
    a.value_num                                AS a_num,
    b.value_num                                AS b_num,
    b.value_num - a.value_num                  AS delta,
    a.value_text                               AS a_text,
    b.value_text                               AS b_text,
    a.origin                                   AS a_origin,
    b.origin                                   AS b_origin,
    CASE
        WHEN a.snap IS NULL THEN 'only_in_b'
        WHEN b.snap IS NULL THEN 'only_in_a'
        WHEN COALESCE(a.bank, b.bank) = 'Q'
             AND a.value_num IS DISTINCT FROM b.value_num THEN 'value_differs'
        WHEN COALESCE(a.bank, b.bank) <> 'Q'
             AND btrim(COALESCE(a.value_text,'')) IS DISTINCT FROM btrim(COALESCE(b.value_text,'')) THEN 'value_differs'
        ELSE 'match'
    END AS verdict
FROM      compare.run_value a
FULL JOIN compare.run_value b
       ON  b.employee_code = a.employee_code
      AND  b.bank          = a.bank
      AND  b.ordinal_no    = a.ordinal_no
      AND  b.usage_no      = a.usage_no
      AND  b.snap <> a.snap;

-- ---------------------------------------------------------------------------
-- Decide which gate applies, once, so every section below agrees.
-- ---------------------------------------------------------------------------
DROP TABLE IF EXISTS _gate;
CREATE TEMP TABLE _gate AS
WITH counts AS (
    SELECT
        (SELECT count(*) FROM compare.run_value WHERE snap = :'a') AS a_lines,
        (SELECT count(*) FROM compare.run_value WHERE snap = :'b') AS b_lines,
        (SELECT count(*) FROM compare.run_total WHERE snap = :'a') AS a_totals,
        (SELECT count(*) FROM compare.run_total WHERE snap = :'b') AS b_totals,
        -- Counted by joining the two master snapshots directly, NOT through
        -- compare.value_diff. That view reports a one-sided row as snap_b
        -- '(absent)', so filtering it by snap name drops exactly the rows that
        -- matter most here - a value present in legacy and MISSING from pipro.
        -- Promoted ordinals are excluded: they are absent by design, not lost.
        (SELECT count(*)
           FROM (SELECT * FROM compare.employee_value WHERE snap = :'master_a') ma
           FULL JOIN (SELECT * FROM compare.employee_value WHERE snap = :'master_b') mb
             ON mb.employee_code = ma.employee_code
            AND mb.bank         = ma.bank
            AND mb.ordinal_no   = ma.ordinal_no
          WHERE NOT EXISTS (SELECT 1 FROM compare.promoted_ordinal p
                             WHERE p.bank       = COALESCE(ma.bank, mb.bank)
                               AND p.ordinal_no = COALESCE(ma.ordinal_no, mb.ordinal_no))
            AND (ma.snap IS NULL OR mb.snap IS NULL
                 OR ma.value_num IS DISTINCT FROM mb.value_num
                 OR btrim(COALESCE(ma.value_text,'')) IS DISTINCT FROM btrim(COALESCE(mb.value_text,'')))
        ) AS master_diffs
)
SELECT *,
    CASE
        WHEN a_lines = 0 AND b_lines = 0 AND a_totals = 0 AND b_totals = 0 THEN 'nothing_to_compare'
        WHEN a_lines = 0 AND b_lines > 0 THEN 'legacy_run_missing'
        WHEN b_lines = 0 AND b_totals = 0 AND a_lines > 0 THEN 'pipro_run_missing'
        WHEN b_lines = 0 AND b_totals > 0 THEN 'totals_only_available'
        WHEN master_diffs > 0 THEN 'master_differs'
        WHEN a_lines = 0 OR b_lines = 0 THEN 'totals_only_available'
        WHEN abs(a_lines - b_lines)::numeric * 100 / greatest(a_lines, b_lines)
             > COALESCE(NULLIF(:'tolerance','')::numeric, 10) THEN 'shape_differs'
        ELSE 'full_detail'
    END AS gate
FROM counts;

\echo ''
\echo '=== 0. Which period did each side actually run? ==========================='
-- Legacy PW_Runf* is simply "the last run" and is NOT guaranteed to be the same
-- period as the pipro run. If these two rows disagree, expect a wall of
-- differences and read it as a period mismatch, not an engine fault.
SELECT system, kind, period_label, period_date, taken_at
FROM compare.run_snapshot WHERE snap IN (:'a', :'b')
ORDER BY system DESC;

\echo ''
\echo '=== 0b. Gate =============================================================='
SELECT a_lines, b_lines, a_totals, b_totals, master_diffs, gate,
       CASE gate
         WHEN 'nothing_to_compare'    THEN 'Neither side has run output. Nothing has been run yet.'
         WHEN 'legacy_run_missing'    THEN 'RUN NOT DONE ON LEGACY - the experimental side has output, legacy has none.'
         WHEN 'pipro_run_missing'     THEN 'RUN NOT DONE ON EXPERIMENTAL - totals only below, no comparison possible.'
         WHEN 'totals_only_available' THEN 'Experimental has totals but no per-line output (a what-if run stores only totals). Totals compared below.'
         WHEN 'master_differs'        THEN 'EMPLOYEE MASTER DATA DIFFERS - line detail suppressed, because every figure derives from it. Fix the import first (see 92), then re-read this.'
         WHEN 'shape_differs'         THEN 'Row counts differ by more than the tolerance - the two runs are structurally different, so a row list would not be readable. Summary only.'
         ELSE 'Comparable - full per-row detail below.'
       END AS meaning
FROM _gate;

\echo ''
\echo '=== 0c. Bank legend ======================================================='
\echo '    Q = amounts.  V = the alpha bank: legacy I (indicators) maps to V at the'
\echo '    same ordinal; legacy N (refnos) maps to V+100 but is NOT in run output,'
\echo '    so every V row here is a legacy I value. There is no date bank: legacy'
\echo '    has no PW_RunfDates.'

\echo ''
\echo '=== 1. Totals - always reported ==========================================='
SELECT t.metric,
       count(*)                                        AS employees,
       sum(la.value_num)                               AS legacy_total,
       sum(pb.value_num)                               AS pipro_total,
       sum(COALESCE(pb.value_num,0) - COALESCE(la.value_num,0)) AS delta,
       count(*) FILTER (WHERE la.value_num IS DISTINCT FROM pb.value_num) AS employees_differing
FROM (SELECT DISTINCT metric FROM compare.run_total WHERE snap IN (:'a', :'b')) t
LEFT JOIN compare.run_total la ON la.snap = :'a' AND la.metric = t.metric
LEFT JOIN compare.run_total pb ON pb.snap = :'b' AND pb.metric = t.metric
                              AND pb.employee_code = la.employee_code
GROUP BY t.metric ORDER BY t.metric;

\echo ''
\echo '=== 2. Employees whose totals differ ======================================'
SELECT la.employee_code, la.metric, la.value_num AS legacy, pb.value_num AS pipro,
       COALESCE(pb.value_num,0) - la.value_num AS delta
FROM compare.run_total la
LEFT JOIN compare.run_total pb ON pb.snap = :'b' AND pb.employee_code = la.employee_code
                              AND pb.metric = la.metric
WHERE la.snap = :'a' AND la.value_num IS DISTINCT FROM pb.value_num
ORDER BY abs(COALESCE(pb.value_num,0) - la.value_num) DESC, la.employee_code
LIMIT 40;

\echo ''
\echo '=== 3. Line summary by bank ==============================================='
SELECT bank, verdict, count(*) AS rows, count(DISTINCT employee_code) AS employees
FROM compare.run_value_diff
WHERE snap_a IN (:'a','(absent)') AND snap_b IN (:'b','(absent)')
  AND (SELECT gate FROM _gate) NOT IN ('nothing_to_compare','pipro_run_missing','legacy_run_missing')
GROUP BY bank, verdict ORDER BY bank, verdict;

\echo ''
\echo '=== 4. Differing ordinals (suppressed unless the gate allows detail) ======='
SELECT bank, ordinal_no, COALESCE(a_origin, b_origin) AS origin,
       count(*) AS rows,
       sum(abs(COALESCE(delta,0))) AS total_abs_delta,
       max(abs(COALESCE(delta,0))) AS worst_delta
FROM compare.run_value_diff
WHERE verdict <> 'match' AND snap_a = :'a' AND snap_b = :'b'
  AND (SELECT gate FROM _gate) IN ('full_detail','shape_differs')
GROUP BY bank, ordinal_no, COALESCE(a_origin, b_origin)
ORDER BY rows DESC, total_abs_delta DESC
LIMIT 40;

\echo ''
\echo '=== 5. Differing rows (full detail only) =================================='
SELECT employee_code, bank, ordinal_no, a_num AS legacy, b_num AS pipro, delta, a_text, b_text, verdict
FROM compare.run_value_diff
WHERE verdict <> 'match' AND snap_a = :'a' AND snap_b = :'b'
  AND (SELECT gate FROM _gate) = 'full_detail'
ORDER BY abs(COALESCE(delta,0)) DESC NULLS LAST, employee_code, ordinal_no
LIMIT 100;

\echo ''
\echo '=== 6. Experimental lines that could not be placed on a legacy ordinal ===='
SELECT label, origin, reason, count(*) AS rows
FROM compare.run_value_unmapped WHERE snap = :'b'
GROUP BY label, origin, reason ORDER BY count(*) DESC;
