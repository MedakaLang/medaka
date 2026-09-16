# PDS-CONFORMANCE-WALKTHROUGH.md — criterion A8, run by hand from the official app

**Status:** written ahead of the first G-QUIET deploy. Writing it first is the
only order in which it is worth anything: criterion A8 of
[`PDS-LAUNCH-PLAN.md`](PDS-LAUNCH-PLAN.md) requires "each step's expected
observation written before the run", and this file is that writing. **#2940
closes on a completed transcript, not on this file existing** — the same
relationship [`PDS-RUNBOOK.md`](PDS-RUNBOOK.md) has to a real deploy.

This document is the walkthrough only. The deploy that precedes it is
[`PDS-DEPLOY.md`](PDS-DEPLOY.md); the release ritual around that deploy is
[`PDS-RUNBOOK.md`](PDS-RUNBOOK.md). Neither is repeated here.

## 0. Why the expected observation is written first

A walkthrough run without written expectations grades itself against whatever
happened. Every step below therefore names what the app should show **and**
what the server should log, before anyone has seen either.

Two consequences worth stating plainly:

- **The "expected route" column is a prediction, not a specification.** The
  official Bluesky app's exact call sequence is not pinned anywhere in this
  repository — the route corpus
  (`pds/test/vectors/pds_route_registration_corpus.txt`) says what the
  reference PDS *registers*, not what the app *calls*. A step whose access log
  shows a different route than predicted here is **data, not a failure**:
  record the route it actually called and correct this file. A step that shows
  a 404 or a 400 is a failure.
- **A step that "worked" but logged nothing is a failure.** The access log is
  the observability criterion (E1) being exercised at the same time. Silence
  where a line was predicted is the [W-QUIETER] shape and is graded as a
  defect, not as a pass.

## 1. Before you start

**Preconditions.** All of these are steps of `PDS-DEPLOY.md`, not of this
document; the walkthrough assumes they are already true.

- The service is running under systemd and Caddy is serving the hostname over
  TLS.
- `PDS-RUNBOOK.md` steps 1–3 are complete: the commit is tagged, the
  provenance match passes, and the required-check set plus the nightly
  `SIGNING_DEEP=1` arm are confirmed green **on the deployed commit**.
- The egress proxy is installed (`PDS-DEPLOY.md` step 8) with **two** rows —
  the appview and the chat service. Without the chat row, steps B7 and B8 are
  not reachable at all; see §5.
- A second Bluesky account exists, on `bsky.social`, to follow and to exchange
  a DM with. It is the other half of four of the steps below and cannot be
  improvised mid-run.

**Two terminals, one phone.** Terminal 1 tails the service journal for the
whole run; terminal 2 is for the `curl` checks in Part A and for anything a
step asks you to look up. The phone runs the official app.

```sh
journalctl -u pds -f -o cat
```

Every server-side expectation below is a line in that stream. The access-log
line's shape is fixed by `accessLogLine` (`pds/lib/accesslog.mdk`):

```
serve: access method=POST path=/xrpc/com.atproto.repo.createRecord status=200 bytes=412 ms=37 client=203.0.113.7
```

`path` has its query string stripped deliberately, so a GET's parameters will
not appear — match on the route, not on the arguments.

## 2. The transcript is the artifact

Record one line per step, in order, in this shape:

```
A3  did:web document       EXPECTED: verificationMethod #atproto present   OBSERVED: <what you saw>   PASS/FAIL
```

The completed transcript is pasted as a comment on **#1697**, per
[`PDS-LAUNCH-PLAN.md`](PDS-LAUNCH-PLAN.md) §3's sign-off table. Observed values
go in even when they match — "as expected" is not an observation and a reader
six months from now cannot check it.

## Part A — identity and reachability, before the app touches it

These are `curl` checks from terminal 2. They come first because every one of
them is a precondition the app will hit silently and fail opaquely on: the app
reports "invalid handle" for at least four distinct upstream causes.

