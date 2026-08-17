#!/usr/bin/env node
// Prunes a packaged copy of mobile/bridge before shipping: node_modules holds
// pure development artifacts (source maps, TypeScript sources, README/LICENSE/
// CHANGELOG) that the runtime never loads — together they dwarf the real code.
// Removing them shrinks the packaged bridge (macOS .app / Windows zip + MSI /
// Linux tarball) with zero runtime impact.
//
// Usage: node prune.mjs <bridge-dir>
//   Operates in place on the given directory's node_modules.
import { readdirSync, rmSync, statSync } from "node:fs";
import { join } from "node:path";

const root = process.argv[2];
if (!root) {
  console.error("usage: node prune.mjs <bridge-dir>");
  process.exit(2);
}
const nm = join(root, "node_modules");
if (!statSync(nm, { throwIfNoEntry: false })?.isDirectory()) {
  console.error(`prune.mjs: no node_modules under ${root}`);
  process.exit(1);
}

// Dev-only files to drop. Basename matcher covers README*, LICENSE*, etc. in
// any casing at any depth (case-insensitive on purpose).
const REMOVE_FILE =
  /\.map$|\.ts$|(^|[\\/])(readme|license|licence|copying|changelog|notice|authors)(\.[a-z0-9]+)?$/i;

let removed = 0;
let bytes = 0;
const walk = (dir) => {
  for (const name of readdirSync(dir)) {
    const p = join(dir, name);
    let st;
    try {
      st = statSync(p);
    } catch {
      continue; // raced with a concurrent prune — ignore
    }
    if (st.isDirectory()) {
      walk(p);
      // Drop empty directories left behind by removals.
      try {
        if (readdirSync(p).length === 0) rmSync(p, { recursive: true });
      } catch { /* ignore */ }
    } else if (REMOVE_FILE.test(name)) {
      try {
        bytes += st.size;
        rmSync(p);
        removed++;
      } catch { /* ignore */ }
    }
  }
};
walk(nm);
console.log(`prune.mjs: removed ${removed} dev-only files (~${(bytes / 1024 / 1024).toFixed(1)} MiB) from ${nm}`);
