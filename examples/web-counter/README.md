# web-counter

A page that calls a program many times, keeping the state in the page. It shows
how to use `load`. It builds on `examples/web-greeter`.

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
It starts from the top on every call and remembers nothing. The page keeps the
total, passes it as `stdin` and replaces it with what `main` printed.

```js
const result = await app.run({ args: ["counter", "10"], stdin: total });
total = result.stdout.trim();
```

A value other than a number goes in as a string in the same way, for example
one value to a line. The program parses it, since the runtime has no `parse`.
A program must not depend on the instance being reused. A trap, `os/exit` or
`fresh: true` gives the next call a new one. `examples/web-errors` shows how
these can be used.

## `run` and `load`

`counter.js` exports both. They differ in what each call costs.

`run` fetches the runtime and the image, compiles the runtime, starts an
instance and calls `main`, on every call. It suits a page that runs the program
once.

```js
import { run } from "./counter.js";

const result = await run({ args: ["counter", "1"], stdin: "0" });
```

`load` does the fetch and the compile once and returns an object with `run`.
The first call to that `run` starts an instance and later calls use it. It
suits a page that calls the program again, such as on each click.

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