| # | Check | Expected observation |
|---|---|---|
| **A1** | `curl -sS https://<hostname>/xrpc/_health` | `{"version":"pdsd 0.1.0 (<commit>, built <date>)"}` — the **same** string `pdsd --version` prints and the same one the startup banner logged. A bare `pdsd 0.1.0` with no parenthesis means the binary was built without `--stamp-build` and breaks the runbook's provenance match. |
| **A2** | `curl -sS https://<hostname>/.well-known/atproto-did` | The account's DID as bare `text/plain`, no JSON, no trailing structure. This is what handle resolution returns when the handle and the hostname are the same string. |
| **A3** | `curl -sS https://<hostname>/.well-known/did.json` | See the note below. **Read this one before running it.** |
| **A4** | `curl -sS https://<hostname>/xrpc/com.atproto.server.describeServer` | JSON naming this server's DID and the account's availability. The app reads this during login to decide whether the host is a PDS at all. |
| **A5** | `curl -sS 'https://<hostname>/xrpc/com.atproto.identity.resolveHandle?handle=<handle>'` | The account's DID, as JSON this time. A 400 here and a correct A2 together mean the handle string the app will send differs from the one the account was created with. |
| **A6** | Re-read terminal 1 | Six access-log lines, one per check above, each `status=200`. A2 and A3 log `path=/.well-known/...`; A1 logs `path=/xrpc/_health`. |

> **A3 is the highest-risk step in this document, and it is deliberately not
> phrased as a pass/fail.**
>
> `/.well-known/did.json` is served by `wellKnownResponse`
> (`pds/lib/handlers.mdk`) from `didWebDocument`, which describes **the server**:
> it carries `id`, `@context` and one `service` entry, and it carries **no
> `verificationMethod` and no `alsoKnownAs`**. The hosted account's own
> document — the one that does carry the `#atproto` verification method built
> from the repo signing key, and the `alsoKnownAs` handle binding — is
> `accountDidDocument`, and it is reachable **only** inside
> `com.atproto.repo.describeRepo`'s `didDoc` field. The two are distinct on
> purpose (#2476 ruled that emitting one under the other's name would be a
> right-looking wrong answer).
>
> That separation is sound when the account DID is a `did:plc:`. **It has never
> been exercised when the account DID is `did:web:<hostname>`**, which is
> exactly what `PDS-DEPLOY.md` step 3 prescribes and what L1 makes the first
> launch identity. In that configuration a relay resolving the account's DID
> fetches this very URL and gets a document with no signing key in it.
>
> **So: record what A3 returns, then go to C1 and C2 and see whether the relay
> and the appview accept the repo anyway.** Whether they need the verification
> method at this URL is a fact about the network, not about this tree, and
> nobody here has measured it. If C1 or C2 fails, A3 is the first suspect and
> the finding is an S1 against `didWebDocument`'s well-known arm. If C1 and C2
> both pass, write that down too — it retires a real open question.

## Part B — the app walkthrough

The step list is A8's own, in A8's order. Do them in order: four of them depend
on the one before.

| # | Action in the app | Expected in the app | Expected route in the log |
|---|---|---|---|
| **B1** | Log in with the handle and password | Session established, timeline opens (it will be empty) | `POST /xrpc/com.atproto.server.createSession` → 200, then `GET /xrpc/app.bsky.actor.getPreferences` → 200. The second one is served **locally** and is the sharpest single check that the preferences store (A2 of the plan) is live. |
| **B2** | Post a text-only post | The post appears in your profile | `POST /xrpc/com.atproto.repo.createRecord` → 200, collection `app.bsky.feed.post` |
| **B3** | Post with an image attached | The image renders in the post | `POST /xrpc/com.atproto.repo.uploadBlob` → 200, then `createRecord` → 200. The blob ceiling is 5,242,880 bytes (`maxBlobBytes`, `pds/lib/resource_limits.mdk`) and Caddy's `request_body max_size` is set to the same number — **use an image well under it**; an image at the boundary tests two limits at once and tells you nothing about either. |
| **B4** | Follow the second account | Follow state shows in the app | `POST /xrpc/com.atproto.repo.createRecord` → 200, collection `app.bsky.graph.follow` |
| **B5** | Reply to a post from the second account | Reply threads correctly under the parent | `createRecord` → 200, collection `app.bsky.feed.post`. Reaching the parent post at all requires a **proxied read** to have succeeded first — if the thread will not load, the failure is the proxy, not the write. |
| **B6** | Open notifications | The second account's follow and any reply appear | `GET /xrpc/app.bsky.notification.listNotifications` → 200, **proxied**. Not in the local registry, so a 400 here means the audience set or the egress proxy, and a 404 means the method axis refused it. |
| **B7** | Send a DM to the second account | Message sends and shows as delivered | A `chat.bsky.convo.*` route → 200, **proxied to the chat audience**. Needs the second `--proxy-audience` row; see §5. |
| **B8** | Receive the second account's reply DM | Message arrives | Same namespace, same audience |
| **B9** | Log out | Session ends, app returns to the login screen | `POST /xrpc/com.atproto.server.deleteSession` → 200 |

