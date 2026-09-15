// Runs `wattle-web.wasm` under Node with the page's own `wasi.js`, and checks
// what each submission writes and returns.
//
// Usage: node examples/web/test.js [path/to/wattle-web.wasm]
//
// The path defaults to `zig-out/web/wattle-web.wasm`, where `zig build examples/web`
// installs it, relative to the working directory. Exits 1 on the first
// mismatch.

import { readFileSync } from "node:fs";
import { createWasi, start } from "./wasi.js";

const path = process.argv[2] ?? "zig-out/web/wattle-web.wasm";
const module = new WebAssembly.Module(readFileSync(path));

function fail(message) {
  console.error(`FAIL: ${message}`);
  process.exit(1);
}

// The imports a Debug or ReleaseSafe build has and a ReleaseSmall or
// ReleaseFast build does not. `wasi.js` provides them for the first two.
const DEBUG_ONLY_IMPORTS = [
  "clock_res_get",
  "fd_filestat_set_size",
  "fd_filestat_set_times",
  "fd_pread",
  "fd_pwrite",
  "fd_sync",
];

// The import object provides every import, and nothing more than the
// imports of some optimize mode.
const imports = WebAssembly.Module.imports(module);
for (const { module: from, name } of imports) {
  if (from !== "wasi_snapshot_preview1") fail(`import ${from}.${name} is not from wasi_snapshot_preview1`);
}
const needed = imports.map(({ name }) => name);
const provided = Object.keys(createWasi().imports.wasi_snapshot_preview1);
const missing = needed.filter((name) => !provided.includes(name));
if (missing.length > 0) fail(`imports: wasi.js does not provide [${missing.join(", ")}]`);
const unused = provided.filter((name) => !needed.includes(name) && !DEBUG_ONLY_IMPORTS.includes(name));
if (unused.length > 0) fail(`imports: wasi.js provides [${unused.join(", ")}], which no build imports`);
console.log(`ok imports (${needed.length} of ${provided.length} provided)`);

const exports = WebAssembly.Module.exports(module).map(({ name }) => name).sort();
const expectedExports = ["_initialize", "janet_web_alloc", "janet_web_eval", "janet_web_free", "janet_web_init", "memory"];
if (exports.join() !== expectedExports.join()) fail(`exports: [${exports.join(", ")}]`);
console.log(`ok exports (${exports.length})`);

const janet = await start(module);

// Each case is a submission and what it must produce. A string matches
// exactly; a function is a predicate over the text.
const cases = [
  { source: "(+ 1 2)", status: 0, stdout: "3\n", stderr: "" },
  // State persists between calls.
  { source: "(def x 40)", status: 0, stdout: "40\n", stderr: "" },
  { source: "(+ x 2)", status: 0, stdout: "42\n", stderr: "" },
  // Both streams, one printed value per form.
  { source: '(print "out") (eprint "err")', status: 0, stdout: "out\nnil\nnil\n", stderr: "err\n" },
  // An error is reported with its stack trace, and the runtime survives it.
  {
    source: '(error "boom")',
    status: 1,
    stdout: "",
    stderr: "error: boom\n  in thunk [repl] (tail call) on line 1, column 1\n",
  },
  {
    source: "(+ x 1",
    status: 1,
    stdout: "",
    stderr: "repl:1:6: parse error: unexpected end of source, ( opened at line 1, column 1\n",
  },
  { source: "(+ x 1)", status: 0, stdout: "41\n", stderr: "" },
  // Unbounded recursion raises `stack overflow` under the web build's stack
  // ceiling rather than exhausting the heap and trapping, and the instance
  // keeps its state.
  { source: "(defn f [n] (+ 1 (f (inc n))))", status: 0, stdout: "<function f>\n", stderr: "" },
  {
    source: "(f 0)",
    status: 1,
    stdout: "",
    stderr: (text) => text.startsWith("error: stack overflow\n  in f [repl]"),
  },
  { source: "(+ x 2)", status: 0, stdout: "42\n", stderr: "" },
];

for (const expected of cases) {
  const result = janet.eval(expected.source);
  const label = JSON.stringify(expected.source);
  if (result.error) fail(`${label}: the instance stopped: ${result.error}`);
  if (result.status !== expected.status) fail(`${label}: status ${result.status}, expected ${expected.status}`);
  for (const stream of ["stdout", "stderr"]) {
    const want = expected[stream];
    const got = result[stream];
    const matches = typeof want === "function" ? want(got) : got === want;
    if (!matches) {
      const shown = got.length > 300 ? `${got.slice(0, 300)}... (${got.length} characters)` : got;
      fail(`${label}: ${stream} was ${JSON.stringify(shown)}`);
    }
  }
  console.log(`ok ${label}`);
}

console.log(`All ${cases.length} submissions matched.`);
