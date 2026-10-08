# web-counter

A page that uses `load` to call a program repeatedly and stores state between
calls. It extends `examples/web-greeter`.

```sh
cd examples/web-counter
wattle build web
wattle ../http-server.wattle localhost 8000 zig-out/web/counter .
```

See the resulting page at `http://localhost:8000/`.

## The program

```clojure
(defn main [& args]
  (def [_ amount] args)
  (def total (or (scan-number (string/trim (file/read stdin :all))) 0))
  (print (+ total (or (scan-number amount) 0))))
```

`main` adds the number in `args` to the number on `stdin` and prints the sum.
Execution starts at `main` on every call, with no retained program state. The
page stores the total, passes it as `stdin` and updates it from the output.

```js
const result = await app.run({ args: ["counter", "10"], stdin: total });
total = result.stdout.trim();
```

Other values can also be passed as strings, for example one value per line. The
program must decode them without `parse`, which is unavailable in this runtime.
Programs must not rely on instance reuse: traps and `os/exit` require a new
instance on the next call, and `fresh: true` requests a new instance for the
current call. `examples/web-errors` demonstrates these cases.

## `run` and `load`

`counter.js` exports `run` and `load` with different startup costs.

`run` fetches the runtime and the image, compiles the runtime, starts an
instance and calls `main`, on every call. It suits a page that runs the program
once.

```js
import { run } from "./counter.js";

const result = await run({ args: ["counter", "1"], stdin: "0" });
```

`load` fetches and compiles once, then returns an object with a `run` method.
The first method call creates an instance; later calls reuse it. Use `load` for
repeated execution, such as on each click.

```js
import { load } from "./counter.js";

const app = await load();
const result = await app.run({ args: ["counter", "1"], stdin: "0" });
```

`index.html` calls `load` once, as the page opens, and enables the buttons when
it returns.

`load` and the top-level `run` take the same two options, `wasm` and `image`.
Each is a URL, defaulting to the files beside the module. Pass these when the
files are served from another path or host. The `run` that `load` returns takes
`args`, `stdin` and `fresh`.
