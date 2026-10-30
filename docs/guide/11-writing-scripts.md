# Writing a script in Medaka

A script here is a program you write once, run, and throw away: edit a file, count
what is in a directory, run a command and compare what it printed, turn a log into
a report. This chapter shows the four jobs scripts are mostly made of, each as a
complete program, then lists the things that cost most people a failed run the first
time, what `medaka run` cannot do, and a sheet of Python and shell idioms with their
Medaka spelling.

Every program in this chapter is a real file, run by the test suite, and the text
on this page is checked against those files. Where a program needs `medaka build`
instead of `medaka run`, the page says so.

## Running a script

Put the program in a file and run it:

```
$ medaka run script.mdk
```

A first line starting with `#!` is skipped, so a script can be executable. The
interpreter has to be named with `env -S`, because on Linux a plain `env` receives
`medaka run` as one argument and looks for a program of that name:

```medaka
#!/usr/bin/env -S medaka run
main = println "hello from a script"
```

After `chmod +x hello_script.mdk`, running `./hello_script.mdk` prints:

```medaka-expect
hello from a script
```

With `#!/usr/bin/env medaka run` instead, Linux's `env` looks for a program called
`medaka run` and answers `No such file or directory`.

To run a program without a file, give `run` a `-` and write the program on standard
input. The shell here-document is the usual way:

```
$ medaka run - <<'EOF'
main = println "inline: the program came from stdin"
EOF
inline: the program came from stdin
```

The program's own standard input is empty (`readAll ()` returns `""`), because the
program text used it up. `medaka run /dev/stdin` does not work when the program arrives through a pipe or
here-document: it reports `` no `main` in this file; add `main = ...` ``. Use `-`.

A program that draws random numbers gets a different seed on every run. Set
`MEDAKA_SEED` to a decimal integer to make the draws repeat, for `run` and for a
built program alike:

```medaka
main = println (debug (map (_ => randomInt 1 100) [1..=5]))
```

```
$ medaka run draw.mdk
[62, 84, 66, 30, 2]
$ MEDAKA_SEED=42 medaka run draw.mdk
[14, 92, 59, 65, 51]
$ MEDAKA_SEED=42 medaka run draw.mdk
[14, 92, 59, 65, 51]
```

(The first line is one possible unseeded run; it differs every time.)

## Four worked examples

The programs below start by writing their own input files, so each one runs from an
empty directory. In a real script you would read files that already exist.

### Edit a file

Most scripts are text edits: read a file, change a literal, replace a block, write
it back. `editFile path f` reads the file, applies `f` to its text and writes the
result. If `f` returns an `Err`, nothing is written and the error comes back with
the path in front of it.

`replaceOnce old new text` is the asserted edit. It is an `Err` unless `old` occurs
exactly once, so a pattern that has drifted fails loudly instead of editing the
wrong place or nothing at all. `cutBetween start end text` splits the text around
two anchors and gives back what came before, between and after. A multi-line block
is easiest to quote as a raw string, `r"""…"""`, in which a backslash is just a
backslash, and `dedent` removes the indentation the quoting needed:

```medaka
import fs.{editFile}
import string.{cutBetween, dedent, replaceOnce}

config : String
config =
  r"""
  [server]
  port = 8080
  # begin generated
  old line 1
  old line 2
  # end generated
  host = "localhost"
  """

generated : String
generated = r"""
  new line 1
  new line 2
  """

begin : String
begin = "# begin generated\n"

finish : String
finish = "# end generated\n"

replaceBlock : String -> (String, String, String) -> String
replaceBlock new (before, _, after) = before ++ begin ++ new ++ finish ++ after

splice : String -> Result String String
splice text =
  map (replaceBlock (dedent generated)) (cutBetween begin finish text)

main =
  resultOrPanic "write" (writeFile "app.toml" (dedent config))
  resultOrPanic
    "port"
    (editFile "app.toml" (replaceOnce "port = 8080" "port = 9090"))
  resultOrPanic "splice" (editFile "app.toml" splice)
  print (resultOrPanic "read" (readFile "app.toml"))
  println (debug (editFile "app.toml" (replaceOnce "no such text" "x")))
  println (debug (editFile "app.toml" (replaceOnce "line" "LINE")))
```

