# Stage B / Phase 3′ (`B-2.2`) — DEBT

Append-only, one row per landed bite. The orchestrator commits; the implementer supplies the row.
**`could move:` and `nearest miss:` may not be blank** — *"nothing, and here is why"* is valid,
silence is not.

```
### <bite id> — <one-line description>
sites:        <files:lines actually touched>
transform:    <what was applied>
could move:   <what acceptance behaviour could plausibly have changed>
nearest miss: <the nearest program this does NOT cover, and what it does today>
engines:      <LLVM / wasm / eval / core_ir_eval — which arms moved, which peers are owed>
unchecked:    <what was not verified, and why>
```

⚠️ **A row is owed for any behaviour delta the repair round's differential DETECTS**, not only
those an implementer recognized — written at detection time, by the round that found it.

---
