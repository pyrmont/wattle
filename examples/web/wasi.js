// The WASI imports `janet-web.wasm` needs, and the calls a host makes to run
// Janet source in it.
//
// A browser has no WASI, so the page supplies `wasi_snapshot_preview1` as a
// JavaScript object. It provides the 32 functions a Debug or ReleaseSafe
// build imports. ReleaseSmall and ReleaseFast builds import 26 of them, all
// but `clock_res_get`, `fd_filestat_set_size`, `fd_filestat_set_times`,
// `fd_pread`, `fd_pwrite` and `fd_sync`. `test.js` fails when the binary
// imports a function missing here. Nothing here reaches a file
// system, an environment or a clock beyond the page's own: descriptors 0, 1
// and 2 are the only open ones, output on 1 and 2 is collected per call, and
// standard input is at end of file.
//
// The same file runs under Node, which is how `test.js` exercises what the
// page runs. It uses only `WebAssembly`, `TextEncoder`, `TextDecoder`,
// `performance` and `crypto.getRandomValues`, which both provide.

// WASI errno values.
const SUCCESS = 0;
const EBADF = 8;
const EINVAL = 28;
const ENOSYS = 52;
const ESPIPE = 70;

// WASI clock ids.
const CLOCK_REALTIME = 0;
const CLOCK_MONOTONIC = 1;
const CLOCK_PROCESS_CPUTIME = 2;
const CLOCK_THREAD_CPUTIME = 3;

// The file type and the two rights `fd_fdstat_get` reports.
const FILETYPE_CHARACTER_DEVICE = 2;
const RIGHT_FD_READ = 1n << 1n;
const RIGHT_FD_WRITE = 1n << 6n;

// `crypto.getRandomValues` refuses more than this many bytes per call.
const RANDOM_CHUNK = 65536;

// Thrown by `proc_exit`, which must not return. `code` is the exit status.
export class WasiExit extends Error {
  constructor(code) {
    super(`exited with status ${code}`);
    this.name = "WasiExit";
    this.code = code;
  }
}