It prints the edited file, then what a failed edit looks like:

```medaka-expect
[server]
port = 9090
# begin generated
new line 1
new line 2
# end generated
host = "localhost"
Err "app.toml: expected 1 occurrence of `no such text…`, found 0"
Err "app.toml: expected 1 occurrence of `line…`, found 2"
```

### Count what is in a repository

`walkFiles root` lists every file under a directory in a stable order, and `glob`
takes a pattern such as `"tree/**/*.mdk"`. `countBy` turns a list into a map from
each key to its count. Sorting by `Down` count puts the biggest first, and the
second element of the key breaks ties by name. `toFixed` writes a float with a given
number of places, and `groupThousands` puts commas in an integer:

```medaka
import fs.{glob, mkdirAll, walkFiles}
import io.{readLines}
import list.{Down(..), sortOn}
import map.{countBy, entries}
import path.{extname}
import string.{groupThousands, padLeft, padRight, repeat, toFixed}

put path n = resultOrPanic path (writeFile path (repeat n "x = 1\n"))

makeTree _ =
  resultOrPanic "mkdir" (mkdirAll "tree/src/sub")
  resultOrPanic "mkdir" (mkdirAll "tree/docs")
  put "tree/src/a.mdk" 1200
  put "tree/src/b.mdk" 30
  put "tree/src/sub/c.mdk" 4
  put "tree/docs/guide.md" 250
  put "tree/docs/notes.md" 7
  put "tree/Makefile" 3

lineCount path = length (resultOrPanic path (readLines path))

row total (ext, n) =
  let share = 100.0 * intToFloat n / intToFloat total
  padRight 10 ' ' (if ext == "" then "(none)" else ext)
    ++ padLeft 6 ' ' (intToString n)
    ++ padLeft 8 ' ' (toFixed 1 share ++ "%")

main =
  makeTree ()
  let files = resultOrPanic "walk" (walkFiles "tree")
  let ranked =
    sortOn (kv => (Down (snd kv), fst kv)) (entries (countBy extname files))
  println "ext         files   share"
  each println (map (row (length files)) ranked)
  let total = fold (n p => n + lineCount p) 0 files
  println "\{length files} files, \{groupThousands total} lines"
  let mdk = resultOrPanic "glob" (glob "tree/**/*.mdk")
  println "mdk: \{debug mdk}"
```

It prints:

```medaka-expect
ext         files   share
.mdk           3   50.0%
.md            2   33.3%
(none)         1   16.7%
6 files, 1,494 lines
mdk: ["tree/src/a.mdk", "tree/src/b.mdk", "tree/src/sub/c.mdk"]
```

