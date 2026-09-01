# owner

owner.mdk — library-mode fixture #5: ownership clause 1 must see a PRIVATE
type declaration (S2-1).

`Gadget` is declared here but NOT exported, so `renderSig` emits no entry
for it.  The owner map used to be built from the RENDERED entries, so it was
blind to this declaration and `rebucketLibraryImpls` fell through to its
name-match clause — filing `Countish Gadget` on `gadget.md` purely because a
module of that name exists in the set, with no warning.  The owner map is
now built from the raw decls, so the impl stays here where the type lives.

## `Countish`

```
interface Countish a
  countOf : a -> Int
```

Anything with a count.

## `Countish Gadget`

```
impl Countish Gadget
```

Must stay on `owner`: `owner` DECLARES `Gadget`, privately.

## `mkGadget`

```
mkGadget : Int -> Int
```

Make a `Gadget`.  Private return type, so the entry renders the name.

