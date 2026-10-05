# sqlite

A SQLite database file reader and writer, plus a small SQL engine, written in Medaka
(`lib/`: B-tree page parsing, record encoding, a SQL tokenizer and parser, select, aggregate,
and mutate paths). It builds on `../parsec`. The `*_demo.mdk` and `*_probe.mdk` files at this
level are runnable examples and probes of one feature each; `test/` holds the project's
checks and `findings/` records design findings from building it. Run a demo with
`medaka run sqlite/<name>_demo.mdk`.