// Returns the import object and the two things the host does with it:
// `bind`, given the instance's memory once it exists, and `take`, which
// returns and clears the output collected since the last `take`.
export function createWasi() {
  let memory = null;
  const decoders = { 1: new TextDecoder(), 2: new TextDecoder() };
  const chunks = { 1: [], 2: [] };

  // A fresh view per call, because growing the memory replaces its buffer.
  const view = () => new DataView(memory.buffer);
  const bytes = (ptr, len) => new Uint8Array(memory.buffer, ptr, len);
  const isStdio = (fd) => fd === 0 || fd === 1 || fd === 2;

  const wasi = {
    // No environment variables: a count of zero and a size of zero.
    environ_sizes_get(countPtr, sizePtr) {
      view().setUint32(countPtr, 0, true);
      view().setUint32(sizePtr, 0, true);
      return SUCCESS;
    },
    environ_get() {
      return SUCCESS;
    },

    // Nanoseconds. Real time from `Date.now`, and the monotonic clock from
    // `performance.now`. A page has no CPU-time clock, so the two CPU-time
    // clocks read the monotonic one. `precision` is a BigInt and is ignored.
    clock_time_get(id, precision, timePtr) {
      let ns;
      if (id === CLOCK_REALTIME) {
        ns = BigInt(Date.now()) * 1000000n;
      } else if (id === CLOCK_MONOTONIC || id === CLOCK_PROCESS_CPUTIME || id === CLOCK_THREAD_CPUTIME) {
        ns = BigInt(Math.round(performance.now() * 1e6));
      } else {
        return EINVAL;
      }
      view().setBigUint64(timePtr, ns, true);
      return SUCCESS;
    },
    // A millisecond for `Date.now`, and a microsecond for `performance.now`,
    // which a browser may coarsen further.
    clock_res_get(id, resolutionPtr) {
      let ns;
      if (id === CLOCK_REALTIME) {
        ns = 1000000n;
      } else if (id === CLOCK_MONOTONIC || id === CLOCK_PROCESS_CPUTIME || id === CLOCK_THREAD_CPUTIME) {
        ns = 1000n;
      } else {
        return EINVAL;
      }
      view().setBigUint64(resolutionPtr, ns, true);
      return SUCCESS;
    },

    // Descriptors 0, 1 and 2 report a character device that cannot seek,
    // which is what wasi-libc's `isatty` tests for, so standard output is
    // line-buffered as it is on a terminal. The rights are the ones `fcntl`
    // reads the access mode from. Any error here would also start the
    // runtime, with standard output fully buffered instead.
    fd_fdstat_get(fd, statPtr) {
      if (!isStdio(fd)) return EBADF;
      const v = view();
      v.setUint8(statPtr, FILETYPE_CHARACTER_DEVICE);
      v.setUint16(statPtr + 2, 0, true);
      v.setBigUint64(statPtr + 8, fd === 0 ? RIGHT_FD_READ : RIGHT_FD_WRITE, true);
      v.setBigUint64(statPtr + 16, 0n, true);
      return SUCCESS;
    },
    fd_fdstat_set_flags(fd) {
      return isStdio(fd) ? ENOSYS : EBADF;
    },
    fd_filestat_get(fd) {
      return isStdio(fd) ? ENOSYS : EBADF;
    },

    // No descriptor is a preopened directory. wasi-libc's constructor, run by
    // `_initialize`, asks from descriptor 3 upwards and stops at EBADF. Any
    // other error, ENOSYS included, makes it exit with status 71 before
    // `janet_web_init` is called. With no preopens, wasi-libc fails every
    // relative path itself, so the `path_*` calls below are not reached.
    fd_prestat_get() {
      return EBADF;
    },
    fd_prestat_dir_name() {
      return EBADF;
    },

    // Standard input is at end of file: zero bytes read.
    fd_read(fd, iovsPtr, iovsLen, readPtr) {
      if (fd !== 0) return EBADF;
      view().setUint32(readPtr, 0, true);
      return SUCCESS;
    },

    // Descriptors 1 and 2 append to the output `take` returns. Nothing
    // touches the page here: a stack trace can run to hundreds of thousands
    // of writes.
    fd_write(fd, iovsPtr, iovsLen, writtenPtr) {
      if (fd !== 1 && fd !== 2) return EBADF;
      const v = view();
      let written = 0;
      for (let i = 0; i < iovsLen; i++) {
        const ptr = v.getUint32(iovsPtr + i * 8, true);
        const len = v.getUint32(iovsPtr + i * 8 + 4, true);
        chunks[fd].push(decoders[fd].decode(bytes(ptr, len), { stream: true }));
        written += len;
      }
      v.setUint32(writtenPtr, written, true);
      return SUCCESS;
    },

    // A terminal cannot seek, and the rest do not apply to one.
    fd_seek(fd) {
      return isStdio(fd) ? ESPIPE : EBADF;
    },
    fd_pread(fd) {
      return isStdio(fd) ? ESPIPE : EBADF;
    },
    fd_pwrite(fd) {
      return isStdio(fd) ? ESPIPE : EBADF;
    },
    fd_filestat_set_size(fd) {
      return isStdio(fd) ? ENOSYS : EBADF;
    },
    fd_filestat_set_times(fd) {
      return isStdio(fd) ? ENOSYS : EBADF;
    },
    fd_sync(fd) {
      return isStdio(fd) ? ENOSYS : EBADF;
    },
    fd_readdir(fd) {
      return isStdio(fd) ? ENOSYS : EBADF;
    },
    fd_close(fd) {
      return isStdio(fd) ? ENOSYS : EBADF;
    },

    // There is no file system. wasi-libc does not reach these (see
    // `fd_prestat_get`); they are here because the binary imports them.
    path_create_directory: () => ENOSYS,
    path_filestat_get: () => ENOSYS,
    path_filestat_set_times: () => ENOSYS,
    path_link: () => ENOSYS,
    path_open: () => ENOSYS,
    path_readlink: () => ENOSYS,
    path_remove_directory: () => ENOSYS,
    path_rename: () => ENOSYS,
    path_symlink: () => ENOSYS,
    path_unlink_file: () => ENOSYS,

    // Returns at once with every subscription reported as having fired, so
    // `os/sleep` does not wait: a page cannot block. A subscription is 48
    // bytes with its userdata at 0 and its type at 8; an event is 32 bytes
    // with the userdata at 0, the error at 8 and the type at 10.
    poll_oneoff(inPtr, outPtr, count, eventsPtr) {
      if (count === 0) return EINVAL;
      const v = view();
      for (let i = 0; i < count; i++) {
        const sub = inPtr + i * 48;
        const event = outPtr + i * 32;
        bytes(event, 32).fill(0);
        v.setBigUint64(event, v.getBigUint64(sub, true), true);
        v.setUint16(event + 8, SUCCESS, true);
        v.setUint8(event + 10, v.getUint8(sub + 8));
      }
      v.setUint32(eventsPtr, count, true);
      return SUCCESS;
    },

    // Unwinds the call into the instance, which cannot continue.
    proc_exit(code) {
      throw new WasiExit(code);
    },

    random_get(bufPtr, len) {
      for (let at = 0; at < len; at += RANDOM_CHUNK) {
        crypto.getRandomValues(bytes(bufPtr + at, Math.min(RANDOM_CHUNK, len - at)));
      }
      return SUCCESS;
    },
  };

  return {
    imports: { wasi_snapshot_preview1: wasi },
    bind(instanceMemory) {
      memory = instanceMemory;
    },
    take() {
      const out = { stdout: "", stderr: "" };
      for (const [fd, key] of [[1, "stdout"], [2, "stderr"]]) {
        chunks[fd].push(decoders[fd].decode());
        out[key] = chunks[fd].join("");
        chunks[fd] = [];
      }
      return out;
    },
  };
}

