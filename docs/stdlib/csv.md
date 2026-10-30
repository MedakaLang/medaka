# csv

Reading and writing delimiter-separated text: CSV, and TSV by choosing a
tab as the delimiter.

A table is a `List (List String)`: one inner list per row, one `String`
per field. `parse` and `parseWith` read RFC 4180 quoting: a field may be
wrapped in double quotes, a doubled quote inside it stands for one quote,
and a quoted field may contain the delimiter and line breaks. LF and CRLF
both end a row, and a final line break does not add an empty row. An empty
line is the row `[]`, and the empty string has no rows.

`render` and `renderWith` write a table back, quoting a field only when it
has to be, and ending every row with LF, never CRLF. A row holding a single
empty field is written as `""`, so that it does not read back as the empty
row: `parse (render rows)` is `Ok rows` for any table.

Reading is lenient in the way Python's csv reader is. Whitespace around a
field is kept. A quote inside an unquoted field is an ordinary character.
Text after the closing quote of a quoted field joins the field, so a quoted
"a" followed directly by b reads as the one field "ab". A lone CR is an
ordinary character. The one error is a
quoted field that never closes.

## Reading

### `parse`

```
parse : String -> Result String (List (List String))
```

Reads comma-separated text into rows of fields.

```medaka
> parse "a,b\r\n1,2\r\n"
Ok [["a", "b"], ["1", "2"]]
> parse "name,note\nann,\"hello, world\"\n"
Ok [["name", "note"], ["ann", "hello, world"]]
> parse "a,\"b"
Err "line 1: unterminated quoted field"
```

### `parseWith`

```
parseWith : Char -> String -> Result String (List (List String))
parseWith d text
```

Reads delimiter-separated text with the given delimiter, with the same
quoting rules as `parse`. A tab reads TSV.

The delimiter may not be a double quote, LF or CR: those give an `Err`.
An unterminated quote gives `Err "line N: unterminated quoted field"`,
where `N` is the 1-based line holding that field's opening quote.

```medaka
> parseWith '\t' "a\tb\n\"x\ty\"\tz\n"
Ok [["a", "b"], ["x\ty", "z"]]
```

## Writing

### `render`

```
render : List (List String) -> String
```

Writes rows as comma-separated text, one LF-terminated line per row.

A field is quoted when it contains a comma, a double quote, CR or LF, and
its inner quotes are doubled. Every row ends in LF, not CRLF, so that the
output compares cleanly with Unix tools. A row with one empty field is
written as `""`, because an empty line reads back as the empty row.

```medaka
> render [["a", "b"], ["x,y", "say \"hi\""]]
"a,b\n\"x,y\",\"say \"\"hi\"\"\"\n"
> render [[""], []]
"\"\"\n\n"
```

### `renderWith`

```
renderWith : Char -> List (List String) -> String
renderWith d rows
```

Writes rows with the given delimiter. A tab writes TSV.

A double quote, LF or CR as the delimiter gives output that does not read
back; this is unspecified.

```medaka
> renderWith '\t' [["a", "b c"], ["x\ty", "z"]]
"a\tb c\n\"x\ty\"\tz\n"
```

