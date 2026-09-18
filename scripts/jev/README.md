# scripts/jev — the Jev style census

**Status:** TOOL, 2026-09-16. Design, measured results, and roadmap: `docs/design/JEV-DESIGN.md`.

A census of judgment-class style findings over Medaka source, using
TypeSafe's Jev model. Code enumerates candidates, Jev answers narrow typed
questions with calibrated probabilities, the script ranks the answers. It
fills the gap between `medaka lint` (mechanical, exact, gated) and a full LLM
style pass (slow, expensive).

Two halves today:

- **Comment register.** Every `--` comment block of two or more lines in
  `compiler/` and `stdlib/`, scored for history narration, anchoring to an
  in-flight change, whether it belongs on an issue instead, and an overall 0 to 3
  register level. The ranked list is the relocation roadmap for
  `[T-COMMENT-REGISTER]`.
- **do-syntax candidates.** Every declaration that threads Result or Option
  through nested matches without a `do`, scored for whether the levels share
  one failure handler (so a `do` plus one wrapper is equivalent), how much
  readability a rewrite would gain, and a convert / partial / leave call.
  `rule-bind-chain-to-do` in `compiler/tools/lint.mdk` already catches the
  verbatim-passthrough shape and the tree is clean of it; this covers the rest.

## Running it

```sh
pip install typesafe-sdk            # once; or TYPESAFE_SDK_PATH=<pip --target dir>
make jev-census                     # compiler/ + stdlib/, top 25 of each table
python3 scripts/jev/jev_census.py compiler/tools --kind do --top 40
python3 scripts/jev/jev_census.py --changed origin/main      # diff-scoped
python3 scripts/jev/jev_census.py --json /tmp/jev.json       # every candidate
python3 scripts/jev/jev_census.py --dry-run                  # enumerate only
```

The key is read from `TYPESAFE_API_KEY` or `~/.config/typesafe/api_key`
(mode 600). Create the file from your own terminal so the key never lands in
a transcript or shell history:

```sh
mkdir -p ~/.config/typesafe && chmod 700 ~/.config/typesafe
read -rs KEY && printf '%s' "$KEY" > ~/.config/typesafe/api_key && chmod 600 ~/.config/typesafe/api_key && unset KEY
```

Answers are cached under `.jev-cache/` (gitignored) by a hash of model,
state, and question text, so a rerun after an edit re-asks only what changed.
A whole-tree first run is a few thousand requests at about a quarter second
each, run eight at a time.

## What it is not

- **Not a gate.** It calls an external API and returns probabilities. It
  always exits 0, is not enrolled in `test/gates.toml`, and must not be. The
  right consumer is a person or an agent deciding what to fix next, or the
  end-of-sprint `style-review` pass over a `--changed` set.
- **Not a rewriter.** Jev never generates text. The roadmap says where and
  what class; the rewrite is the agent's.
- **Not a verifier of comments against code.** A comment-versus-code
  mismatch question was tried and failed (yes on 81 of 100 blocks). It is
  documented as retired in the design doc; do not re-add it in that shape.

## Changing a question

Edit the question in `jev_census.py`, then:

```sh
make jev-eval        # re-measures against scripts/jev/eval_corpus.json
```

`eval_corpus.json` holds 166 hand-labeled items with their text stored inline,
so the corpus does not drift with the tree. The numbers it prints are
agreement with the corpus labels — one labeler's judgment for the original
items, and for the 6 added in 2026-09 an adjudication against the question
text (see `_about`); the design doc records the numbers
each shipped question set had, so a change can be compared. Pass
`--no-language-notes` to `jev_eval.py` to rerun the novel-language control.
