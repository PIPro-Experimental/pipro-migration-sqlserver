// Generate pipro tenant migrations + hop-2 import SQL for every DataDictionary
// table with copyData=true (COMPANY/PAYROLL schema types) not already in pipro.
// Usage: node generate-carry.js  (reads ./inventory.json, writes ./out/...)
const fs = require('fs');
const path = require('path');

const inv = require('./inventory.json');
const OUT = path.join(__dirname, 'out');
fs.mkdirSync(OUT, { recursive: true });

// ---------------------------------------------------------------- classification
// Already present in pipro (employees + the generic-slot store + accounts widen).
const SKIP = new Set([
  'employees', 'employee_amounts', 'settings_employee_amounts',
  'employee_dates', 'settings_employee_dates',
  'employee_precision_amounts', 'settings_employee_precision_amounts',
  'employee_alpha', 'settings_employee_alpha',
  'employee_thirdparty_payments', 'employee_accounts',
]);

const ZA = new Set([
  'settings_zaf_uif_calcs', 'settings_zaf_uif', 'settings_zaf_uif_company',
  'settings_zaf_uif_file', 'settings_zaf_uif_file_sort', 'settings_fund_coida',
  'settings_zaf_sars_company_values', 'settings_zaf_sars_company',
  'settings_zaf_sars_file', 'settings_zaf_sars_file_sort',
  'zaf_sars_print', 'zaf_sars_work', 'settings_user_zaf_southafrica',
  'equity', 'settings_equity', 'employment_tax_incentive',
  'fund_mibfa', 'fund_mibfa_header', 'fund_mibfa_other',
  'settings_apso_tax', 'settings_apso_tax_codes',
]);
const ZW = new Set(['settings_taxcodes_zwe_zimbabwe']);
const NEIGHBOUR = new Set([
  'settings_taxcodes_cod_congo', 'settings_taxcodes_gha_ghana',
  'settings_taxcodes_ken_kenya', 'settings_user_mli_mali',
  'settings_taxcodes_mus_mauritius', 'settings_user_nam_namibia',
  'settings_taxcodes_nam_namibia', 'settings_taxcodes_swz_eswatini',
  'settings_tax_certificate_swz_calcs', 'settings_tax_certificate_swz_header',
  'settings_tax_certificate_swz_eswatini',
  'settings_tax_certificate_bwa_botswana', 'settings_tax_certificate_bwa_blocks',
  'settings_tax_certificate_bwa_calcs',
  'settings_tax_certificate_lso_lesotho', 'settings_tax_certificate_lso_calcs',
]);

const TYPE_DDL = {
  BOOLEAN: 'BOOLEAN', TINYINT: 'SMALLINT', SMALLINT: 'SMALLINT',
  INTEGER: 'INTEGER', BIGINT: 'BIGINT', DOUBLE: 'DOUBLE PRECISION',
  MONEY: 'NUMERIC(19,4)', ACCURATE: 'NUMERIC(19,10)', GUESS: 'NUMERIC(9,3)',
  TEXT: 'TEXT', DATE: 'DATE', DATETIME: 'TIMESTAMP', TIMESTAMP_NOZ: 'TIMESTAMP',
  TIMESTAMP_TZ: 'TIMESTAMPTZ',
};

// pg reserved words we can't use unquoted as column names.
const RESERVED = new Set(['row', 'user', 'order', 'group', 'default', 'check',
  'primary', 'references', 'table', 'column', 'select', 'where', 'from', 'to',
  'desc', 'asc', 'limit', 'offset', 'both', 'case', 'cast', 'collate', 'do',
  'else', 'end', 'for', 'grant', 'in', 'into', 'not', 'null', 'on', 'or',
  'then', 'union', 'unique', 'using', 'when', 'with', 'all', 'and', 'any']);

function snake(raw) {
  return raw
    .replace(/([a-z0-9])([A-Z])/g, '$1_$2')
    .replace(/([A-Z]+)([A-Z][a-z])/g, '$1_$2')
    .toLowerCase()
    .replace(/__+/g, '_');
}

function targetCol(col) {
  const lower = col.name; // already lowercased original
  if (col.type === 'AUTO_KEY') return 'id';
  if (lower === 'employeeno' || lower === 'empno') return 'employee_id';
  // EmployeeId (the alpha code, = employees.EmployeeId_F01) would collide with
  // the employee_id integer link; keep pipro's name for the same concept.
  if (lower === 'employeeid') return 'employee_code';
  let s = snake(col.rawName || col.name);
  if (RESERVED.has(s)) s = s + '_no'; // e.g. settings_table_values.row -> row_no
  return s;
}

