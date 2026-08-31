# Quick Start

## "Hello World" in Medaka

Every Medaka program begins by declaring a `main`. In Medaka `main` is a
zero-argument value of type `Unit`, normally an effectful expression such as
`println` (write `main = ...`, not `main () = ...` or `main args = ...`).
`medaka run` evaluates `main` for its effects; it never applies `main` as a
function or prints a plain value.
Let's start with a simple program that prints "Hello world!" to stdout.
The quickest way to follow along is the [playground](#), where you can run
every example in this guide right in your browser.

```medaka
main = println "Hello world!"
```

Running it prints:

```medaka-expect
Hello world!
```

As you can see in the previous example, single line comments in Medaka begin with `--`.
Medaka also supports block comments.

```medaka
{- This is a block comment.
   It can span multiple lines.
   This will print 7 to stdout. -}
main = println (2 + 5)
```

```medaka-expect
7
```
