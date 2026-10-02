# Contributing to Medaka

Medaka is experimental (0.1.0 preview), and contributions are welcome. The
details live in [AGENTS.md](AGENTS.md); this page only points at them.

## Build

Follow the [Install section of the README](README.md#install), then:

```sh
make medaka
```

## Test

```sh
make test            # in-language suite: doctests, property tests, `test` blocks
make preflight       # the gates relevant to your diff, derived from it
```

Run `make preflight` rather than the full gate suite locally; CI runs the rest.
AGENTS.md ("Build & test" and "The gates") explains the gate suite and its knobs.

## Before you commit

Format and lint every `.mdk` file you touched:

```sh
medaka fmt --write path/to/file.mdk
medaka lint path/to/file.mdk
```

## Sending a change

`main` is protected, so every change goes through a pull request: branch, push
the branch, open a PR, and let the required checks run. AGENTS.md
("How work lands") has the full flow. Reproduce a bug before fixing it, and say
so in the PR if it was already fixed.

To find something to work on, browse the
[issue tracker](https://github.com/MedakaLang/medaka/issues); issues labelled
`S0: silent wrongness` come first.

## Security findings

See [SECURITY.md](SECURITY.md).