const renames = []; // audit of reserved-word renames
const stats = { tables: 0, columns: 0 };

function tableDdl(t) {
  const isPayroll = t.schemaType === 'PAYROLL';
  const hasAuto = t.columns.some(c => c.type === 'AUTO_KEY');
  const hasPayrollCol = t.columns.some(c => c.name === 'payroll');
  const keyCols = [];
  const lines = [];

  // Interim SchemaType.PAYROLL tables were scoped by schema-per-payroll; pipro
  // hosts every payroll of a tenant in one schema, so tables that had no
  // payroll column gain one as the scoping key component.
  if (isPayroll && !hasPayrollCol) {
    lines.push('    payroll        INTEGER NOT NULL');
    if (!hasAuto) keyCols.push('payroll');
  }

  for (const c of t.columns) {
    const name = targetCol(c);
    if (RESERVED.has(snake(c.rawName || c.name))) {
      renames.push(`${t.name}.${snake(c.rawName || c.name)} -> ${name}`);
    }
    if (c.type === 'AUTO_KEY') {
      lines.push('    id             INTEGER PRIMARY KEY');
      continue;
    }
    const notNull = c.keyPos > 0 && !hasAuto ? ' NOT NULL' : '';
    lines.push(`    ${name.padEnd(14)} ${TYPE_DDL[c.type]}${notNull}`);
    if (c.keyPos > 0 && !hasAuto) keyCols.push(name);
    stats.columns++;
  }

  const seen = new Set();
  for (const c of t.columns) {
    const n = targetCol(c);
    if (seen.has(n)) throw new Error(`duplicate column ${t.name}.${n}`);
    seen.add(n);
  }

  let ddl = `CREATE TABLE ${t.name} (\n` + lines.join(',\n');
  if (keyCols.length > 0 && !hasAuto) {
    ddl += `,\n    PRIMARY KEY (${keyCols.join(', ')})`;
  }
  ddl += '\n);';

  // scoping index where payroll/employee_id isn't the leading key
  const extra = [];
  if (isPayroll && hasAuto) {
    extra.push(`CREATE INDEX idx_${t.name}_payroll ON ${t.name} (payroll);`);
  }
  const empCol = t.columns.find(c => c.name === 'employeeno' || c.name === 'empno');
  if (empCol && (hasAuto || keyCols[0] !== 'employee_id')) {
    if (!(keyCols.length && keyCols.includes('employee_id') && keyCols[0] === 'employee_id')) {
      extra.push(`CREATE INDEX idx_${t.name}_employee ON ${t.name} (employee_id);`);
    }
  }
  stats.tables++;
  return { ddl, extra, hasAuto, keyCols, isPayroll, hasPayrollCol };
}

function importSql(t) {
  const isPayroll = t.schemaType === 'PAYROLL';
  const hasAuto = t.columns.some(c => c.type === 'AUTO_KEY');
  const hasPayrollCol = t.columns.some(c => c.name === 'payroll');
  const hasEmp = t.columns.some(c => c.name === 'employeeno' || c.name === 'empno');
  const tgtCols = [];
  const selCols = [];
  const keyCols = [];

  if (isPayroll && !hasPayrollCol) {
    tgtCols.push('payroll');
    selCols.push(`:payroll_number`);
    if (!hasAuto) keyCols.push('payroll');
  }
  for (const c of t.columns) {
    const tgt = targetCol(c);
    tgtCols.push(tgt);
    if (c.type === 'AUTO_KEY') {
      selCols.push(`s.${c.name}`); // carry source identity; sequence resynced below
      continue;
    }
    if (tgt === 'employee_id') { selCols.push('e.user_id'); }
    else selCols.push(`s.${c.name}`);
    if (c.keyPos > 0 && !hasAuto) keyCols.push(tgt);
  }

  let sql = `INSERT INTO ${t.name} (${tgtCols.join(', ')})\n`;
  sql += `SELECT ${selCols.join(', ')}\nFROM :"legacy_schema".${t.name} s`;
  if (hasEmp) sql += `\nJOIN employees e ON e.id = 'emp-' || s.employeeno::text`;
  if (hasAuto) sql += `\nON CONFLICT (id) DO NOTHING;`;
  else if (keyCols.length) sql += `\nON CONFLICT (${keyCols.join(', ')}) DO NOTHING;`;
  else sql += ';';

  if (hasAuto) {
    sql += `\nSELECT setval(pg_get_serial_sequence('${t.name}', 'id'), (SELECT COALESCE(MAX(id), 0) + 1 FROM ${t.name}), false);`;
  }
  return sql;
}

