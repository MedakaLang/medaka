# Effects III: Labels, Manifests, and the Host

The built-in labels describe what the runtime can do. A program can also declare
labels of its own, and the reason to do so is the subject of this chapter: a row is
not only a check inside the program but a *manifest* that whoever runs the program
can read before deciding what to grant it.

## Declaring a label

A label is declared at top level with `effect`, and used in rows like any built-in:

```medaka
effect Audit

audit : String -> <Audit> Unit
audit _ = ()

transfer : Int -> <Audit, Stdout> Unit
transfer amount =
  audit "transfer \{amount}"
  putStrLn "moved \{amount}"

main = transfer 10
```

```medaka-expect
moved 10
```

Look at `audit`. Its body is `()`, which performs nothing, yet its signature says
`<Audit>`. That is allowed, since a body may perform less than its signature
claims, and it is how a label enters a program: a signature *requires* the label,
and from then on every caller is charged with it. `check` prints
`main : <Audit, Stdout> Unit`.

In a real system the function behind a label is usually a host import, an `extern`
the platform provides (`extern kvGet : String -> <KV> String`), and the label is
the platform's name for that capability. But nothing about a label depends on
that. `Audit` above is pure Medaka, and it still tracks: a function that calls
`audit` without declaring `Audit` is refused,

```
error: labels.mdk:8:18: Effectful value used where <Stdout> is allowed, but it performs <Audit>
  |
8 |   audit "transfer \{amount}"
  |                   ^
```

and so is a row that mentions a label nobody declared:

```
error: labels.mdk:1:19: Unknown effect: Audit
  |
1 | audit : String -> <Audit> Unit
  |                    ^
```

`IO` does not cover a label you declare. It is the join of the ten built-in host
labels and nothing else, so a function that calls `audit` under an `<IO>` bound is
refused the same way:

```
error: labels.mdk:8:8: Effectful value used where <IO> is allowed, but it performs <Audit>
  |
8 |   audit "x"
  |         ^
```

This is deliberate. `<IO>` means "may touch the host"; a label you declare means
something the host does not know about until you tell it.

## Labels across modules

A label is exported with `export effect`, and importing anything from the module
brings the label into scope:

```medaka-project
-- file: audit.mdk
export effect Audit

export
audit : String -> <Audit, Stdout> Unit
audit msg = putStrLn "audit: \{msg}"

-- file: main.mdk
import audit.{audit}

transfer : Int -> <Audit, Stdout> Unit
transfer amount =
  audit "transfer \{amount}"
  putStrLn "moved \{amount}"

main = transfer 10
```

```medaka-expect
audit: transfer 10
moved 10
```

A label's identity is its declaring module plus its name, so two modules that each
declare an `Audit` have declared two different labels. Import both and a row that
says `<Audit>` is refused rather than guessed at:

```
error: labels.mdk:4:18: Ambiguous effect label: 'Audit' is declared by both `a` and `b`, and both declarations are in scope. A label is identified by the module that declares it, so these are two different effects and a row cannot tell them apart by spelling. Import only one of those modules here, or rename one of the declarations
  |
4 | both : String -> <Audit> Unit
  |                   ^
```

## The manifest

Because a row is inferred for every binding and checked against every signature,
the row of a program's entry point is a verified statement of everything the
program can do. `medaka manifest` prints it as TOML:

```
$ medaka manifest labels.mdk
[package.capabilities]
Audit = true
Stdout = true
```

The block is one entry per label in `main`'s row. A label with no parameter
renders as `true`; [chapter 4](effects-4-authority.md) shows what a parameterized
one renders as. `--fn name` picks a different entry point:

```
$ medaka manifest labels.mdk --fn transfer
[package.capabilities]
Audit = true
Stdout = true
```

The point of the manifest is that it cannot lie. It is not a declaration the
author wrote; it is the join of the rows of every primitive the entry can reach,
and the escape check has already refused every attempt to hide one. Adding a
dependency that quietly opens a network connection changes the manifest, and a
manifest checked into a repository would show the change in review.

## Checking a policy

`medaka check-policy` takes the other side: a list of what the host is willing to
grant, and a verdict. Its shape comes from a plugin scenario, where a host loads a
module and calls a function named `transform` on each request:

```medaka
effect Audit

audit : String -> <Audit> Unit
audit _ = ()

transform : String -> <Audit, Stdout> String
transform request =
  audit "request \{request}"
  putStrLn "handling \{request}"
  "ok"
```

```
$ medaka check-policy plugin.mdk --fn transform --allow Stdout
rejected. transform requires <Audit, Stdout>. Not permitted by policy {Stdout}
   reached via: transform → audit
```

The verdict names the label that is not allowed and the call chain that reaches
it. Exit code 1. Widen the policy and the module is accepted, and the tool then
runs the plugin once on a sample request to show it working:

