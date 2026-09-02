# owner

## `Countish`

```
interface Countish a
  countOf : a -> Int
```

Anything with a count.

## `mkGadget`

```
mkGadget : Int -> Int
```

Make a `Gadget`.  Private return type, so the entry renders the name.

## Instances

- `Gadget`: [`Countish`](#countish-gadget)

### `Countish Gadget`

```
impl Countish Gadget
```

Must stay on `owner`: `owner` DECLARES `Gadget`, privately.