**After B9, log back in.** The walkthrough is not finished at logout: Part C
needs a live session, and a login that fails *after* a clean logout is a
distinct defect from one that fails on a cold start.

## Part C — the network

These are the two steps that cannot be faked by any amount of local testing,
and they are why the walkthrough exists.

| # | Check | Expected observation |
|---|---|---|
| **C1** | The relay has the repo | `com.atproto.sync.listRepos` and `getRepoStatus` are served unconditionally, so the relay needs no configuration to *read* — what needs confirming is that it **subscribed and indexed**. The observable on this side is the `serve: stats` line's `subscriptions=` field going to 1 or more and staying there. Its shape is fixed by `statsLogLine` (`pds/lib/accesslog.mdk`). |
| **C2** | A fresh appview fetch of the profile succeeds | From a browser **not logged in as either account**, load the profile on `bsky.app` by handle. The posts from B2, B3 and B5 are there. This is the end-to-end proof: it means the relay read the firehose, validated the commit signatures, and the appview indexed the result. |
| **C3** | Re-read the whole journal for the run | No `serve: persist failed` line, no `serve: relay announce failed` line, and no access-log line with a 5xx status anywhere in the run. |

C2 failing while B2 succeeded is the interesting case, and it is the one A3's
note is about: it means this server accepted and stored the write but the
network would not take it.

## 3. Steps that are expected not to work, and are not failures

Write these in the transcript as **OUT**, with the reason, so the next reader
does not re-derive them.

- **Video posting.** A3 of the launch plan names the video service as one of
  the reasons `getServiceAuth` exists, but no issue tracks video upload end to
  end and nothing in this tree has exercised it. Out of this walkthrough.
- **Changing the handle.** `com.atproto.identity.updateHandle` is criterion A7
  and is milestoned G-ANNOUNCE (#2939) — not registered today. Do not try it;
  a 404 here is the documented state.
- **Anything needing OAuth**, a third-party client, email verification,
  password reset, app passwords, or a second account on this server. All are
  out of scope for every gate by decision (`PDS-LAUNCH-PLAN.md` §2.A).
- **Browser access to the PDS from `bsky.app`.** CORS (criterion A6) is
  implemented, but the client bar for G-QUIET is the official app (L2). If you
  try it anyway, record it as an extra observation rather than as a step.

## 4. When a step fails

1. **Finish the run.** Do not stop at the first failure — a later step often
   discriminates the cause, and a partial transcript is the artifact that
   cannot be graded. Mark it FAIL, note the observation, continue.
2. **Grade it before fixing it.** An S0 or S1 in the request path blocks
   G-QUIET; an S2 or below does not. `PDS-LAUNCH-PLAN.md` §1 is the bar.
3. **Deploying a fix restarts the soak clock** from that deploy, per
   `PDS-RUNBOOK.md` §4 — not from the original go-live.
4. **Re-run the whole walkthrough after any S0/S1 fix that touched the request
   path**, not only the failed step. This mirrors criterion B14's own
   re-run rule.

## 5. The one configuration that silently removes two steps

B7 and B8 need `--proxy-audience <chat service DID>=<port>` **and** a matching
egress route on that port. Without both, the chat calls are refused
`400 InvalidRequest` with nothing signed — which is correct, configured
behavior, and looks in the app exactly like a broken DM feature.

Confirm before the run, not during it: the startup line
`serve: config ... appview=yes ...` tells you appview proxying is on, but it
does **not** enumerate the audience rows. Check the unit's `ExecStart` for a
`--proxy-audience` row, and check `Caddyfile.egress` for that row's port.

## 6. What a complete transcript looks like

```
PDS A8 conformance walkthrough
commit:   <tag>  (pdsd --version: <string from A1>)
date:     <date>
operator: Val

A1  health                 EXPECTED: version string matches --version   OBSERVED: ...   PASS
A2  atproto-did            EXPECTED: bare DID, text/plain               OBSERVED: ...   PASS
A3  did.json               EXPECTED: recorded, graded via C1/C2         OBSERVED: ...   (see C1/C2)
...
B7  send DM                EXPECTED: chat.bsky.convo.* proxied 200      OBSERVED: ...   PASS
...
C2  fresh appview profile  EXPECTED: B2/B3/B5 posts visible             OBSERVED: ...   PASS

Failures: <none, or the list with severities>
Routes observed that this document did not predict: <list, or none>
```

That last line is not decoration. It is the correction this file needs to stop
being a prediction, and the next run's version of this document should have it
folded in.
