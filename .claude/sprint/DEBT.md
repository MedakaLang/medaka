# Stage A sprint — DEBT ledger

**Append-only, one row per landed bite.** Written by the sub-orchestrator when it commits a
bite; the implementer supplies the row's content with its edit.

> ⚠️ **This ledger is the deliverable that makes the testing round possible.** The diff alone
> is not. An agent that skips a row has not saved time — it has converted a deferred check into
> a check nobody will ever know to make.

**`could move:` may not be left blank.** "Nothing, and here is why" is a valid entry; silence is
not. The testing round works this column first, because the gate suite is structurally blind to
this run's characteristic failure — a silently widened acceptance. Value goldens cannot see a
diagnostic-only change, and absence probes cannot see an undercount.

Row format (§4):

```
### <bite id> — <unit> — <one-line description>
sites:      <the files:lines actually touched>
transform:  <what was applied>
could move: <what acceptance behavior could plausibly have changed, incl. "nothing — pure rename">
unchecked:  <what I did not verify, and why>
```

---

<!-- rows appended below, in landing order -->
