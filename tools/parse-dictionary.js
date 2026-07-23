// Parse DataDictionary.java into a JSON inventory of tables + columns.
// Usage: node parse-dictionary.js <path-to-DataDictionary.java> > inventory.json
const fs = require('fs');

const src = fs.readFileSync(process.argv[2], 'utf8');
const lines = src.split(/\r?\n/);

const tables = [];
let cur = null;

// Matches: table.columns.add( ...args... )  with optional chained calls after.
const addRe = /table\.columns\.add\((.*)\)\s*(?:\.(\w+)\(([^)]*)\))?\s*;/;

function splitArgs(s) {
  // split top-level commas, respecting quotes
  const args = [];
  let depth = 0, inStr = false, curArg = '';
  for (let i = 0; i < s.length; i++) {
    const c = s[i];
    if (inStr) {
      curArg += c;
      if (c === '"' && s[i - 1] !== '\\') inStr = false;
      continue;
    }
    if (c === '"') { inStr = true; curArg += c; continue; }
    if (c === '(') depth++;
    if (c === ')') depth--;
    if (c === ',' && depth === 0) { args.push(curArg.trim()); curArg = ''; continue; }
    curArg += c;
  }
  if (curArg.trim() !== '') args.push(curArg.trim());
  return args;
}

for (let i = 0; i < lines.length; i++) {
  const line = lines[i];
  let m;

  if ((m = line.match(/getNewRecord\("([^"]+)"\)/))) {
    cur = {
      name: m[1].toLowerCase(), line: i + 1, legacy: [], duplicate: [],
      schemaType: 'UNKNOWN', createTable: false, copyData: false,
      populateFromFirstValidSource: false, parseOrdinalFromFieldNameRight: 0,
      recordKey: null, columns: [],
    };
    tables.push(cur);
    continue;
  }
  if (!cur) continue;

  if ((m = line.match(/table\.setLegacy\("([^"]*)"\)/))) {
    cur.legacy = m[1].toLowerCase().split(',').map(s => s.trim()).filter(Boolean);
  } else if ((m = line.match(/table\.setDuplicate\("([^"]*)"\)/))) {
    cur.duplicate = m[1].toLowerCase().split(',').map(s => s.trim()).filter(Boolean);
  } else if ((m = line.match(/table\.schemaType = SchemaType\.(\w+)/))) {
    cur.schemaType = m[1];
  } else if ((m = line.match(/table\.createTable = (true|false)/))) {
    cur.createTable = m[1] === 'true';
  } else if ((m = line.match(/table\.copyData = (true|false)/))) {
    cur.copyData = m[1] === 'true';
  } else if (line.match(/table\.populateFromFirstValidSource = true/)) {
    cur.populateFromFirstValidSource = true;
  } else if ((m = line.match(/table\.parseOrdinalFromFieldNameRight = (\d+)/))) {
    cur.parseOrdinalFromFieldNameRight = Number(m[1]);
  } else if ((m = line.match(/table\.recordKey = (.*);/))) {
    cur.recordKey = m[1].trim();
  } else if ((m = line.match(addRe))) {
    const args = splitArgs(m[1]);
    const col = { name: null, legacy: null, type: null, keyPos: 0, defValue: null, chain: null };
    // arg patterns: name is always first string; DataType.X somewhere; optional
    // second string BEFORE DataType = legacy; string AFTER DataType = default;
    // int after DataType = keyPos.
    let seenType = false;
    for (const a of args) {
      const strM = a.match(/^"(.*)"$/);
      const typeM = a.match(/^DataType\.(\w+)$/);
      if (typeM) { col.type = typeM[1]; seenType = true; continue; }
      if (strM) {
        if (!seenType) {
          if (col.name === null) { col.name = strM[1].toLowerCase(); col.rawName = strM[1]; }
          else col.legacy = strM[1].toLowerCase();
        } else {
          col.defValue = strM[1];
        }
        continue;
      }
      if (/^\d+$/.test(a) && seenType) { col.keyPos = Number(a); continue; }
    }
    if (m[2]) col.chain = `${m[2]}(${m[3]})`;
    if (col.type === 'AUTO_KEY') col.keyPos = 1;
    cur.columns.push(col);
  }
}

process.stdout.write(JSON.stringify(tables, null, 1));
