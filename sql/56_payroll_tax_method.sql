-- ===========================================================================
-- 56_payroll_tax_method.sql — the payroll's tax method from legacy's CumTaxInd.
-- Run after 55 (which carries settings_user_tax into the tenant). Re-runnable.
--
-- WHY: legacy chooses the tax routine from PW_Parm_PayrollUser.CumTaxInd ('Y' =
-- cumulative: Pay020 gblnCumulative_Tax, which selects the RSA cumulative tax
-- routine, the only one that applies the medical aid tax credit). pipro's engine
-- reads the payroll's tax_method instead, which defaults to 'non_cumulative', so
-- a cumulative legacy payroll was taxed non-cumulatively (airplane: tax 6% high).
--
--   cum_tax_ind true          -> 'cumulative'
--   cum_tax_ind false / NULL  -> 'non_cumulative'
--
-- A tenant without the legacy row keeps whatever tax_method it has.
-- Runner variables: :tenant_schema :target_payroll_id :payroll_number
-- ===========================================================================
\set ON_ERROR_STOP on
BEGIN;
SET search_path TO :"tenant_schema", public;

UPDATE payrolls p
   SET tax_method = CASE WHEN t.cum_tax_ind IS TRUE THEN 'cumulative' ELSE 'non_cumulative' END
  FROM settings_user_tax t
 WHERE p.id = :target_payroll_id
   AND t.payroll = :payroll_number;

SELECT id, tax_method FROM payrolls WHERE id = :target_payroll_id;

COMMIT;
\echo 'Done (56_payroll_tax_method.sql):' :tenant_schema 'payroll' :target_payroll_id
