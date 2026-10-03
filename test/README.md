# test

The compiler's differential and regression suite. The gates are the `diff_compiler_*.sh`
scripts and native `*_test.mdk` modules registered in `gates.toml`; fixtures, goldens and
snapshots sit beside them. Run the gates your change touches with `make preflight`; run the
in-language tests (doctests, properties, `test` blocks) with `make test`. `AGENTS.md`
("Build & test") explains the loop and how to add a gate.
