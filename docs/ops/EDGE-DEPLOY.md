# Deploying a Medaka program to Cloudflare Workers

`medaka build --target wasmgc/edge` turns a program into a WasmGC module plus a
loader that exposes it as a Workers `fetch` handler. This page is the procedure
from source to a verified live origin. The target and its capability set are
defined in `docs/spec/TARGETS.md`; the host contract in
`docs/spec/WASM-SEMANTICS.md`.

Each command below is tagged at the end of the page with whether it was run for
this document. Nothing here deploys or authenticates: the deploy and origin-probe
steps are written from wrangler's documented behavior and are **not run here**.

## Prerequisites

- A `medaka` built from the repository (`make medaka`). The distributed `medaka`
  does not yet ship the host file or a wasm emitter, so it cannot build wasm
  (see Limits).
- A wasm emitter: `sh test/wasm/build_wasm_oracle.sh --modules-only` builds
  `test/bin/wasm_emit_modules_main`. Point `MEDAKA_WASM_EMITTER` at it; the build
  stops with an actionable error otherwise.
- `wasm-tools` on `PATH` (assembles the emitted WAT).
- `node` 24 or later for local checks of the loader; `wrangler` 4.x for the
  Workers steps (`npm install wrangler`). Measured with wrangler 4.151.1 and
  workerd 2026-10-12.
- For the deploy only: a Cloudflare account and an API token scoped to Workers
  edit. Keep it outside the repository, as `playground/README.md` §
  Deploying does for Pages.

## Build

```sh
MEDAKA_WASM_EMITTER=$PWD/test/bin/wasm_emit_modules_main \
  MEDAKA_STRICT=1 ./medaka build --target wasmgc/edge -o dist/hello.wasm hello.mdk
```

`-o` must end in `.wasm`: the Workers bundler recognizes a compiled module by
that suffix, and an edge build with any other `-o` is a build error. The output
directory holds exactly four files:

| File | Purpose |
|---|---|
| `hello.wasm` | The program. Imports the `env` namespace; exports `mdk_main` and `mdk_entry_split`. |
| `hello.mjs` | The Workers entry. Imports the module with `import source`, exports `run(opts)` and a default `fetch` handler. |
| `hello.bytes.mjs` | The same entry for runtimes that cannot `import source` (Bun). Reads the `.wasm` from disk and compiles it. Workers refuses it. |
| `medaka_host.mjs` | The host: capability imports, JSPI wiring, output buffering. Both entries import it; keep it beside them. |

Two edge builds into one directory overwrite `medaka_host.mjs` with identical
bytes. A build for any other target writes only the `.wasm`.

The default `fetch` handler runs the program once per request, answers `200`
with the program's stdout as `text/plain; charset=utf-8` when it finishes
normally, and `500` with the stdout produced so far when it exits non-zero or
traps. The request path, method and body are not visible to the program. Stderr
goes to neither the response nor the caller; a panic message reaches only
`run()`'s result.

## Wrangler configuration

`wrangler.toml` beside the output files:

```toml
name = "medaka-hello"
main = "hello.mjs"
compatibility_date = "2026-10-01"
```

- `main` is `<base>.mjs`. Wrangler bundles the `.wasm` as a `CompiledWasm` module
  through its default rule (`**/*.wasm`) and keeps `import source wasmModule from
  "./hello.wasm"` unchanged. This is why the suffix matters.
- `import source` is the only static form that hands the loader a
  `WebAssembly.Module` on workerd, Node and Deno. Workers refuses runtime
  `WebAssembly.compile(bytes)` ("Wasm code generation disallowed by embedder"),
  so the bytes loader cannot run there.
- No compatibility flag is needed for JSPI. workerd 2026-10-12 exposed
  `WebAssembly.Suspending` and `WebAssembly.promising` at compatibility dates
  2021-11-03, 2024-01-01, 2025-06-01, 2026-10-01 and 2026-10-12, and a
  `fetchText` program suspended and resumed under it. This was measured on local
  workerd only (through `workerd` and `wrangler dev --local`). **Whether
  production Workers behaves the same is unconfirmed until the first deploy.**
- `wrangler deploy --dry-run --outdir` accepted the config and bundle
  (87 KiB, 22 KiB gzipped) with exit 0.

## Local check

```sh
cd dist
npx wrangler dev --local --port 8790
curl -s -w '\nstatus=%{http_code} type=%{content_type}\n' http://127.0.0.1:8790/
```

Expected for the hello program (`println "hello from the edge"`, `sleepMs 5`,
`println "after sleep"`):

```
hello from the edge
after sleep

status=200 type=text/plain; charset=utf-8
```

A `fetchText` program run this way reaches the network from the local worker; the
spike pointed it at a local HTTP server on `127.0.0.1` and got the body back.