`io.readLines` is used to count lines rather than `string.lines`: see
[Line counts](#line-counts) below.

### Run a command and compare outputs

`io.runCommandOk program args` runs a program and returns its standard output and
standard error, or an `Err` naming the exit code. `diff.unified n (labelA, textA)
(labelB, textB)` prints the difference between two texts in the format `diff -u`
uses, with `n` lines of context, and prints nothing when the texts are equal.

`medaka run` refuses a program that can reach `runCommand`, before it runs anything:

```
$ medaka run run_compare.mdk
error: run_compare.mdk:…: the built-in `runCommand` is reached via `main → capture → runCommandOk → runCommand`, and `medaka run` refuses it on purpose (implemented by llvm; running a subprocess from the interpreter waits on a security decision)
help: build it with `medaka build run_compare.mdk -o <bin>`, then run `<bin>`
```

Until the exec policy for `run` is settled, build the script and run the binary:

```medaka
import diff.{unified}
import io.{runCommandOk}

golden : String
golden = "alpha\nbeta\ngamma\ndelta\n"

report : String -> String -> <IO> Unit
report label out =
  if out == golden then
    println "\{label}: same"
  else
    print (unified 1 ("golden", golden) (label, out))

capture : String -> String -> <Exec "printf", IO> Unit
capture label text =
  let (out, _) = resultOrPanic label (runCommandOk "printf" [text])
  report label out

main =
  capture "run-a" golden
  capture "run-b" "alpha\nBeta\ngamma\n"
  println (debug (runCommandOk "sh" ["-c", "echo oops >&2; exit 3"]))
```

```
$ medaka build run_compare.mdk -o run_compare
$ ./run_compare
run-a: same
--- golden
+++ run-b
@@ -1,4 +1,3 @@
 alpha
-beta
+Beta
 gamma
-delta
Err "sh exited 3: oops\n"
```

### Turn JSON into a report

`json.parseLines` reads JSON Lines: one result per non-blank line, so a malformed
line is an `Err` for that line and the rest still parse. `json.atPath` follows a
list of keys and indexes into a value, and its `Err` says which step failed.
`math` has `mean`, `median`, `stdev` and `percentile`, and `roundInt` rounds a float
to an `Int`. `json.pretty n` prints a value over several lines, indented `n` spaces,
and `csv.render` writes rows of fields as CSV, quoting where it must:

```medaka
import csv as C
import json.{Json(..), asNumber, atPath, jObject, parseLines, pretty}
import list.{partitionResults}
import map.{entries, groupByKey}
import math.{mean, median, percentile, roundInt}
import string.{dedent, toFixed}

log : String
log =
  r"""
  {"path": "/home", "ms": 12.5, "status": 200}
  {"path": "/api", "ms": 80, "status": 200}
  {"path": "/api", "ms": 240.25, "status": 500}
  not json
  {"path": "/home", "ms": 15, "status": 404}
  """

data Req = { path : String, ms : Float, status : Int }

text : String -> Json -> Result String String
text key j = match atPath [key] j
  Ok (JString s) => Ok s
  Ok _ => Err "\{key}: not a string"
  Err e => Err e

number : String -> Json -> Result String Float
number key j = match atPath [key] j
  Err e => Err e
  Ok v => match asNumber v
    Some x => Ok x
    None => Err "\{key}: not a number"

request : Json -> Result String Req
request j = do
  path <- text "path" j
  ms <- number "ms" j
  status <- number "status" j
  pure Req { path = path, ms = ms, status = roundInt status }

whole : Option Float -> Json
whole x = JInt (roundInt (optionOr 0.0 x))

pathRow : (String, List Req) -> List String
pathRow (path, rs) =
  let avg = optionOr 0.0 (mean (map (r => r.ms) rs))
  [path, intToString (length rs), toFixed 1 avg]

main =
  let (bad, parsed) = partitionResults (parseLines (dedent log))
  let (unusable, reqs) = partitionResults (map request parsed)
  let times = map (r => r.ms) reqs
  let byStatus = entries (groupByKey (r => r.status) reqs)
  let stats = jObject [
    ("mean", whole (mean times)),
    ("median", whole (median times)),
    ("p90", whole (percentile 90.0 times)),
  ]
  let statuses = map ((s, rs) => (intToString s, JInt (length rs))) byStatus
  let report = jObject [
    ("requests", JInt (length reqs)),
    ("skipped", JInt (length bad + length unusable)),
    ("ms", stats),
    ("by_status", jObject statuses),
  ]
  println (pretty 2 report)
  println (debug (atPath ["by_status", "200"] report))
  println (debug (atPath ["ms", "max"] report))
  let byPath = entries (groupByKey (r => r.path) reqs)
  print (C.render (["path", "count", "mean_ms"] :: map pathRow byPath))
```

It prints:

```medaka-expect
{
  "requests": 4,
  "skipped": 1,
  "ms": {
    "mean": 87,
    "median": 48,
    "p90": 192
  },
  "by_status": {
    "200": 2,
    "404": 1,
    "500": 1
  }
}
Ok 2
Err "at ms: no key \"max\""
path,count,mean_ms
/api,2,160.1
/home,2,13.8
```

To read a whole JSON document, use `json.parse` in place of `parseLines`. To write
JSON Lines, `json.stringifyLines` is the other half of `parseLines`.

## First round trips

These are the facts that most often cost a failed run. The compiler's message names
most of them; the aim here is to save the round trip.

### A plain block, not `do`

Statements in `main` are lines of an indented block. `do` is for chaining `Option`
and `Result` values, not for sequencing output; used for output it gives
`` this `do` block needs a `Thenable` value here, such as `Option` or `Result`, but got `Unit`; bind a plain `Unit` with `let` instead of `<-` ``.

```medaka
main =
  println "a plain indented block"
  println (debug [1, 2, 3])
  println (debug "text")
  println (display "text")
```

```medaka-expect
a plain indented block
[1, 2, 3]
"text"
text
```

Medaka has no `show`: the function is `debug`, which renders a value the way a
program would write it, strings in quotes. `display` renders the plain text.
Writing `show` gives `` unbound variable `show`; did you mean `debug`? (Haskell's `show` is `debug` in Medaka) ``.

### Results are values, not statements

`writeFile`, `readFile` and most of `fs` return a `Result`. A `Result` cannot stand
alone as a statement: the compiler says `` this statement's value (`Result String Unit`) is discarded; only a `Unit` expression may stand alone as a statement ``. Either unwrap it
with `resultOrPanic "context" (…)`, which stops the script with the context and the
error when it is an `Err`, or match on it:

```medaka
main =
  resultOrPanic "write demo.txt" (writeFile "demo.txt" "hello\n")
  match readFile "demo.txt"
    Ok text => print text
    Err e => println "cannot read: \{e}"
  println (debug (readFile "missing.txt"))
```

```medaka-expect
hello
Err "No such file or directory"
```

`let _ = writeFile …` also compiles, and throws the `Err` away without a word. The
house style keeps `let _ =` inside `do` blocks; in a plain block, unwrap or match.

```medaka
main =
  let _ = readFile "missing.txt"
  println "the Err above was dropped without a word"
```

```medaka-expect
the Err above was dropped without a word
```

### Effects in signatures

A function with a signature must name every effect it performs. A `shout : String ->
Unit` that calls `println` is rejected with `` performs <Stdout> where only <> is allowed ``. Write the row, here
`<IO>`, or leave the signature off: inference fills the row in, and leaving `main`
and script helpers unsigned is the easiest way.

```medaka
shout : String -> <IO> Unit
shout s = println (s ++ "!")

main = shout "a helper with a signature names its effects"
```

```medaka-expect
a helper with a signature names its effects!
```

### Imports

A bare `import fs` binds no names; it only makes the module's instances available.
Write `import fs as F` and call `F.walkDir`, or `import fs.{walkDir}`. Using a
module's function without either gives `` unbound variable `walkDir`; add `import fs.{walkDir}` ``.

Most of what scripts need is not in the prelude. Where the common names live:

- `string`: `trim`, `padLeft`, `padRight`, `repeat`, `lines`, `split`, `join`,
  `contains`, `replace`, `replaceAll`, `replaceOnce`, `toFixed`.
- `list`: `sortOn`, `sort`, `tally`, `take`, `drop`, `last`, `reverse`.
- `path`: `basename`, `dirname`, `extname`.
- `map`: `countBy`, `groupByKey`, `entries`.
- The prelude, with no import: `map`, `filter`, `flatMap`, `any`, `fold`, `each`,
  `length`, `debug`, `resultOrPanic`. There is no `concatMap` (it is `flatMap`) and
  no `foldl` (it is `fold`); `concatMap` gives `` unbound variable `concatMap` ``.

```medaka
import fs as F
import fs.{walkDir}
import list.{sortOn, tally}
import path.{basename}
import string.{lines, padLeft, repeat, trim}

main =
  println (debug (basename "src/lib/main.mdk"))
  println (debug (trim "  padded  "))
  println (padLeft 5 '.' "ab")
  println (repeat 3 "ab")
  println (debug (lines "a\nb"))
  println (debug (sortOn negate [3, 1, 2]))
  println (debug (tally ["x", "y", "x"]))
  println (debug (flatMap (x => [x, x]) [1, 2]))
  println (debug (fold (+) 0 [1, 2, 3]))
  println (debug (any (> 2) [1, 2, 3]))
  println (debug (F.isFile "no-such-file"))
  println (debug (walkDir "no-such-dir"))
```

```medaka-expect
"main.mdk"
"padded"
...ab
ababab
["a", "b"]
[3, 2, 1]
[("x", 2), ("y", 1)]
[1, 1, 2, 2]
6
True
Err "No such file or directory"
Err "No such file or directory"
```

### Floats and integers

`round` returns a `Float`. Integer `/` and `%` need an `Int`, so convert with
`floatToInt (round x)`, or use `math.roundInt` (also `floorInt` and `ceilInt`):

```medaka
import math.{roundInt}

main =
  println (debug (round 7.6))
  println (debug (floatToInt (round 7.6) / 2))
  println (debug (roundInt 7.6 / 2))
```

```medaka-expect
8.0
4
4
```

### Regular expressions

`regex` uses RE2. Write patterns as raw strings, `r"\d+"`, instead of doubling every
backslash. A replacement template names groups `$1`, `$2`, not `\1`: a backslash
followed by a digit is kept as literal text. A record field access inside a lambda
needs the type said out loud, because `Match` and `Group` both have a `text` field.
Without `(m : R.Match)`, the compiler says `` ambiguous field `.text`: it is declared by `Group` and `Match` and the record type is undetermined; annotate the record, as in `(r : Group).text` ``.

```medaka
import regex as R

main =
  let re = R.mustCompile r"(\w+)@(\w+)"
  println (R.replaceAll re "$2/$1" "user@host, ann@site")
  println (R.replaceAll re r"\2/\1" "user@host")
  println
    (debug (map (m => (m : R.Match).text) (R.findAll re "user@host, ann@site")))
```

```medaka-expect
host/user, site/ann
\2/\1
["user@host", "ann@site"]
```

### Replacing text

`string.replace old new s` replaces only the first occurrence. Python's
`s.replace(old, new)` replaces every one. For every occurrence use `replaceAll`; for
an edit that must hit exactly one place, use `replaceOnce`, which is an `Err` when
the text occurs no times or more than once:

```medaka
import string.{replace, replaceAll, replaceOnce}

main =
  println (replace "a" "o" "banana")
  println (replaceAll "a" "o" "banana")
  println (debug (replaceOnce "ban" "pan" "banana"))
  println (debug (replaceOnce "n" "m" "banana"))
```

```medaka-expect
bonana
bonono
Ok "panana"
Err "expected 1 occurrence of `n…`, found 2"
```

### Line counts

`string.lines` splits on every `\n`, so a text that ends in a newline ends in an
empty line. `io.readLines` does not produce that last empty line. The file
`wc -l` counts as two lines is two lines with `readLines`:

```medaka
import io.{readLines}
import string.{lines}

main =
  println (debug (lines "a\nb\n"))
  resultOrPanic "write" (writeFile "two.txt" "a\nb\n")
  println (debug (readLines "two.txt"))
```

```medaka-expect
["a", "b", ""]
Ok ["a", "b"]
```

### Which engine

`medaka run` interprets the program: it starts fast and needs no build. `medaka
build` compiles it to a native binary: it is slow to start the first time, runs
much faster, and has no recursion limit worth the name. Everything above runs under
both, apart from subprocesses (build only) and the limits in the next section. The
[engines table](../stdlib/ENGINES.md) lists, extern by extern, what each way of
running does.

## Limits of `medaka run`

The interpreter has no tail calls and stops a call chain at depth 25,000. A
function that is a loop in compiled code is a deep chain here, so library functions
that walk a whole input recursively overflow on a large one under `run`. The message
is `recursion too deep: evaluator call depth exceeded 25000`, and the advice in it
is to build. The edges below were measured on small inputs of one shape; your input's
edge will differ, and all of them work natively.

| call | `medaka run` | `medaka build` |
|---|---|---|
| `csv.parse` of rows `a,b,c` | 24,000 rows ok; 25,000 overflow | 300,000 rows ok |
| `json.parse` of an array of `{"a": n}` objects | 6,000 ok; 7,000 overflow | 100,000 ok |
| `diff.editScript` of two lists of lines, one in a thousand different | 12,000 lines ok; 13,000 overflow | 100,000 ok |
| `fs.walkDir` of one directory of empty files | 20,000 ok; 25,000 overflow | 120,000 ok |

For big inputs, `medaka build`. The probe behind the first row reads its size from
the environment:

```medaka
import csv as C
import string.{repeat, toInt}

main =
  let n = optionOr 1000 (toInt (optionOr "1000" (getEnv "N")))
  match C.parse (repeat n "a,b,c\n")
    Ok rows => println "rows: \{length rows}"
    Err e => println "err \{e}"
```

```
$ N=24000 medaka run limit_csv.mdk
rows: 24000
$ N=25000 medaka run limit_csv.mdk
…: runtime error [E-STACK-OVERFLOW]: recursion too deep: evaluator call depth exceeded 25000; `medaka run` has no tail-call optimisation, so build a native binary with `medaka build`
```

### Floats in JSON

`json.pretty` and `json.stringify` write a float with `floatToString`, which
switches to an exponent from 1e12, while Python's `json.dumps` writes digits until
1e16. A script that writes large floats into JSON for another program to read should
check that the program accepts both spellings.

```medaka
import json.{Json(..), pretty}

main =
  each
    (x => println (pretty 2 (JFloat x)))
    [100000000000.0, 1e+12, 1.5e+14, 1e+15, 1e+16]
```

Medaka prints:

```medaka-expect
100000000000.0
1e+12
1.5e+14
1e+15
1e+16
```

Python's `json.dumps` of the same numbers prints:

```
100000000000.0
1000000000000.0
150000000000000.0
1000000000000000.0
1e+16
```

### Diffs that differ from GNU `diff`

`diff.unified` finds a shortest edit script, and where several shortest scripts
exist it may choose a different one from GNU `diff -u`. Both are correct; a golden
file compared byte for byte with `diff -u` output can differ. For these inputs:

```medaka
import diff.{unified}

main = print (unified 3 ("A", "c\na\n") ("B", "b\nc\nc\na\na\n"))
```

Medaka prints:

```medaka-expect
--- A
+++ B
@@ -1,2 +1,5 @@
+b
 c
+c
 a
+a
```

GNU `diff -U3 --label A --label B` prints:

```
--- A
+++ B
@@ -1,2 +1,5 @@
+b
 c
+c
+a
 a
```

## Python and shell idioms in Medaka

The thirty idioms below are the most frequent in a survey of 19,391 distinct scripts
that coding agents wrote and ran in this repository: 7,289 Python and 8,088 shell
bodies, the rest Medaka and JavaScript. They are ranked by how many scripts use the
idiom (the count is in the first column), and where Python and shell spell the same
thing differently, both are given. Each cell on the right is a line from a program
that runs in the test suite, with these definitions in force. The cells that use `sh` or
`runCommand` come from a second program that must be built, and its definitions follow.

```medaka-nocheck: setup only; the table that follows holds the cells that complete this program
import diff.{unified}
import fs.{copyFile, mkdirAll}
import io.{getEnvOr, readLines}
import json.{atPath, parse}
import list.{last, reverse, sort, sortOn, take}
import map.{countBy, entries}
import path.{basename}
import regex as R
import string.{contains, lines, replaceAll, split, toFixed, trim}

matchText : R.Match -> String
matchText m = m.text

main =
  let digits = R.mustCompile r"\d+"
  let doc = resultOrPanic "json" (parse "{\"a\": {\"b\": 1}}")
  let text = "alpha beta\nbeta gamma\ngamma\n"
  let s = "  banana split  "
  resultOrPanic "setup" (writeFile "notes.txt" text)
  -- cells
```

```medaka-nocheck: setup only; the table that follows holds the cells that complete this program
import fs.{mkdirAll}
import string.{trim}

main =
  let sh script = runCommand "sh" ["-c", script]
  let stdout (_, out, _) = out
  let merged (_, out, err) = out ++ err
  resultOrPanic "setup" (mkdirAll "src")
  resultOrPanic "setup" (writeFile "src/a.mdk" "")
  resultOrPanic "setup" (writeFile "src/b.mdk" "")
  -- cells
```

| Python or shell | scripts | Medaka |
|---|---:|---|
| `os.environ.get("K", "d")`, `${K:-d}` | 7,176 | `println (getEnvOr "NO_SUCH_VARIABLE" "default")` |
| `print(f"total: {1 + 2}")`, `echo "total: $((1 + 2))"` | 6,557 | `println "total: \{1 + 2}"` |
| `open(p, "w").write(t)`, `echo t > p` | 6,176 | `resultOrPanic "write" (writeFile "out.txt" "hello\n")` |
| `s.replace("a", "o")` | 6,165 | `println (replaceAll "a" "o" s)` |
| `s.strip()` | 6,165 | `println (debug (trim s))` |
| `s.split(",")` | 6,165 | `println (debug (split "," "a,b,c"))` |
| `open(p).read()`, `cat p` | 6,105 | `println (debug (readFile "out.txt"))` |
| `a \| b` | 5,872 | `println (debug ([3, 1, 2] \|> sort \|> reverse))` |
| `cmd 2>&1`, `subprocess.run(..., stderr=STDOUT)` | 4,974 | `println (debug (map merged (sh "echo out; echo err >&2")))` |
| `cd d && cmd` | 4,315 | `println (debug (map stdout (sh "cd src && ls")))` |
| `$?`, `proc.returncode` | 4,292 | `println (debug (sh "echo out; echo err >&2; exit 2"))` |
| `for x in xs:` | 3,749 | `each println ["a", "b"]` |
| `$(cmd)`, `subprocess.check_output` | 3,079 | `println (debug (map (trim << stdout) (runCommand "echo" ["hi"])))` |
| `grep beta file` | 2,651 | `each println (filter (contains "beta") (lines text))` |
| `tail -n 1 file` | 2,179 | `println (debug (map last (readLines "notes.txt")))` |
| `head -n 2 file` | 1,807 | `println (debug (take 2 (lines text)))` |
| `mkdir -p a/b/c`, `os.makedirs(p, exist_ok=True)` | 1,555 | `resultOrPanic "mkdir" (mkdirAll "a/b/c")` |
| `sys.argv[1:]`, `"$@"` | 1,328 | `println (debug (args ()))` |
| `sed 's/b+/B/g'`, `re.sub(r"b+", "B", s)` | 1,255 | `println (R.replaceAll (R.mustCompile r"b+") "B" "abba")` |
| `[x * x for x in xs if x % 2 == 0]` | 1,253 | `println (debug (map (x => x * x) (filter isEven [1, 2, 3, 4])))` |
| `rm f`, `os.remove(f)` | 1,249 | `resultOrPanic "rm" (removeFile "out.txt")` |
| `re.findall(r"\d+", s)` | 1,051 | `println (debug (map matchText (R.findAll digits "a1b22")))` |
| `printf "%.2f"`, `f"{x:.2f}"` | 882 | `println (toFixed 2 3.14159)` |
| `sorted(xs, key=len)` | 789 | `println (debug (sortOn stringLength ["ccc", "a", "bb"]))` |
| `wc -l file` | 777 | `println (debug (map length (readLines "notes.txt")))` |
| `cp a b`, `shutil.copy(a, b)` | 712 | `resultOrPanic "cp" (copyFile "notes.txt" "copy.txt")` |
| `json.loads(s)["a"]["b"]` | 679 | `println (debug (atPath ["a", "b"] doc))` |
| `basename p`, `os.path.basename(p)` | 552 | `println (basename "src/lib/main.mdk")` |
| `sort \| uniq -c`, `Counter(xs)` | 507 | `println (debug (entries (countBy (x => x) ["a", "b", "a"])))` |
| `diff -u a b`, `difflib.unified_diff` | 336 | `print (unified 1 ("old", "a\nb\n") ("new", "a\nB\n"))` |

Where a count is shared (the three string idioms), the survey did not separate them.
A cell that prints nothing, such as the `mkdirAll` one, is a statement whose effect is the point.
