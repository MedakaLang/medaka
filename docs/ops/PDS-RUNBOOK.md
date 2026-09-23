# PDS-RUNBOOK.md — the release ritual for a PDS deploy

**Status:** written ahead of the first G-QUIET deploy. #2972's H1 criterion
closes only once this runbook has been followed, step by step, for a real
deploy — writing this file is not that event.

This is the ritual around a deploy: tag, verify, decide what must be green,
soak, roll back, and handle an incident. The procedure itself — building,
installing, and configuring `pds serve` — is
[`PDS-DEPLOY.md`](PDS-DEPLOY.md); this document never repeats its content,
only points at the section that applies at each step.

## 1. Tag the commit

No release-tagging convention exists yet anywhere in this repository, and no
tag of any kind currently exists on this repo (`git tag --list` and `git
ls-remote --tags origin` both come back empty). `AGENTS.md` names an
`oracle-frozen` tag as "preserves the last `lib/`-present commit," but that
tag does not actually exist on the remote — whatever state that prose
describes, it is not reflected in `git ls-remote --tags origin` today, and
this runbook does not rely on it existing. This runbook establishes the PDS
convention by reusing, rather than inventing, the value [`PDS-DEPLOY.md`'s
"Versioned releases and rollback"](PDS-DEPLOY.md#versioned-releases-and-rollback)
section already computes for the release directory name:

```sh
STAMP=$(git rev-parse --short=9 HEAD)
git tag "pds-deploy-$STAMP" HEAD
git push origin "pds-deploy-$STAMP"
```

Run this against a **clean checkout**. `$STAMP` itself (`git rev-parse
--short=9 HEAD`) has no "dirty" concept — the `-dirty` suffix `PDS-DEPLOY.md`
describes is appended by `--stamp-build` to the commit baked into the
*binary's* version stamp (what `pdsd --version` reports) when the working
tree isn't clean at build time, not to `$STAMP` or to this tag's name. Build
from a clean checkout anyway: if it isn't, the binary's baked stamp will
carry `-dirty` and disagree with both the clean `$STAMP` tag and the release
directory name computed from it, breaking step 2's provenance match even
though nothing about the tag itself is wrong.

## 2. Provenance match against the tag (D3)

Once the release is built and the symlink is live, confirm the deployed
binary is the tagged commit and nothing else — the exact mechanism (why
`pdsd --version` and `readlink /opt/pds/current` should always name the same
commit, and what a mismatch means) is in `PDS-DEPLOY.md`'s ["Versioned
releases and rollback"](PDS-DEPLOY.md#versioned-releases-and-rollback)
section; this step is only the checklist over it:

```sh
git rev-parse --short=9 "pds-deploy-$STAMP"   # the tagged commit
pdsd --version                                # must name the same commit
readlink /opt/pds/current                     # must end in .../releases/$STAMP
```

All three must agree. A mismatch is a stop-the-deploy condition, not a note
for later.

## 3. The gate set that must be green

**Never hand-type this list.** Derive it, per `[W-REQUIRED-CHECKS]` in
`AGENTS.md`:

```sh
gh api repos/MedakaLang/medaka/rulesets --jq '.[]|select(.enforcement=="active")|.id' | while read -r id; do
  gh api "repos/MedakaLang/medaka/rulesets/$id" \
    --jq '.rules[]|select(.type=="required_status_checks")|.parameters.required_status_checks[].context'
done
```

Confirm every context this prints is green on the deploy commit before
tagging (the tag should land on a commit that already merged through the
queue, so this is normally already true — re-check it anyway, don't assume).

**The merge-tier arm of `pds/test/signing_parity` IS in that required-check
set** (it runs in `gates_3`, per `test/gates.toml`) — the ordinary required-
check derivation above already covers it. **One ARM of it is NOT covered
that way and must be checked separately.** The gate's `SIGNING_DEEP=1` arm
(`pds/test/signing_parity.sh` with `SIGNING_DEEP=1`, #1962 — G4 in
`PDS-LAUNCH-PLAN.md` §2.G) runs only on the nightly tier, not per-PR, so it
never appears in the ruleset's required-check set the way the merge-tier arm
does. That nightly arm must be confirmed green against the **exact deploy
commit** separately, every deploy:

```sh
gh api repos/MedakaLang/medaka/actions/workflows/nightly.yml/runs \
  --jq '.workflow_runs[] | select(.head_sha=="'"$(git rev-parse HEAD)"'") | "\(.id) \(.conclusion)"'
gh api repos/MedakaLang/medaka/actions/runs/<id>/jobs \
  --jq '.jobs[] | select(.name | contains("signing_parity")) | "\(.name) \(.conclusion)"'
```

The job's YAML id is `pds-signing-parity`, but that id never appears in
`.jobs[].name` — the filter above matches on the job's `name:` field, which
is `"pds/test/signing_parity.sh SIGNING_DEEP=1 (the eval and interpreted-
WasmGC arms — #1962)"` in `.github/workflows/nightly.yml` (confirmed present
in this tree at the time this runbook was written). If the deploy commit has
never had a nightly run against it (e.g. it merged after the last nightly
kicked off), trigger one explicitly rather than deploying on an unconfirmed
commit:

```sh
gh workflow run nightly.yml --ref <deploy-branch-or-tag>
```

then re-poll the two commands above once it completes.

## Graceful stop during a soak

A `pdsd` started with `pds serve` opts into SIGTERM handling once it has bound
its listener. On SIGTERM it logs `serve: SIGTERM received; admission stopped;
draining connections`, closes the listener, finishes already-framed requests
(including their synchronous stage/persist/promote sequence), stops accepting
new requests on kept-alive sockets, and sends WebSocket subscribers a normal
1000 Close frame. Once connections retire it logs `serve: shutdown complete;
connections drained` and exits 0. Check both lines and the exit status in
the journal; a missing completion line is not a clean stop. No signal handler
runs repository code: a nonblocking POSIX self-pipe wakes the cooperative
scheduler. Other Medaka binaries retain the ordinary SIGTERM default.

A peer that stops sending a request can use its existing 60-second request
budget; a response write can take another 30 seconds. The drain has a
95-second monotonic deadline after admission stops: if it expires, the server
logs `serve: shutdown deadline (95s); terminating remaining connections` to
stderr and exits between scheduler steps. This is a forced stop, **not** a
successful drain; investigate stalled requests and verify the event-log
recovery line on restart before counting more soak time. A blocking filesystem
operation inside one synchronous persist step is not preemptible by the
scheduler; the checked-in `pds/pds.service` pins `TimeoutStopSec=110s`,
leaving 15 seconds after the app's deadline (systemd's 90-second default is
too short). Verify the installed unit still carries that setting and treat a
supervisor-forced kill as a crash/recovery event. A deliberate stop still resets the uninterrupted soak
clock; do not stitch two windows across it.

## 4. The soak rule

`docs/ops/PDS-LAUNCH-PLAN.md` names a soak ("G-QUIET closes. Soak begins.",
§4 step 6) and reserves its duration explicitly to Val: "a number Val sets
when each earlier gate closes, not a number this document guesses now"
(§4, between the milestone table and the H-criteria table). This runbook
does not guess one either — the one rule the plan does fix is the counting
convention, which this runbook restates:

A soak is counted from the **last S0/S1 fix deployed** — not from first
boot. If a fix for a silent-wrongness or loud-breakage defect is deployed on
day 2 of a soak already in progress, the clock restarts from that deploy, not
from the original one. The duration itself is Val's call at the time each
soak begins; do not deploy against an assumed number.

**That is the calendar clock. There is a second one, and it is not a
calendar.** `PDS-LAUNCH-PLAN.md` §1 states both: the uninterrupted-run clock
resets on *every* restart — a deploy, a config change, a crash, a reboot —
whatever the severity. The run clock matters to these observations, but retention also depends
on an append counter:

| property | observation requirement |
|---|---|
| refresh-token rotation against a live token | > 2h since a token was issued |
| relay reconnecting after the retention window | > 72h and a natural sweep after the append trigger |
| event-log retention sweep | every 256 appends; only entries older than 72h then expire |
| RSS drift with a readable trend | days |

So during a soak:

- **Deploys are allowed** — the calendar clock only resets on S0/S1 — but
  **batch them.** Each restart zeroes the run clock.
- **Record every deploy on #1697** with its date and the severities it carried.
  Two clocks cannot be reconstructed afterwards from a tag list alone.
- **At least one ≥72h window with no restart must fall inside the soak** before
  its gate closes. It is not by itself a sweep: record a natural 256th append
  after entries have aged past 72h and the relay's reconnect to test `#3005`.
  Otherwise the run demonstrated availability, not retention correctness.

### Synthetic mixed-load evidence (C7 / #2957)

`pds/nightly/load_harness.sh` runs only against its private loopback servers
and generated corpus. It concurrently drives read clients, authenticated
`createRecord` writers and a live `subscribeRepos` consumer. Timestamped
samples report the loaded `pdsd` process's RSS (`ps`, KiB), the loaded data
directory's allocated size (`du -sk`, KiB), request/sample errors, and the
server PID. Initial, peak across all samples, and final values and continuity
are printed; an exited server, nonzero request errors, an acknowledged writer
rkey missing from or duplicated in post-attach `#commit` operation paths, an
unexpected relay operation path, or a configured bound breach fails the run.
Each bound grades the maximum sampled increase from the initial value, even
if the final value falls: RSS as a percentage of initial RSS and disk in KiB.
These are synthetic measurements, not production observations.

A bounded shakeout, not a soak sign-off, can be run off-hours in an isolated
checkout with the native compiler built:

```sh
LOAD_RECORDS=32 LOAD_BLOBS=2 LOAD_CLIENTS=2 LOAD_WRITE_CLIENTS=1 \
LOAD_SUBSCRIBER=1 LOAD_DURATION_MS=6000 LOAD_TICKS=30 \
LOAD_INTERVAL_MS=100 LOAD_WARMUP_SECONDS=1 LOAD_RESOURCE_SAMPLE_SECONDS=1 \
MEDAKA_ROOT=<isolated-checkout> MEDAKA=<isolated-checkout>/medaka \
sh <isolated-checkout>/pds/nightly/load_harness.sh
```

An isolated 32-record, 2-blob shakeout on 2026-09-23 recorded 91 successful
read requests, 44 authenticated writes, 44 **post-attach** `#commit` events
(no replay), zero request errors and one server PID across 14 timestamped
samples. Loaded-server RSS went from 8,928 to 13,212 KiB (+47.984%);
loaded data-directory size went from 456 to 2,084 KiB (+1,628 KiB). This
~13-second workload phase is not an RSS/disk bound or a full soak result.

For a full off-hours observation, an operator must first choose and approve
all three values below; the harness invents no resource bound or duration:

```sh
LOAD_FULL_SOAK=1 LOAD_DURATION_MS=<operator-approved-ms> \
LOAD_MAX_RSS_GROWTH_PCT=<operator-approved-percent> \
LOAD_MAX_DISK_GROWTH_KIB=<operator-approved-KiB> \
LOAD_RECORDS=<operator-approved-record-count> LOAD_BLOBS=<operator-approved-blob-count> \
LOAD_CLIENTS=<operator-approved-reader-count> LOAD_WRITE_CLIENTS=<operator-approved-writer-count> \
LOAD_SUBSCRIBER=1 LOAD_TICKS=<operator-approved-sample-count> \
LOAD_INTERVAL_MS=<operator-approved-interval-ms> \
MEDAKA_ROOT=<isolated-checkout> MEDAKA=<isolated-checkout>/medaka \
sh <isolated-checkout>/pds/nightly/load_harness.sh
```

The RSS limit grades the highest sampled RSS against the initial sample as a
percentage; the disk limit grades the highest sampled disk usage against the
initial sample in KiB. A transient sampled breach is not forgiven by a later
drop. Set `LOAD_RESOURCE_SAMPLE_SECONDS` to
an operator-chosen sampling cadence for the observation. No numerical limit,
production/off-hours authorization, or live-run evidence is supplied by this
procedure; the full observation and #2957 sign-off remain blocked until those
are separately approved and observed. The event-log retention sweep is driven
by **every 256 appends**, not by elapsed uptime: a 72h duration does not itself
cause a sweep. A natural retention-sweep observation remains pending until the
append-count trigger is reached and its effects are recorded.

⚠️ **`systemctl restart` during a soak still costs the uninterrupted window above**, even
when the change is trivial. It no longer costs every session: the open session
set is persisted and read back at startup, so a restart is not a logout and the
operator's own use of the service carries across one. A session lost across a
restart is a defect now, not the design — `pds/test/serve_e2e.sh` case 9g is
what holds that.

## 5. Rollback

Rollback is the exact D3 command from `PDS-DEPLOY.md`'s ["Versioned releases
and rollback"](PDS-DEPLOY.md#versioned-releases-and-rollback) `Rollback`
subsection — repointing the symlink to a previously known-good stamp and
restarting the unit:

```sh
ln -sfn /opt/pds/releases/<previous-stamp> /opt/pds/current
systemctl restart pds
```

**Wait for readiness before step 2.** `systemctl is-active` goes green the
instant systemd forks; this server needs ~4–5 s more before it is listening,
and probing in that window reports a working rollback as a failed one — which
is exactly what the first D3 rehearsal did (`#3106`). The signal is the
server's own line:

```sh
t0=$(date +%s); systemctl restart pds
until journalctl -u pds --since "@$t0" | grep -q 'serve: listening on'; do sleep 1; done
```

Then re-run step 2 (provenance match) against the rolled-back commit before
considering the rollback complete — a rollback that doesn't verify its own
target is the same defect this whole check exists to catch.

**Rehearsed 2026-09-17**, both directions, on the live deployment: rolled back
to the previous stamp, confirmed the older binary served and the repo head was
unchanged, rolled forward, provenance matched each way. D3's "run once" clause
is discharged; the transcript is on #1697.

## 6. Incident procedure

This is a **single-operator deployment**. There is no on-call rotation and
this runbook will not invent one. If the service goes down at an hour Val is
asleep or otherwise unavailable:

- **It stays down until morning.** No pager, no second responder — that is
  the honest current state, not a gap this document is deferring.
- On discovery, check the journal first (`journalctl -u pds -n 200`), then
  the access log for the last served request before the gap, then
  `pdsd --version` / `readlink /opt/pds/current` (step 2) to rule out an
  unnoticed bad deploy before assuming an unrelated crash.
- If the cause is a regression from the most recent deploy, roll back (step
  5) before investigating further — restoring service takes priority over
  root-causing it live.
- The first failed-state transition after arming the alert instance attempts
  one push; later transitions of that same unit are the same incident and
  are no-ops while the alert instance remains active (exited). Its one-start
  limit also suppresses retries if the first delivery fails. Check the journal
  for a failed delivery — there is no automatic retry. A missing push is not
  proof the service recovered: the separate health-gated dead-man's switch
  stops receiving pings while the PDS is unhealthy and can still report an
  ongoing outage. See [Down-detection](PDS-DEPLOY.md#down-detection-two-mechanisms-deliberately).
- **After** the service is healthy and this incident has been acknowledged,
  re-arm its push path with `systemctl reset-failed pds-alert@pds.service`
  **then** `systemctl stop pds-alert@pds.service` (for a backup failure,
  substitute `pds-alert@pds-backup.service`). Resetting clears a failed-
  delivery start limit; stopping clears the successful active (exited) state.
  Do this in that order: after stopping, an inactive instance may unload and
  `reset-failed` would report "Unit not loaded". Both states must be cleared
  before a later incident can alert again. Do not re-arm
  while the source service is flapping; that permits another push for the
  same outage. A manager reboot also clears this in-memory boundary, so it
  is not a persistent incident ledger.
- Any S0/S1 found during recovery restarts the soak clock (step 4) once the
  fix is deployed, not once the service is merely back up.

## 6a. Assume breach: the box is compromised

Criterion B16 (`PDS-LAUNCH-PLAN.md` §2.B) asks for this in writing, per
identity kind, before the first real post. It is a different incident class
from §6: there, the service is down and the question is how to restore it;
here, the service may be running perfectly and the question is what an
attacker now holds.

**What is on the box, and what holding it means.** The signing key
(`/opt/pds/secrets/key.hex`), the session-token secret, and the account
credential. An attacker with all three can sign commits as this DID, mint
sessions, and answer as this server. The backup *recipient* public key is
there too and is not a secret; the age private key is not on the box, so
archives already written stay unreadable.

**For a `did:web` account — the G-QUIET and G-ANNOUNCE identity — there is no
key rotation.** The DID document lives on this host, so whoever controls the
host controls the identity; that is ruling **R2**, accepted with its price
stated. Recovery is therefore not "rotate the key", it is:

1. Take the host off the internet — remove the DNS record first, since that
   stops the world reaching it even while you still can.
2. Stand up a new account on a **new hostname** from the last good backup, and
   treat the old DID as burned. The old handle can be re-pointed at the new
   DID; the old DID cannot be reclaimed from an attacker who holds the box.
3. Say so publicly. A PDS whose key is compromised can sign anything, so silence
   about a known breach is the one response that is actually dishonest.

**For the `did:plc` account — G-MIGRATE and after — this inverts**, which is
the whole reason L1 orders the identities as it does. Rotation keys are held
off-box (criterion G2), so a PLC operation signed with them re-points the DID
at a restored instance and the identity survives the host. That procedure is
#2609's, rehearsed twice before it is ever needed.

**In both cases the backups are the recovery path and the archives are safe**,
because the age private key is in a password manager and never on the host
(`PDS-DEPLOY.md` § "Scheduled encrypted backups"). Restore to a *new* box: the
old one is evidence and is not trustworthy again without a rebuild.

## 7. The compiler-upgrade procedure

This is separate from a PDS-code upgrade (redeploying `pds/serve.mdk` against
an unchanged compiler, which is the ordinary case steps 1-5 cover). A `pdsd`
binary rebuilt against a **newer `medaka` compiler** must additionally pass,
before the swap:

1. **`pds/test/signing_parity.sh` with `SIGNING_DEEP=1`** (#1962) — the
   eval-vs-native-vs-WasmGC ECDSA parity check. A compiler change is exactly
   the kind of change this gate exists to catch that an unchanged-compiler
   PDS release doesn't need to re-run.
2. **`pds/test/serve_e2e.sh`** — the full end-to-end server behavior gate.

`pds/test/signing_parity.sh` hard-requires `test/bin/wasm_emit_modules_main`
to exist (it is gitignored, absent on a fresh checkout); build it first, the
same way `.github/workflows/nightly.yml`'s `pds-signing-parity` job does:

```sh
export MEDAKA_EMITTER="$(git rev-parse --show-toplevel)/medaka_emitter"
sh test/wasm/build_wasm_oracle.sh --modules-only
MEDAKA_ROOT="$(git rev-parse --show-toplevel)" SIGNING_DEEP=1 sh pds/test/signing_parity.sh
MEDAKA_ROOT="$(git rev-parse --show-toplevel)" sh pds/test/serve_e2e.sh
```

Both must be green against the rebuilt binary before it replaces the running
one. Neither substitutes for step 3's per-deploy gate confirmation — this is
in addition to it, specifically because a compiler upgrade changes code paths
those two gates cover that a PDS-only change does not touch.

## 8. The announcement footnotes

Drafted **before the soak ends**, not after: `docs/ops/PDS-LAUNCH-PLAN.md`
[§6, "What 'written entirely in Medaka' will mean, honestly"](PDS-LAUNCH-PLAN.md#6-what-written-entirely-in-medaka-will-mean-honestly)
already has the claim text and its TLS/runtime/reference-as-oracle
footnotes. Use that text verbatim; this runbook does not restate or rewrite
it. Before posting, re-read it against the tree as it stands on the day —
the claim must still be true of the deployed commit, not just of the day it
was drafted.
