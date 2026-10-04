# The website — incident narrative behind AGENTS.md's [WEB-*] items

## The website — full AGENTS.md section

*Full `AGENTS.md` text as of 2026-10-03, moved here verbatim when AGENTS.md was slimmed; AGENTS.md keeps the rule and the command.*

## The website — <https://medaka-lang.dev>

**The playground IS the website** (Cloudflare Pages, project `medaka`; also
`medaka.pages.dev`). Pure static — the compiler runs client-side as WasmGC, so
there is no backend to deploy. Full procedure, credential handling, and the two
traps below: `playground/README.md` § Deploying.

```sh
bash playground/deploy_cloudflare.sh    # builds site/ if needed, then publishes
```

🚨 **[WEB-PREVIEW-SILENT] The deploy must pass `--branch` explicitly** (the script
does; don't remove it). Wrangler otherwise infers the branch from git, so
deploying from a topic branch publishes a **PREVIEW** — it prints *"Deployment
complete"* and a url, **exits 0**, and the production origin keeps serving 404.
The output is indistinguishable from a real deploy. Verify the ORIGIN, never the
exit code:
```sh
curl -sS -o /dev/null -w '%{http_code}\n' https://medaka-lang.dev/dist/array.mdk   # 200
```

🚨 **[WEB-SITE-FILE-LIST] `build_site.sh` copies an EXPLICIT file list**, and the
page fetches ~24 assets at startup (`runtime`/`core` + the ~20 `EXTRA_MODULES` in
`main.js`, the two wasm blobs, `favicon.svg`, `og-card.png`). A new asset that is
not added to that list is silently absent from the deploy — this shipped a site
that 404'd on **every** stdlib import. The script now derives the expected set
from `main.js` and fails closed; keep that check.

🚨 **[WEB-STALE-DIST] `build_site.sh` COPIES whatever `playground/dist/` already
holds and rebuilds the wasm only when `dist/playground.wasm` is MISSING**, and
`deploy_cloudflare.sh` builds `site/` only when `site/` is missing. A gate run
(`test/wasm/diff_playground_input.sh` calls `build_playground_wasm.sh`) leaves a
`dist/` from THAT branch's source, and a later deploy from `main` ships it with
exit 0 — this deployed a `core.mdk` that predated a merged stdlib change while
`verify_stdlib_deploy.sh` still PASSED (it checks the docs route, not `dist/`).
Before a deploy: `bash playground/build_playground_wasm.sh` (re-copies every
`dist/*.mdk` from `stdlib/`), `rm -rf playground/site`, then deploy. Verify the
COMPILER, not just the origin: compile a probe through the live
`/dist/playground.wasm` + `/dist/core.mdk` with `playground/dev_compile_node.mjs`,
and grep the live `core.mdk` for a line only the new source has. The custom domain
can lag `medaka.pages.dev` by a minute after a deploy; re-fetch before concluding
it missed.

⚠️ **[WEB-OG-ABSOLUTE] `og:image` in `index.html` is an ABSOLUTE
`https://medaka-lang.dev/…` url** — scrapers don't resolve relative ones — so no
link-preview card renders from any other origin, `*.pages.dev` previews included.
Expected, not a bug. Regenerate the card with `python3 playground/build_og_card.py`
(headless Chrome; reads the fish from `favicon.svg` and the token colours from
`medaka_lang.js`).

⚠️ **[WEB-SH-IS-A-GATE] A new `.sh` under `playground/` is EXECUTED by
`make preflight`** — `_gate_candidates()` (`test/preflight.sh`) treats every
tracked `.sh` as a gate and subtracts only what `test/CI-COVERAGE-TOOLS.txt`
lists. `deploy_cloudflare.sh` was missing that entry and preflight **ran a live
production deploy** on a diff that only touched `playground/README.md`. Ledger any
new script there, and prove it by measuring the SIDE EFFECT (deployment count),
not the gate list.