```
$ medaka check-policy plugin.mdk --fn transform --allow Audit,Stdout
accepted. transform requires only <Audit, Stdout>
handling X-Forwarded-For: 192.168.1.1
   transform "X-Forwarded-For: 192.168.1.1" = ok
```

> ⚠️ **The sample run assumes a `String -> String` entry.** `check-policy` on a
> function of any other shape reports the verdict correctly but then fails while
> trying to apply it to the sample string, so an accepted module can still exit 1.
> Use `medaka manifest` to inspect an entry of another shape; the sample run is
> tracked as [#3329](https://github.com/MedakaLang/medaka/issues/3329).

Together the two commands are the whole story of "effects as capabilities". The
compiler computes what a module needs. The host decides what it is willing to
give. Neither has to trust the other's prose.

## What the host charges

The manifest is the row of *invoking* the entry, which is more than the row of
forcing it. If an entry returns a function, the host may call that function, so
its latent row is charged too:

```medaka
makeLogger : String -> String -> <Stdout> Unit
makeLogger prefix = msg => putStrLn "\{prefix}: \{msg}"
```

```
$ medaka manifest closures.mdk --fn makeLogger
[package.capabilities]
Stdout = true
```

`makeLogger "app"` performs nothing, but a host holding the result can make it
print, so the manifest says `Stdout`. The rule is by position: an arrow the entry
*hands out* (its result, a field of a record it returns, an element of a list it
returns) is charged; an arrow the entry *takes* (a callback parameter) is the
host's own function and is not. The same reading applies through data the entry
returns, and a slot whose variance the compiler cannot see is charged as if it
were both.

## `main` is the grant root

Inside the language, `main` is an ordinary binding. It may declare any row, or
none, and the escape check treats its signature like any other:

```medaka
main : <Stdout> Unit
main = putStrLn "bounded main"
```

```medaka-expect
bounded main
```

There is no rule that `main` may only use certain labels. Bounding a program is
the host's job, done by reading the manifest, and the type system's job ends at
computing it truthfully. A `main` declared `<Stdout>` that calls `println` is an
error, but only because `println` is `<IO>` and `<IO>` does not fit `<Stdout>`,
not because of anything special about `main`.

## Foreign code

An `extern` you declare yourself is a call into C, and the compiler makes you say
so. The row must name `FFI`:

```
error: ffi.mdk:1:14: Foreign declaration 'cAbs' does not name the 'FFI' effect in its result row. Every user-declared 'extern' is a foreign call, so its declared row must say so: write '<FFI>' (or '<FFI "libname">' to name the library), joined with whatever else the row already names — 'String -> <Net "a.com/*"> String' becomes 'String -> <FFI, Net "a.com/*"> String'. The compiler does not add the label for you: a row it rewrote would no longer be the row you read
  |
1 | extern cAbs : Int -> Int
  |               ^
```

The parameter names the library, as a statement about where the call goes rather
than something the compiler enforces:

```medaka
extern cSqrt : Float -> <FFI "libm"> Float

root : Float -> <FFI "libm"> Float
root x = cSqrt x
```

`FFI` is not part of `IO`. A function declared `<IO>` cannot call a foreign
function:

```
error: ffi.mdk:4:17: Effectful value used where <IO> is allowed, but it performs <FFI>
  |
4 | wrapped n = cAbs n
  |                  ^
```

The reason is the same as for user labels, sharpened: foreign code can do anything
at all, including things the ten labels do not describe, so a boundary has to opt
into it by name.

The externs in the standard library's runtime catalog are the exception. They are
the effect vocabulary itself, not foreign declarations, so they carry the labels
from the table in chapter 1 with no `FFI`. Their declared rows are the trusted
base of the whole system: after checking, rows are erased, so a catalog extern
that claimed a narrower row than it performs would be a hole nothing downstream
could detect. That is also why redeclaring a catalog name with a narrower row is
refused:

```
error: ffi.mdk:1:18: Foreign declaration 'putStrLn' redeclares a built-in runtime name with a NARROWER effect row: the built-in performs <Stdout>, this declaration claims <>, which does not cover <Stdout>. A local extern whose name matches a stdlib/runtime.mdk built-in is always lowered as that built-in, whatever the local signature says — so 'putStrLn' really does perform <Stdout>, and every caller typechecked against this declaration would be told it does not. Declare the built-in's own row `<Stdout>` (a WIDER row such as `<IO>` is also accepted — over-declaring is safe), or rename the extern to a name the runtime does not already define
  |
1 | extern putStrLn : String -> <> Unit
  |                   ^
```

So far every label has been all-or-nothing: a program may read files or may not.
The next chapter refines that to *which* files.
