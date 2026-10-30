# diff

Differences between two sequences, and between two texts in the unified
format that `diff -u` prints.

`editScript` compares any two lists and answers with the steps that turn
the first into the second: `Keep` an element, `Delete` one of the first
list, `Insert` one of the second. The script is a shortest one, so it has
as many `Keep`s as the longest common subsequence has elements. Where
several shortest scripts exist, the one returned may differ from the one
another tool picks. Within a run of changes, deletions come before
insertions.

`unified` compares two texts line by line. Lines are cut on LF alone, so a
CR is part of its line, and a final line without its LF differs from the
same line with one.

## Edit scripts

### `Edit`

```
data Edit a
  = Keep a
  | Insert a
  | Delete a
```

One step of an edit script.

```medaka
> Keep 1
Keep 1
```

Instances: `Eq`, `Debug`

### `editScript`

```
editScript : Eq a => List a -> List a -> List (Edit a)
editScript a b
```

A shortest edit script turning the first list into the second.

Runs in time proportional to the combined length of the two lists times
the number of insertions and deletions in the script, so similar inputs
are cheap.

```medaka
> editScript [1, 2, 3] [1, 3, 4]
[Keep 1, Delete 2, Keep 3, Insert 4]
> editScript ['a', 'b'] ['b', 'a']
[Delete 'a', Keep 'b', Insert 'a']
> editScript [1, 2] ([] : List Int)
[Delete 1, Delete 2]
```

## Unified format

### `unified`

```
unified : Int -> (String, String) -> (String, String) -> String
unified ctx _ _
```

Compares two texts and prints the difference in unified format, with
`ctx` unchanged lines around each change.

Each text comes with the label that names it in the two header lines. The
result is empty when the texts are equal. The format has no timestamps,
so the headers are the label alone.

```medaka
> unified 1 ("old", "a\nb\nc\n") ("new", "a\nB\nc\n")
"--- old\n+++ new\n@@ -1,3 +1,3 @@\n a\n-b\n+B\n c\n"
> unified 3 ("old", "same\n") ("new", "same\n")
""
> unified 0 ("old", "") ("new", "x\n")
"--- old\n+++ new\n@@ -0,0 +1 @@\n+x\n"
```

