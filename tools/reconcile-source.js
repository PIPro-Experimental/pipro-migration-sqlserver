// Compare the DataDictionary-derived inventory against the ACTUAL desktop
// schemas (source-columns.csv from information_schema) and report drift:
//   - dictionary columns missing on the desktop  -> import emits NULL
//   - desktop columns absent from the dictionary -> NOT carried (data-loss list!)
//   - whole tables missing either side
// Usage: node reconcile-source.js   (expects ./inventory.json + ./source-columns.csv)
const fs = require('fs');
const path = require('path');

const inv = require('./inventory.json');
const rows = fs.readFileSync(path.join(__dirname, 'source-columns.csv'), 'utf8')
  .split(/\r?\n/).filter(Boolean).map(l => l.split(','));

const actual = {}; // table -> Set(columns); schemas merged (names don't overlap in scope)
for (const [schema, table, col] of rows) {
  (actual[table] ??= new Set()).add(col);
}

const inScope = inv.filter(t => t.copyData && (t.schemaType === 'COMPANY' || t.schemaType === 'PAYROLL'));
let missingTables = [], report = [];
for (const t of inScope) {
  const act = actual[t.name];
  if (!act) { missingTables.push(t.name); continue; }
  const expected = t.columns.map(c => c.name); // lowercased dictionary names = desktop names
  const missing = expected.filter(c => !act.has(c));
  const extra = [...act].filter(c => !expected.includes(c) && c !== '_updated_on');
  if (missing.length || extra.length) {
    report.push({ table: t.name, schemaType: t.schemaType, missing_on_desktop: missing, extra_on_desktop: extra });
  }
}
console.log('tables in scope:', inScope.length);
console.log('tables MISSING on desktop:', missingTables.join(', ') || 'none');
console.log('');
for (const r of report) {
  console.log(`${r.table} (${r.schemaType})`);
  if (r.missing_on_desktop.length) console.log('   dict-only (import as NULL): ' + r.missing_on_desktop.join(', '));
  if (r.extra_on_desktop.length) console.log('   desktop-only (NOT carried!): ' + r.extra_on_desktop.join(', '));
}
fs.writeFileSync(path.join(__dirname, 'drift-report.json'), JSON.stringify({ missingTables, report }, null, 1));