// ---------------------------------------------------------------- emit
const groups = { core: [], neighbour: [], za: [], zw: [] };
for (const t of inv) {
  if (!t.copyData) continue;
  if (t.schemaType !== 'COMPANY' && t.schemaType !== 'PAYROLL') continue; // SYSTEM falls away
  if (SKIP.has(t.name)) continue;
  if (ZA.has(t.name)) groups.za.push(t);
  else if (ZW.has(t.name)) groups.zw.push(t);
  else if (NEIGHBOUR.has(t.name)) groups.neighbour.push(t);
  else groups.core.push(t);
}

function emitMigration(tables, header) {
  const parts = [header.trimEnd(), ''];
  const identity = [];
  for (const t of tables) {
    const r = tableDdl(t);
    const legacy = t.legacy.length ? t.legacy.join(', ') : t.name;
    parts.push(`-- ${t.name}  (interim <- ${legacy})`);
    parts.push(r.ddl);
    for (const e of r.extra) parts.push(e);
    parts.push('');
    if (r.hasAuto) identity.push(t.name);
    // structural duplicates (same DDL, different name, never populated by import)
    for (const dup of t.duplicate || []) {
      parts.push(`-- ${dup}: structural duplicate of ${t.name} (DataDictionary setDuplicate)`);
      parts.push(r.ddl.replace(`CREATE TABLE ${t.name} (`, `CREATE TABLE ${dup} (`));
      parts.push('');
    }
  }
  return { sql: parts.join('\n'), identity };
}

function identityMigration(tables) {
  const parts = [
    '-- Convert the legacy-carry identity keys to BIGINT IDENTITY (BY DEFAULT, so',
    '-- the hop-2 import can still insert explicit ids; it resyncs the sequence',
    '-- afterwards). SQLite branch: INTEGER PK is already a rowid alias, no-op.',
    '',
  ];
  for (const name of tables) {
    parts.push(`ALTER TABLE ${name} ALTER COLUMN id TYPE BIGINT;`);
    parts.push(`ALTER TABLE ${name} ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY;`);
    parts.push('');
  }
  return parts.join('\n');
}

const H = (title, extra) => `-- ${title}
--
-- GENERATED from petervm_pipro_java DataDictionary.java (copyData = true) by
-- pipro-migration-sqlserver/tools/generate-carry.js — edit the generator, not
-- this file, if the mapping rules change.
--
-- Cleanups applied mechanically to every table (see legacy-carry-manifest.md):
--   * column names snake_cased; EmployeeNo -> employee_id (the pipro user_id);
--     AUTO_KEY columns -> id; reserved words suffixed (_no)
--   * interim SchemaType.PAYROLL tables gain a payroll INTEGER scoping column
--     where they had none (interim scoped them schema-per-payroll)
--   * money stays NUMERIC(19,4) / (19,10) / (9,3) — NOT minor units; these are
--     legacy-carry tables and conversion would be lossy for 4dp values
${extra ? '--\n' + extra : '--'}
`;

const core = emitMigration(groups.core, H(
  'Legacy-carry: country-agnostic interim tables (DataDictionary copyData set)',
  `-- Includes the run_history family AS-IS for now — the run-table redesign is an
-- open discussion; this preserves the data so that discussion isn't gated on it.`));
const neighbour = emitMigration(groups.neighbour, H(
  'Legacy-carry: neighbour-country settings tables (no pipro country pack yet)',
  `-- Botswana / Congo / Ghana / Kenya / Lesotho / Mali / Mauritius / Namibia /
-- Eswatini. Data preserved here until (if ever) these get country packs.`));
const za = emitMigration(groups.za, H('Legacy-carry: South Africa interim tables (DataDictionary copyData set)'));
const zw = emitMigration(groups.zw, H('Legacy-carry: Zimbabwe interim tables (DataDictionary copyData set)'));

