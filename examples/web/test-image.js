// Runs an image under a `wattle-web.wasm` built with `-Dwasm-image`, and
// checks what loading it writes.
//
// Usage: node examples/web/test-image.js <wasm> <image> <expected-stdout> [expected-stderr]
//
// `image` is a file `wattle build img` made. The test exits 1 on the first
// mismatch. It needs Node 22.7 or later, as `test.js` does.

import { readFileSync } from "node:fs";
import { start } from "../../src/client/web/wasi.js";

const [wasmPath, imagePath, stdout, stderr = ""] = process.argv.slice(2);
if (!imagePath || stdout === undefined) {
  console.error("usage: node examples/web/test-image.js <wasm> <image> <expected-stdout> [expected-stderr]");
  process.exit(2);
}

function fail(message) {
  console.error(`FAIL: ${message}`);
  process.exit(1);
}

const module = new WebAssembly.Module(readFileSync(wasmPath));
const exports = WebAssembly.Module.exports(module).map(({ name }) => name).sort();
const expectedExports = ["_initialize", "memory", "wattle_web_alloc", "wattle_web_free", "wattle_web_init", "wattle_web_run_image"];
if (exports.join() !== expectedExports.join()) fail(`exports: [${exports.join(", ")}]`);
console.log(`ok exports (${exports.length})`);

const wattle = await start(module);
const unescape = (text) => text.replaceAll("\\n", "\n");
const cases = [
  // The image runs.
  { bytes: readFileSync(imagePath), status: 0, stdout: unescape(stdout), stderr: unescape(stderr) },
  // The instance survives running it, and loads another.
  { bytes: readFileSync(imagePath), status: 0, stdout: unescape(stdout), stderr: unescape(stderr) },
  // Bytes that are not an image raise from `unmarshal`, and the instance survives.
  { bytes: new TextEncoder().encode("(+ 1 2)"), status: 1, stdout: "", stderr: (text) => text.startsWith("error: ") },
  { bytes: readFileSync(imagePath), status: 0, stdout: unescape(stdout), stderr: unescape(stderr) },
];

for (const [index, expected] of cases.entries()) {
  const result = wattle.runImage(expected.bytes);
  if (result.error) fail(`case ${index}: the instance stopped: ${result.error}`);
  if (result.status !== expected.status) fail(`case ${index}: status ${result.status}, expected ${expected.status}: ${result.stderr}`);
  for (const stream of ["stdout", "stderr"]) {
    const want = expected[stream];
    const got = result[stream];
    const matches = typeof want === "function" ? want(got) : got === want;
    if (!matches) fail(`case ${index}: ${stream} was ${JSON.stringify(got)}`);
  }
  console.log(`ok case ${index}`);
}

console.log(`All ${cases.length} cases matched.`);