To check the loader without workerd, `node hello.mjs`-style use works through
`import('./hello.mjs')` then `run()`, which returns
`{stdout, stderr, exitCode}`. `fetchText` there needs
`node --experimental-wasm-jspi` and `run({fetch})` to supply the fetch function;
without JSPI it fails with a message naming JSPI. A top-level value that calls
`fetchText` or `sleepMs` cannot suspend during initialization: the run ends in exit
code 1 with a message saying so; call them from `main`.

## Deploy

```sh
cd dist
npx wrangler deploy
```

Authentication comes from `CLOUDFLARE_API_TOKEN` and `CLOUDFLARE_ACCOUNT_ID` in
the environment. `wrangler deploy` prints the `*.workers.dev` URL, or the routes
the config names.

## Verify the origin

A zero exit and a printed URL prove only that wrangler uploaded. Probe the live
origin, as `playground/README.md` does for Pages:

```sh
curl -sS -w '\nstatus=%{http_code} type=%{content_type}\n' https://medaka-hello.<subdomain>.workers.dev/
```

Expect `status=200`, `type=text/plain; charset=utf-8`, and a body byte-equal to
the program's stdout (`hello from the edge\nafter sleep\n`). A program that
calls `fetchText` is probed the same way against a route whose content you know:
with `main` printing `ok: ` and the body of `fetchText "https://<known-host>/data.txt"`,
the response body must be `ok: <that file's content>`. A `500` with an empty body
means the program trapped before printing (see F1 below); `status=200` with an
`err: ...` line means `fetchText` ran and the fetch failed, which is the
program's result, not a deploy fault.

Because the handler ignores the path, every route on the worker returns the same
body; probe `/` and one other path to confirm the route table is what you meant.

## Bun and Deno

- Deno 2.9.6 runs `hello.mjs` (the `import source` form), including
  `deno serve hello.mjs`; `fetchText` works because Deno has JSPI.
- Bun 1.4.3 cannot parse `import source`. Use `hello.bytes.mjs` as the entry:
  `bun hello.bytes.mjs` serves the default handler, and `run()` works. The bytes
  loader also works on Node and Deno. Bun has JSPI, so `fetchText` runs there.
- Node 24.18 accepts `import source` with no flag.

## Limits and known gaps

- **FFI is granted, bindings are not supplied (F2).** `wasmgc/edge` grants the
  `FFI` label, but the default `fetch` handler passes no `bindings`. A `bind js`
  program passes `medaka check` and fails at the call with `CapabilityError: js
  binding ... is not supplied by this host`. `run(opts)` forwards `opts.bindings`;
  `fetch` has no source for them.
- **A top-level value that reaches `fetchText` or `sleepMs` traps at
  instantiation (F1).** `page = fetchText "..."` at top level passes `check`,
  builds, and fails under JSPI with `trying to suspend without WebAssembly.promising`
  because top-level values run in the wasm start function, which is never
  promising. On the edge this is a `500` with an empty body. Call `fetchText` and
  `sleepMs` from inside `main` or functions it calls. `sleepMs` at top level was
  not probed; treat it the same.
- **Sockets are refused.** The `net` module's socket externs are refused by
  `medaka check` on the edge target; only `fetchText` does network I/O.
- **Withheld or inert:** stdin, environment, files, argv and `exit` are withheld
  or inert on the edge. A program that calls `exit` or reads args can pass
  `check` (those carry no capability label, #4178) and die at run with a
  withheld-slice error.
- **The distributed `medaka` cannot build wasm yet (F3).** `scripts/make_dist.sh`
  ships neither `playground/medaka_host.mjs` nor a wasm emitter; build from a
  repository checkout.
- **Panic text carries the build machine's source path** on stderr (reaches
  `run()` and the runtime log, which the default `fetch` writes with `console.error`; it is not
  in the response body).
- **Unmeasured:** production Workers; the lowest Node 24 minor accepting
  `import source` unflagged; whether Workers' coarse clock makes `monotonicSec`
  deltas zero.

## Provenance of the commands

| Command | Status |
|---|---|
| `sh test/wasm/build_wasm_oracle.sh --modules-only` | ran |
| `medaka build --target wasmgc/edge -o <dir>/hello.wasm hello.mdk` (four files listed above) | ran |
| `import('./hello.mjs')` then `run()` under node 24 | ran |
| `wrangler deploy --dry-run --outdir`, bundle size and `import source` kept | from spike report |
| `wrangler dev --local --port 8790` plus `curl` | from spike report |
| JSPI present across compatibility dates | from spike report |
| `deno serve`, `bun hello.bytes.mjs`, `node --experimental-wasm-jspi` | from spike report |
| `wrangler deploy` | not run here |
| origin probe `curl` against `*.workers.dev` | not run here |
| `npm install wrangler` | from spike report |