// Instantiates `module`, a compiled `janet-web.wasm`, and starts the runtime.
//
// Returns an object whose `eval(source)` runs one submission and returns
// `{ status, stdout, stderr, error }`: `status` is 0, or 1 when the
// submission failed, and `error` is null, or the exception that stopped the
// instance (a `WebAssembly.RuntimeError` for a trap, a `WasiExit` for
// `os/exit`). After an `error`, the instance is unusable and `eval` throws;
// the host starts a new one. Throws when `janet_web_init` fails.
export async function start(module) {
  const wasi = createWasi();
  const instance = await WebAssembly.instantiate(module, wasi.imports);
  const exports = instance.exports;
  wasi.bind(exports.memory);
  exports._initialize();
  const initStatus = exports.janet_web_init();
  const initOutput = wasi.take();
  if (initStatus !== 0) {
    throw new Error(`janet_web_init returned ${initStatus}: ${initOutput.stderr}`);
  }

  const encoder = new TextEncoder();
  let stopped = null;

  return {
    eval(source) {
      if (stopped) throw new Error("the instance has stopped", { cause: stopped });
      const encoded = encoder.encode(source);
      const ptr = exports.janet_web_alloc(encoded.length);
      if (ptr === 0) throw new Error(`could not allocate ${encoded.length} bytes`);
      new Uint8Array(exports.memory.buffer, ptr, encoded.length).set(encoded);
      let status = 1;
      try {
        status = exports.janet_web_eval(ptr, encoded.length);
        exports.janet_web_free(ptr, encoded.length);
      } catch (error) {
        stopped = error;
      }
      return { status, ...wasi.take(), error: stopped };
    },
  };
}
