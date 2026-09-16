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

No release-tagging convention exists yet anywhere in this repository (checked
`git tag` / `git ls-remote --tags origin`, and grepped `docs/` — nothing pins
a scheme; the `oracle-frozen` tag named in `AGENTS.md` is the OCaml-removal
marker, unrelated to releases). This runbook establishes the PDS one by
reusing, rather than inventing, the value [`PDS-DEPLOY.md`'s "Versioned
releases and rollback"](PDS-DEPLOY.md#versioned-releases-and-rollback)
section already computes for the release directory name:

```sh
STAMP=$(git rev-parse --short=9 HEAD)
git tag "pds-deploy-$STAMP" HEAD
git push origin "pds-deploy-$STAMP"
```

Run this against a **clean checkout** — the same "any untracked or modified
file appends `-dirty`" caveat `PDS-DEPLOY.md` states for `$STAMP` applies
here too, and a dirty `$STAMP` would make the tag name disagree with the
release directory name built moments later from the same commit.

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

**One gate is NOT in that list and must be checked separately.** The nightly
signing-parity gate (`pds/test/signing_parity.sh` with `SIGNING_DEEP=1`,
#1962 — G4 in `PDS-LAUNCH-PLAN.md` §2.G) runs on its own nightly tier, not
per-PR, so it never appears in the ruleset's required-check set the way a
merge-tier gate does. It must be confirmed green against the **exact deploy
commit** separately, every deploy:

```sh
gh api repos/MedakaLang/medaka/actions/workflows/nightly.yml/runs \
  --jq '.workflow_runs[] | select(.head_sha=="'"$(git rev-parse HEAD)"'") | "\(.id) \(.conclusion)"'
gh api repos/MedakaLang/medaka/actions/runs/<id>/jobs \
  --jq '.jobs[] | select(.name | contains("signing_parity")) | "\(.name) \(.conclusion)"'
```

The job to look for is `pds-signing-parity` (step name `"pds/test/signing_parity.sh
SIGNING_DEEP=1 (the eval and interpreted-WasmGC arms — #1962)"` in
`.github/workflows/nightly.yml`, confirmed present in this tree at the time
this runbook was written). If the deploy commit has never had a nightly run
against it (e.g. it merged after the last nightly kicked off), trigger one
explicitly rather than deploying on an unconfirmed commit:

```sh
gh workflow run nightly.yml --ref <deploy-branch-or-tag>
```

then re-poll the two commands above once it completes.

## 4. The soak rule

`docs/ops/PDS-LAUNCH-PLAN.md` names a soak ("G-QUIET closes. Soak begins.",
§4 step 6) but does not itself state a duration. This runbook sets one:

**72 hours**, counted from the **last S0/S1 fix deployed** — not from first
boot. If a fix for a silent-wrongness or loud-breakage defect is deployed on
day 2 of a soak already in progress, the clock restarts from that deploy, not
from the original one. Rationale: a single-operator deployment with no other
traffic to surface a defect faster needs enough elapsed wall time under real
use (the announcement, once G-ANNOUNCE closes) to catch a bug that doesn't
show up in the first few requests; 72 hours is long enough to span at least
one full day/night cycle of actual usage twice over, short enough not to
indefinitely stall the next milestone on a quiet server.

## 5. Rollback

Rollback is the exact D3 command from `PDS-DEPLOY.md`'s ["Versioned releases
and rollback"](PDS-DEPLOY.md#versioned-releases-and-rollback) `Rollback`
subsection — repointing the symlink to a previously known-good stamp and
restarting the unit:

```sh
ln -sfn /opt/pds/releases/<previous-stamp> /opt/pds/current
systemctl restart pds
```

Re-run step 2 (provenance match) against the rolled-back commit before
considering the rollback complete — a rollback that doesn't verify its own
target is the same defect this whole check exists to catch.

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
- Any S0/S1 found during recovery restarts the soak clock (step 4) once the
  fix is deployed, not once the service is merely back up.

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

```sh
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