fs.writeFileSync(path.join(OUT, '2026_07_23_100000_legacy_carry_core.sql'), core.sql);
if (core.identity.length) fs.writeFileSync(path.join(OUT, '2026_07_23_100100_legacy_carry_core_identity.pgsql.sql'), identityMigration(core.identity));
fs.writeFileSync(path.join(OUT, '2026_07_23_110000_legacy_carry_neighbour_countries.sql'), neighbour.sql);
if (neighbour.identity.length) fs.writeFileSync(path.join(OUT, '2026_07_23_110100_legacy_carry_neighbour_identity.pgsql.sql'), identityMigration(neighbour.identity));
fs.writeFileSync(path.join(OUT, '2026_07_23_100000_legacy_carry_za.sql'), za.sql);
if (za.identity.length) fs.writeFileSync(path.join(OUT, '2026_07_23_100100_legacy_carry_za_identity.pgsql.sql'), identityMigration(za.identity));
fs.writeFileSync(path.join(OUT, '2026_07_23_100000_legacy_carry_zw.sql'), zw.sql);
if (zw.identity.length) fs.writeFileSync(path.join(OUT, '2026_07_23_100100_legacy_carry_zw_identity.pgsql.sql'), identityMigration(zw.identity));

// ---------------------------------------------------------------- hop-2 import
function emitImport(tables, fileTitle, note) {
  const parts = [`-- ===========================================================================
-- ${fileTitle}
-- GENERATED by tools/generate-carry.js — edit the generator, not this file.
-- Run ONCE PER TENANT after 10_employees.sql (employee ids must exist).
-- Runner variables: :legacy_schema :tenant_schema :payroll_number
--
-- Source identifiers are UNQUOTED LOWERCASE: DataDictionary's ColumnCollection
-- lowercases every table/column name, so that is what the desktop DB contains.
${note ? '-- ' + note + '\n' : ''}-- ===========================================================================
\\set ON_ERROR_STOP on
BEGIN;
SET search_path TO :"tenant_schema", public;
`];
  for (const t of tables) {
    parts.push(`-- ---- ${t.name} ----`);
    parts.push(importSql(t));
    parts.push('');
  }
  parts.push('COMMIT;');
  parts.push(`\\echo 'Done (${fileTitle.split(' ')[0]}):' :tenant_schema '<-' :legacy_schema`);
  return parts.join('\n');
}

const companyTables = [...groups.core, ...groups.neighbour, ...groups.za, ...groups.zw].filter(t => t.schemaType === 'COMPANY');
const payrollTables = [...groups.core, ...groups.neighbour, ...groups.za, ...groups.zw].filter(t => t.schemaType === 'PAYROLL');
fs.writeFileSync(path.join(OUT, '50_legacy_carry_company.sql'),
  emitImport(companyTables, '50_legacy_carry_company.sql — interim COMPANY-schema tables'));
fs.writeFileSync(path.join(OUT, '55_legacy_carry_payroll.sql'),
  emitImport(payrollTables, '55_legacy_carry_payroll.sql — interim PAYROLL-schema tables',
    'CONFIRM: :payroll_number fills the payroll scoping column where the interim table had none (migration_map.legacy_payroll_number).'));

// ---------------------------------------------------------------- manifest
const man = [];
man.push('# Legacy-carry manifest', '');
man.push(`Generated ${''}from DataDictionary.java. copyData=true tables: ${inv.filter(t => t.copyData).length}; in scope (COMPANY/PAYROLL): ${companyTables.length + payrollTables.length + SKIP.size - 0}.`, '');
man.push('| table | schemaType | module | keys | auto-id | notes |');
man.push('|---|---|---|---|---|---|');
for (const [mod, list] of Object.entries(groups)) {
  for (const t of list) {
    const keys = t.columns.filter(c => c.keyPos > 0).map(c => targetCol(c)).join(', ');
    const auto = t.columns.some(c => c.type === 'AUTO_KEY') ? 'yes' : '';
    const addP = t.schemaType === 'PAYROLL' && !t.columns.some(c => c.name === 'payroll') ? '+payroll col' : '';
    man.push(`| ${t.name} | ${t.schemaType} | ${mod} | ${keys} | ${auto} | ${addP} |`);
  }
}
man.push('', '## Skipped (already in pipro / handled separately)', '');
for (const s of [...SKIP]) man.push(`- ${s}`);
man.push('', '## Reserved-word renames', '');
for (const r of [...new Set(renames)]) man.push(`- ${r}`);
fs.writeFileSync(path.join(OUT, 'legacy-carry-manifest.md'), man.join('\n'));

console.log('tables emitted:', stats.tables, ' columns:', stats.columns);
console.log('core:', groups.core.length, ' neighbour:', groups.neighbour.length, ' za:', groups.za.length, ' zw:', groups.zw.length);
console.log('identity tables:', [core, neighbour, za, zw].flatMap(g => g.identity).join(', '));
console.log('renames:', [...new Set(renames)].join('; ') || 'none');
