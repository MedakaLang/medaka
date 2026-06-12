# Medaka — convenience targets.
#
# Two compilers live here (see AGENTS.md):
#   • the native, self-hosted `medaka` (CANONICAL post-2026-06-12 flip) — built
#     OCaml-free from the checked-in IR seed; this is what users invoke.
#   • the OCaml reference compiler (`lib/`+`bin/`, built with dune) — kept FROZEN
#     as the soak-period differential oracle (retirement ≠ removal); not removed.
#
# Quick start (native, no OCaml):   make medaka && ./medaka run yourfile.mdk

.PHONY: medaka emitter seed reference bootstrap clean help

## medaka  — build the native OCaml-free `medaka` CLI from the seed (CANONICAL)
medaka:
	sh test/build_native_medaka.sh

## emitter — build just the native emitter binary from the seed (medaka_emitter)
emitter:
	sh test/bootstrap_from_seed.sh

## bootstrap — verify the OCaml-free seed bootstrap (C3a byte-identical)
bootstrap:
	sh test/bootstrap_from_seed.sh

## seed    — RE-MINT the checked-in IR seed (needs OCaml; run per-release only)
seed: reference
	sh test/refresh_seed.sh

## reference — build the OCaml reference compiler + tools (the frozen oracle)
reference:
	dune build --root .

## clean   — remove native build artifacts (keeps the checked-in seed)
clean:
	rm -f medaka medaka_emitter

help:
	@grep -E '^## ' Makefile | sed 's/^## //'
