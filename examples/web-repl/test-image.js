// Runs images under a `wattle-web.wasm` built with `-Dwasm-image`, and checks
// what each call writes and returns.
//
// Usage: node examples/web-repl/test-image.js <wasm> <hello-image> <echo-image>
//
// `hello-image` is made from `hello.wattle` and `echo-image` from
// `echo.wattle`, each with `wattle build img`. One instance runs every case,
// so a case also checks that the instance survives the one before it. The test
// exits 1 on the first mismatch. It needs Node 22.7 or later, as `test.js`
// does.

import { readFileSync } from "node:fs";
import { start } from "../../src/client/web/wasi.js";

const [wasmPath, helloPath, echoPath] = process.argv.slice(2);
if (!echoPath) {
  console.error("usage: node examples/web-repl/test-image.js <wasm> <hello-image> <echo-image>");
  process.exit(2);
}

function fail(message) {
  console.error(`FAIL: ${message}`);
  process.exit(1);
}

const module = new WebAssembly.Module(readFileSync(wasmPath));
const exports = WebAssembly.Module.exports(module).map(({ name }) => name).sort();
const expectedExports = ["__stack_pointer", "_initialize", "memory", "wattle_web_alloc", "wattle_web_free", "wattle_web_init", "wattle_web_run_image"];
if (exports.join() !== expectedExports.join()) fail(`exports: [${exports.join(", ")}]`);
console.log(`ok exports (${exports.length})`);

const wattle = await start(module);
const hello = readFileSync(helloPath);
const echo = readFileSync(echoPath);

const helloOut = "hello from image\nsum 6\n";
const cases = [
  { label: "hello", image: hello, status: 0, stdout: helloOut, stderr: "to stderr\n" },
  // The arguments reach `main` as they are, and standard input is read to its end.
  {
    label: "args and stdin",
    image: echo,
    options: { args: ["prog", "a b", "c"], stdin: "héllo\nworld" },
    status: 0,
    stdout: "prog|a b|c\nstdin: héllo\nworld\n",
    stderr: "",
  },
  // The same instance again, with other input: standard input starts over.
  { label: "second input", image: echo, options: { args: ["prog"], stdin: "x" }, status: 0, stdout: "prog\nstdin: x\n", stderr: "" },
  // No arguments and no input.
  { label: "no options", image: echo, status: 0, stdout: "\nstdin: \n", stderr: "" },
  // Bytes as input.
  {
    label: "bytes",
    image: echo,
    options: { stdin: new Uint8Array([104, 105]) },
    status: 0,
    stdout: "\nstdin: hi\n",
    stderr: "",
  },
  // A raise in `main` gives status 1 and a trace, and the instance survives.
  {
    label: "error",
    image: echo,
    options: { args: ["prog", "--fail"] },
    status: 1,
    stdout: "prog|--fail\nstdin: \n",
    stderr: (text) => text.startsWith("error: failed\n"),
  },
  // Bytes that are not an image raise from `unmarshal`.
  {
    label: "not an image",
    image: new TextEncoder().encode("(+ 1 2)"),
    status: 1,
    stdout: "",
    stderr: (text) => text.startsWith("error: "),
  },
  { label: "hello again", image: hello, status: 0, stdout: helloOut, stderr: "to stderr\n" },
];

for (const expected of cases) {
  const result = wattle.runImage(expected.image, expected.options);
  const label = expected.label;
  if (result.error) fail(`${label}: the instance stopped: ${result.error}`);
  if (result.status !== expected.status) fail(`${label}: status ${result.status}, expected ${expected.status}: ${result.stderr}`);
  for (const stream of ["stdout", "stderr"]) {
    const want = expected[stream];
    const got = result[stream];
    const matches = typeof want === "function" ? want(got) : got === want;
    if (!matches) fail(`${label}: ${stream} was ${JSON.stringify(got)}`);
  }
  console.log(`ok ${label}`);
}

// `os/exit` ends the instance. The call that exits returns the exit code as its
// status, with the exception as its error, and the next call throws.
for (const code of [0, 3]) {
  const exiting = await start(module);
  const result = exiting.runImage(echo, { args: ["prog", `--exit=${code}`] });
  if (result.status !== code) fail(`exit ${code}: status ${result.status}`);
  if (result.error?.name !== "WasiExit" || result.error.code !== code) fail(`exit ${code}: error was ${result.error}`);
  if (result.stdout !== `prog|--exit=${code}\nstdin: \n`) fail(`exit ${code}: stdout was ${JSON.stringify(result.stdout)}`);
  let threw = false;
  try {
    exiting.runImage(echo);
  } catch {
    threw = true;
  }
  if (!threw) fail(`exit ${code}: a stopped instance ran another call`);
  console.log(`ok exit ${code}`);
}

console.log(`All ${cases.length} cases and 2 exits matched.`);
