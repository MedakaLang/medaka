# parsec

A general parser-combinator library written in Medaka (`lib/`), with a smoke demo in
`main.mdk` (arithmetic expressions and integer lists) and a TOML demo in `toml_demo.mdk`.
It is a separate project under its own `medaka.toml`, and `../sqlite` depends on it. The
byte-oriented parsers in `stdlib/byteparser.mdk` are a different, smaller library. Run the
checks with `medaka test parsec/test/check_test.mdk`.
