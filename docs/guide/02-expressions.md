# Expressions

Medaka supports basic types and values like integers, strings, booleans, tuples, lists, and arrays.
Top-level values are declared with a name and `=`. The entry to a program is declared
via the special name `main`.

```medaka
int = 5
float = 3.14
bool = True
string = "hello 👋" -- strings are utf8 by default
pair = (False, 7) -- tuples
list = [1, 2, 3] -- a linked list
array = [|"a", "b", "c"|] -- an in-memory array

-- will print [1, 2, 3]
main = println list
```

```medaka-expect
[1, 2, 3]
```

Top-level declarations can't be reassigned.

```medaka-nocheck: intentionally invalid duplicate declaration example
int = 4
int = 5 -- ❌ error!
```

Within an expression we can use a `let ...  in` expression to declare a local binding.

```medaka
list = let five = 5 in [4, five, 6]
```

You can also put `let`s on separate lines for readability, leaving off the `in`.

```medaka
list =
  let five = 5
  [4, five, 6]
```

Medaka bindings are immutable. When you need mutable state, put the value in a `Ref`
cell instead: the binding stays immutable while the cell's contents can change. The
`:=` operator writes the cell, and `!` reads it. This example prints `2`.

```medaka
main =
  let a = Ref 1
  a := 2
  println !a
```

```medaka-expect
2
```

Here `!` means dereference, not Boolean negation. Use `not` to negate a Boolean.

Medaka's type inference means you rarely need to provide explicit type signatures.
Medaka can generally figure out your program's types on its own. However, you are
free to add explicit type signatures to whatever expressions you want. While not
generally required, we highly recommend adding explicit type signatures to your
top-level declarations for readability and documentation.

```medaka
int : Int
int = 4

list = let nums: List Int = [1, 2, 3] in if True then nums else []

pairWithFloat : (String, Float)
pairWithFloat = ("abc", 1.23)
```
