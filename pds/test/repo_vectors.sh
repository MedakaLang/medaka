#!/bin/sh
# The complete official repo transcript AND the focused-route representative,
# each run on BOTH compiled engines and differenced byte-for-byte.
#
# ── WHY THERE IS NO `medaka run` ARM HERE ANY MORE (#2208, S-2-pds-pole) ──────
#
# This gate was the single most expensive in the suite: 948.9s in
# test/gate_cost_baseline.json, 14% of the whole 6683s gate budget, and the pole
# that floored `gates (pds)` on every rebalance. Profiled arm-by-arm at that cut
# (marks around each block of the then-76-line script, all assertions removed):
#
#     arm1  medaka run … --representative   1091.56s   98.76%
#     arm2  medaka build native + run          7.45s    0.67%
#     arm3  medaka build --target wasm + node  6.31s    0.57%
#     cmp   native.out vs wasm.out             0.01s    0.00%
#
# So the cost was never "three compiles of the pds library" — those are 9.7s
# together. It was ONE `medaka run`: the tree-walking interpreter executing
# secp256k1 over the transcript. The assertions were never the expensive part;
# the ENGINE was.
#
# The `--representative` flag is a property of the DRIVER, not of the
# interpreter — the same binary arm 2 already builds takes it. Measured on the
# same box, same corpus, same driver:
#
#     medaka run  … --representative   1091.56s
#     ./native    … --representative      0.335s   (byte-identical output)
#     node run.js … --representative      1.25s    (byte-identical output)
#
# So the 43 routes the representative arm checks (6 official-atproto external +
# 27 focused rejections + 8 boundary controls + 1 malformed-bound-MST export)
# now run on TWO engines with a cross-engine differential, in ~1.6s, where they
# previously ran on ONE engine for 1091.56s. This is more coverage in the merge
# queue than before, not less.
#
# The eval interpreter's own agreement on this transcript is a breadth arm, not
# a soundness arm — the native==Wasm differential and the 19 hostile-route
# rejections both stay here in the queue — so it moved to
# pds/nightly/repo_vectors_eval_engine.sh under #2181's charter clause. It is
# STRONGER there than it was here: it now `cmp`s the interpreter's bytes against
# the native binary's instead of grepping four counts out of them.
#
# pds/test/signing_parity.sh demotes its own eval arm on this same axis (#1962),
# but in place, behind SIGNING_DEEP — the two shapes are written up in
# pds/README.md § CI classification policy.
set -eu

ROOT=${MEDAKA_ROOT:?set MEDAKA_ROOT to the repo root}
MEDAKA=${MEDAKA:-"$ROOT/medaka"}
DRIVER="$ROOT/pds/test/repo_vectors_main.mdk"
WASM_EMITTER=${MEDAKA_WASM_EMITTER:-"$ROOT/test/bin/wasm_emit_modules_main"}
WORK=$(mktemp -d "${TMPDIR:-/tmp}/pds-repo.XXXXXX")
trap 'rm -rf "$WORK"' EXIT HUP INT TERM

fail() {
  echo "FAIL: $1" >&2
  exit 1
}

require_empty() {
  [ ! -s "$1" ] || {
    cat "$1" >&2
    fail "$2 emitted stderr"
  }
}

# The runner's stdout is the program's output, byte for byte.  The trailing `0`
# this once stripped was never the runner's doing: it was #2424, the Wasm emitter
# auto-printing a Unit main's result as an Int, and it is gone.  Stripping a
# trailing `0` conditionally would also eat a real `0` output line, so no
# normalization happens here at all.
strip_exit_trailer() {
  cp "$1" "$2"
}

[ -x "$MEDAKA" ] || fail "build medaka first (missing $MEDAKA)"
sh "$ROOT/pds/test/vector_provenance.sh" --files-for P1-D-REPO > "$WORK/vector-files"
[ "$(wc -l < "$WORK/vector-files" | tr -d ' ')" = 1 ] || fail 'expected exactly one ledger-owned P1-D corpus'
CORPUS_REL=$(sed -n '1p' "$WORK/vector-files")
CORPUS="$ROOT/$CORPUS_REL"

if ! MEDAKA_ROOT="$ROOT" MEDAKA_STRICT=1 "$MEDAKA" build "$DRIVER" -o "$WORK/native" > "$WORK/native-build.log" 2>&1; then
  cat "$WORK/native-build.log" >&2
  fail 'native driver build failed'
fi

"$WORK/native" "$CORPUS" > "$WORK/native.out" 2> "$WORK/native.err"
require_empty "$WORK/native.err" native

grep -F -q 'external: 15/15 official-atproto transcript checks' "$WORK/native.out" || fail 'native transcript count is incomplete'
grep -F -q 'hostile: 19/19 rejected on named routes' "$WORK/native.out" || fail 'native hostile count is incomplete'
grep -F -q 'REPO-IDENTITY PASS mixed lookup/create rejected state=unchanged' "$WORK/native.out" || fail 'native missed normalized repository identity control'
grep -F -q 'repository-identity: 1/1 normalized key control' "$WORK/native.out" || fail 'native repository identity count is incomplete'
[ "$(tail -1 "$WORK/native.out")" = 'TOTAL: PASS' ] || fail 'native did not end in TOTAL: PASS'

"$WORK/native" "$CORPUS" --representative > "$WORK/native-rep.out" 2> "$WORK/native-rep.err"
require_empty "$WORK/native-rep.err" 'native representative'

grep -F -q 'representative-external: 6/6 official-atproto initialization/create/CAR checks' "$WORK/native-rep.out" || fail 'native representative external count is incomplete'
grep -F -q 'focused-rejected: 27/27 named routes' "$WORK/native-rep.out" || fail 'native F1 rejection count is incomplete'
grep -F -q 'focused-controls: 8/8 valid routes' "$WORK/native-rep.out" || fail 'native F1 boundary controls are incomplete'
grep -F -q 'focused-export-boundary: 1/1 malformed bound MST route' "$WORK/native-rep.out" || fail 'native F1 export boundary is incomplete'
grep -F -q 'OP CREATE PASS' "$WORK/native-rep.out" || fail 'native missed the representative CREATE'
grep -F -q 'CREATE CAR PASS order=' "$WORK/native-rep.out" || fail 'native missed representative exact CAR bytes/order'
[ "$(tail -1 "$WORK/native-rep.out")" = 'REPRESENTATIVE: PASS' ] || fail 'native did not end in REPRESENTATIVE: PASS'

# ── P4-C: the SAME transcript, through the record-write handler layer ────────
# repo_vectors_main.mdk replays the corpus directly against lib.repo. This arm
# replays it through handleBytes — JSON request bytes in, JSON response bytes
# out — and compares every uri/cid/commit.cid/commit.rev against the same pinned
# rows, so the handler layer is graded against the official oracle rather than
# against itself. Native only, for the reason the header gives at length.
HANDLERS_DRIVER="$ROOT/pds/test/record_handlers_main.mdk"
if ! MEDAKA_ROOT="$ROOT" MEDAKA_STRICT=1 "$MEDAKA" build "$HANDLERS_DRIVER" -o "$WORK/handlers" > "$WORK/handlers-build.log" 2>&1; then
  cat "$WORK/handlers-build.log" >&2
  fail 'record-handler driver build failed'
fi

"$WORK/handlers" "$CORPUS" > "$WORK/handlers.out" 2> "$WORK/handlers.err"
require_empty "$WORK/handlers.err" 'record handlers'

grep -F -q 'transcript: 4/4 handler-layer steps matched the pinned corpus' "$WORK/handlers.out" || fail 'handler-layer transcript count is incomplete'
grep -F -q 'CELL swap-commit-mismatch PASS error=InvalidSwap' "$WORK/handlers.out" || fail 'handler layer missed the swapCommit CAS rejection'
grep -F -q 'CELL validate-true-refused PASS error=InvalidRequest' "$WORK/handlers.out" || fail 'handler layer missed the validate:true refusal'
grep -F -q 'cells: 4/4 state-preserving rejections' "$WORK/handlers.out" || fail 'handler-layer state-preservation count is incomplete'
[ "$(tail -1 "$WORK/handlers.out")" = 'TOTAL: PASS' ] || fail 'record-handler driver did not end in TOTAL: PASS'

# ── P4-D: the SAME transcript, READ BACK through the read/sync handlers ──────
# Replays the four writes and then reads the result back out through
# getRecord/listRecords/describeRepo/sync.getRepo/sync.getLatestCommit,
# comparing every answer against the corpus's own rows. sync.getRepo's body is
# checked THREE ways: response bytes == repoExportCar's bytes == the corpus CAR
# row, so a wrong pair cannot satisfy it. Compiled engines only, same reason as
# the arm above; the repository-FREE half of these routes (resolveHandle, every
# unconfigured-store refusal, and /.well-known/did.json under a did:key
# account) runs on all three engines in pds/test/read_routes_all_engines.sh.
# The did:web arm of /.well-known/did.json is here instead, because the
# document that URL owes a resolver of THIS host's own did:web carries the
# repository's signing key, and a repository is what the eval arm cannot
# afford.
READS_DRIVER="$ROOT/pds/test/read_handlers_main.mdk"
if ! MEDAKA_ROOT="$ROOT" MEDAKA_STRICT=1 "$MEDAKA" build "$READS_DRIVER" -o "$WORK/reads" > "$WORK/reads-build.log" 2>&1; then
  cat "$WORK/reads-build.log" >&2
  fail 'read-handler driver build failed'
fi

"$WORK/reads" "$CORPUS" > "$WORK/reads.out" 2> "$WORK/reads.err"
require_empty "$WORK/reads.err" 'read handlers'

grep -F -q 'setup: 4/4 transcript writes replayed through the seam' "$WORK/reads.out" || fail 'read-handler setup replay is incomplete'
grep -F -q 'READ sync-getRepo-car-bytes PASS' "$WORK/reads.out" || fail 'read handlers missed the three-way CAR byte equality'
grep -F -q 'READ sync-getLatestCommit PASS' "$WORK/reads.out" || fail 'read handlers missed the pinned latest commit'
grep -F -q 'READ getRecord-deleted-medaka-a PASS error=RecordNotFound' "$WORK/reads.out" || fail 'read handlers missed the deleted-record refusal'
grep -F -q 'READ wellknown-did-web-serves-account-document PASS' "$WORK/reads.out" || fail 'read handlers missed the did:web well-known account document'
grep -F -q 'READ wellknown-did-key-keeps-server-document PASS' "$WORK/reads.out" || fail 'read handlers missed the did:key well-known fallback'
grep -F -q 'reads: 20/20 corpus-graded read routes' "$WORK/reads.out" || fail 'read-handler route count is incomplete'
[ "$(tail -1 "$WORK/reads.out")" = 'TOTAL: PASS' ] || fail 'read-handler driver did not end in TOTAL: PASS'

# ── the applyWrites batch: N operations, ONE signed commit ──────────────────
# Its own corpus, generated by the same pinned official @atproto/repo as four
# MST edits followed by ONE signCommit. That shape is the point: a batch must
# advance the repository by exactly one revision, so an answer key replayed as
# four single-write commits would grade the wrong thing. The batch corpus is a
# separate ledger row for the same reason it is a separate file — the transcript
# above is matched positionally by two other drivers.
BATCH_DRIVER="$ROOT/pds/test/batch_handlers_main.mdk"
sh "$ROOT/pds/test/vector_provenance.sh" --files-for P1-E-BATCH > "$WORK/batch-files"
[ "$(wc -l < "$WORK/batch-files" | tr -d ' ')" = 1 ] || fail 'expected exactly one ledger-owned batch corpus'
BATCH_CORPUS="$ROOT/$(sed -n '1p' "$WORK/batch-files")"

if ! MEDAKA_ROOT="$ROOT" MEDAKA_STRICT=1 "$MEDAKA" build "$BATCH_DRIVER" -o "$WORK/batch" > "$WORK/batch-build.log" 2>&1; then
  cat "$WORK/batch-build.log" >&2
  fail 'batch driver build failed'
fi

"$WORK/batch" "$BATCH_CORPUS" > "$WORK/batch.out" 2> "$WORK/batch.err"
require_empty "$WORK/batch.err" 'batch handlers'

grep -F -q 'external: 4/4 official-atproto batch checks' "$WORK/batch.out" || fail 'batch external count is incomplete'
grep -F -q 'BATCH one-commit-cid PASS' "$WORK/batch.out" || fail 'batch missed the pinned single-commit CID'
grep -F -q 'BATCH exported-car-bytes PASS' "$WORK/batch.out" || fail 'batch missed the pinned CAR bytes'
grep -F -q 'BATCH swap-commit-mismatch PASS error=InvalidSwap state=unchanged' "$WORK/batch.out" || fail 'batch missed the swapCommit CAS rejection'
grep -F -q 'BATCH failing-operation-aborts-batch PASS error=InvalidRequest state=unchanged' "$WORK/batch.out" || fail 'batch missed the all-or-nothing abort'
grep -F -q 'BATCH empty-batch-is-a-no-op PASS state=unchanged' "$WORK/batch.out" || fail 'batch missed the empty-batch no-op'
grep -F -q 'cells: 3/3 state-preserving batch properties' "$WORK/batch.out" || fail 'batch cell count is incomplete'
[ "$(tail -1 "$WORK/batch.out")" = 'TOTAL: PASS' ] || fail 'batch driver did not end in TOTAL: PASS'

# ── the three blob routes, graded against the official lex-data answer key ──
# pds/test/blob_routes_test.mdk drives the same three routes, but computes its
# expected CIDs with lib.blob.blobCid — an encoder and a decoder agreeing prove
# only that they are inverse. This arm replays blob_reference_corpus.txt, whose
# CIDs and whole `blob` ref JSON the pinned official @atproto/lex-data produced,
# so uploadBlob's answer is compared against something outside this tree. Its
# own ledger row for the same reason the batch corpus has one: a different
# generator, a different official package, a different row shape.
BLOB_DRIVER="$ROOT/pds/test/blob_handlers_main.mdk"
sh "$ROOT/pds/test/vector_provenance.sh" --files-for S-blob-core > "$WORK/blob-files"
[ "$(wc -l < "$WORK/blob-files" | tr -d ' ')" = 1 ] || fail 'expected exactly one ledger-owned blob corpus'
BLOB_CORPUS="$ROOT/$(sed -n '1p' "$WORK/blob-files")"

if ! MEDAKA_ROOT="$ROOT" MEDAKA_STRICT=1 "$MEDAKA" build "$BLOB_DRIVER" -o "$WORK/blob" > "$WORK/blob-build.log" 2>&1; then
  cat "$WORK/blob-build.log" >&2
  fail 'blob driver build failed'
fi

"$WORK/blob" "$BLOB_CORPUS" > "$WORK/blob.out" 2> "$WORK/blob.err"
require_empty "$WORK/blob.err" 'blob handlers'

grep -F -q 'external: 3/3 official-atproto blob checks' "$WORK/blob.out" || fail 'blob external count is incomplete'
grep -F -q 'BLOB upload-empty PASS' "$WORK/blob.out" || fail 'blob missed the pinned zero-byte blob CID'
grep -F -q 'BLOB upload-small-text PASS' "$WORK/blob.out" || fail 'blob missed the pinned text blob CID'
grep -F -q 'BLOB upload-image-shaped PASS' "$WORK/blob.out" || fail 'blob missed the pinned image-shaped blob CID'
grep -F -q 'BLOB listBlobs-corpus-cids PASS' "$WORK/blob.out" || fail 'blob missed the corpus-graded listBlobs answer'
grep -F -q 'routes: 4/4 corpus-graded blob route reads' "$WORK/blob.out" || fail 'blob read-back route count is incomplete'
[ "$(tail -1 "$WORK/blob.out")" = 'TOTAL: PASS' ] || fail 'blob driver did not end in TOTAL: PASS'

# ── the #commit firehose event, byte for byte against the official bytes ────
# A DIFFERENT schema from every transcript above: com.atproto.sync.subscribeRepos
# def `commit`, which shares field names with the repository commit object and
# means different things by them. Its own corpus for the same reason the batch
# has one — its own generator pass, its own row shape — and its own pinned
# lexicon JSON, which the generator checks the assembled event against, so a
# field-name typo cannot be graded against itself.
#
# Seven signed commits over a tree that climbs to three MST layers, covering
# create, update, delete and a three-operation batch. That shape is the point:
# on a one-node, single-write transcript every candidate rule for `blocks`
# returns the same answer, and `ops[].prev` — absent on a create, present
# otherwise — needs all three actions exercised at once.
EVENT_DRIVER="$ROOT/pds/test/commit_event_vectors_main.mdk"
sh "$ROOT/pds/test/vector_provenance.sh" --files-for P1-F-COMMIT-EVENT > "$WORK/event-files"
[ "$(wc -l < "$WORK/event-files" | tr -d ' ')" = 1 ] || fail 'expected exactly one ledger-owned commit-event corpus'
EVENT_CORPUS="$ROOT/$(sed -n '1p' "$WORK/event-files")"

if ! MEDAKA_ROOT="$ROOT" MEDAKA_STRICT=1 "$MEDAKA" build "$EVENT_DRIVER" -o "$WORK/event" > "$WORK/event-build.log" 2>&1; then
  cat "$WORK/event-build.log" >&2
  fail 'commit-event driver build failed'
fi

"$WORK/event" "$EVENT_CORPUS" > "$WORK/event.out" 2> "$WORK/event.err"
require_empty "$WORK/event.err" 'commit event'

grep -F -q 'prev-lookups: 9/9 op rows matched the reference previous record CID' "$WORK/event.out" || fail 'commit-event prev-record lookups are incomplete'
grep -F -q 'commit-identity: 7/7 steps matched the pinned commit and data CIDs' "$WORK/event.out" || fail 'commit-event commit identity is incomplete'
grep -F -q 'blocks: 7/7 steps matched the reference relevant-block set' "$WORK/event.out" || fail 'commit-event block sets are incomplete'
grep -F -q 'reference-car: 7/7 steps matched the official-ordered CAR root and blocks' "$WORK/event.out" || fail 'commit-event reference CAR decode is incomplete'
grep -F -q 'frames: 7/7 steps byte-identical to the official-ordered event' "$WORK/event.out" || fail 'commit-event frames are not byte-identical to the official bytes'
grep -F -q 'frames-sorted: 7/7 steps byte-identical to the canonical-ordered event' "$WORK/event.out" || fail 'commit-event canonical-ordered frames are incomplete'
grep -F -q "prevData: 7/7 steps named the prior commit's data root" "$WORK/event.out" || fail 'commit-event prevData is not the prior data root'
# The discriminator between a covering proof and a tree diff: a rule built from
# the changed nodes alone would still satisfy every count above.
grep -F -q 'untouched-nodes: 3/7 steps shipped an MST node the write did not change' "$WORK/event.out" || fail 'commit-event blocks stopped carrying unchanged MST nodes'
[ "$(tail -1 "$WORK/event.out")" = 'TOTAL: PASS' ] || fail 'commit-event driver did not end in TOTAL: PASS'

# ── the #identity/#account/#sync events, byte for byte against the official
#    bodies ──────────────────────────────────────────────────────────────────
# The three events a repository's CREATION emits, from their own corpus: the
# pinned image's own sequencer/events.js builders, called directly. They ride
# in this gate rather than in one of their own because they grade the same
# module against the same kind of answer key as the #commit block above, and a
# corpus with no gate is a corpus nothing checks.
#
# Its rows are BODIES — `seq` and `time` are spliced in downstream and neither
# builder sets them — so the driver names each header itself and compares the
# whole frame against header-plus-row.
ACTIVATION_DRIVER="$ROOT/pds/test/activation_event_vectors_main.mdk"
sh "$ROOT/pds/test/vector_provenance.sh" --files-for S-oracle-answer-keys > "$WORK/activation-files"
ACTIVATION_ROW=$(grep -c 'pds_sync_event_bodies_corpus.txt' "$WORK/activation-files" || true)
[ "$ACTIVATION_ROW" = 1 ] || fail 'expected exactly one ledger-owned activation-event corpus'
ACTIVATION_CORPUS="$ROOT/$(grep 'pds_sync_event_bodies_corpus.txt' "$WORK/activation-files")"

if ! MEDAKA_ROOT="$ROOT" MEDAKA_STRICT=1 "$MEDAKA" build "$ACTIVATION_DRIVER" -o "$WORK/activation" > "$WORK/activation-build.log" 2>&1; then
  cat "$WORK/activation-build.log" >&2
  fail 'activation-event driver build failed'
fi

"$WORK/activation" "$ACTIVATION_CORPUS" > "$WORK/activation.out" 2> "$WORK/activation.err"
require_empty "$WORK/activation.err" 'activation event'

grep -F -q 'IDENTITY-WITH-HANDLE: PASS' "$WORK/activation.out" || fail 'the #identity frame is not byte-identical to the official body'
grep -F -q 'ACCOUNT-ACTIVE: PASS' "$WORK/activation.out" || fail 'the #account frame is not byte-identical to the official body'
grep -F -q 'SYNC: PASS' "$WORK/activation.out" || fail 'the #sync frame is not byte-identical to the official body'
# The CAR shape asserted directly rather than left implicit in the frame hex:
# a wrong-but-self-consistent CAR encoder passes the frame comparison only by
# agreeing with itself.
grep -F -q 'SYNC-CAR-ROOTS: PASS' "$WORK/activation.out" || fail "the #sync CAR's root is not the pinned commit"
grep -F -q 'SYNC-CAR-BLOCKS: PASS' "$WORK/activation.out" || fail "the #sync CAR's block set is not the pinned commit alone"
# The genesis #commit's own CAR, whose block set is NOT the commit alone: a
# brand-new repository ships the empty MST root node beside it, or the relay
# it just announced itself to has no block for the data root the commit names.
grep -F -q 'GENESIS-COMMIT-CAR-ROOTS: PASS' "$WORK/activation.out" || fail "the genesis #commit's CAR is not rooted at the pinned genesis commit"
grep -F -q 'GENESIS-COMMIT-CAR-BLOCKS: PASS' "$WORK/activation.out" || fail "the genesis #commit's CAR does not carry the empty MST root beside the commit"
[ "$(tail -1 "$WORK/activation.out")" = 'TOTAL: PASS' ] || fail 'activation-event driver did not end in TOTAL: PASS'

# ── the sync READS, against the official CARs ───────────────────────────────
# `com.atproto.sync.getRecord` and `com.atproto.sync.getBlocks`, driven through
# the real protocol seam against a repository this driver REBUILDS from the
# corpus's own signing key, records and revision — the `FIXTURE` line is that
# rebuild's commit CID checked against the pinned one, and everything after it
# is meaningless if it fails, so it is asserted first and separately.
#
# The absent case is one discriminator this gate exists for: a missing record
# is answered 200 with a proof of NON-membership, not refused. A route that
# refused instead would satisfy every "record not found" intuition and break
# backfill.
#
# ── WHY getRecord IS NOT ASSERTED BYTE FOR BYTE (#3007) ──────────────────────
#
# The official `repo.getRecords` reaches `MST.cidsForPath`: the root-down
# DESCENT PATH to the key, carrying the record CID inline. This server answers
# `mstCoveringProofBlocks`, which also covers the key's lexical neighbors and
# walks leaf-up. So our answer is a SUPERSET of the reference's, in a different
# order, wherever the key sits below the root — and the pinned image's own
# consumer surface (`verifyProofs`/`verifyRecords`) accepts both identically.
# Asserting byte-identity here would red on a conformant answer.
#
# What is asserted instead, per probe, is derived from the five axes the
# driver reports on the four-node fixture rather than assumed:
#
#   probe                   CONTAIN  BOUNDED  SET-EQUAL  ORDER  CAR-BYTES
#   GETRECORD-PRESENT-D0      yes      yes       yes      no       no
#   GETRECORD-PRESENT-D1..D3  yes      yes       no       no       no
#   GETRECORD-ABSENT-BELOW    yes      yes       yes      no       no
#   GETRECORD-ABSENT-MID      yes      yes       yes      no       no
#
# CONTAIN — every block the official CAR names is in ours — is asserted on all
# six, because an OMISSION is the direction that makes a proof unsound. BOUNDED
# — our answer is no larger than the size measured on this fixture — is
# asserted on all six too: CONTAIN alone never caps the answer from above, so
# a regression that widened every probe to "the whole block store" would still
# satisfy CONTAIN and pass silently without it. SET equality is asserted on
# the three where it holds, so the weaker check is not spread over probes that
# do not need it. ORDER and byte-identity are asserted nowhere for getRecord:
# neither holds on any probe, and normalizing our emission to manufacture one
# would be changing the answer to fit the test. `getBlocks` is untouched by
# all of this and stays byte-identical.
SYNC_READS_DRIVER="$ROOT/pds/test/sync_car_shapes_main.mdk"
SYNC_READS_ROW=$(grep -c 'pds_sync_car_shapes_corpus.txt' "$WORK/activation-files" || true)
[ "$SYNC_READS_ROW" = 1 ] || fail 'expected exactly one ledger-owned sync-read CAR corpus'
SYNC_READS_CORPUS="$ROOT/$(grep 'pds_sync_car_shapes_corpus.txt' "$WORK/activation-files")"

if ! MEDAKA_ROOT="$ROOT" MEDAKA_STRICT=1 "$MEDAKA" build "$SYNC_READS_DRIVER" -o "$WORK/syncreads" > "$WORK/syncreads-build.log" 2>&1; then
  cat "$WORK/syncreads-build.log" >&2
  fail 'sync-read CAR driver build failed'
fi

"$WORK/syncreads" "$SYNC_READS_CORPUS" > "$WORK/syncreads.out" 2> "$WORK/syncreads.err"
require_empty "$WORK/syncreads.err" 'sync reads'

grep -F -q 'FIXTURE: PASS' "$WORK/syncreads.out" || fail 'the rebuilt sync-read fixture is not the pinned repository'

# A probe the driver stopped emitting would otherwise pass this section by
# being absent from it, so the count is asserted before the grades are.
SYNC_PROBES=$(grep -c -e '-BLOCKS-CONTAIN: ' "$WORK/syncreads.out" || true)
[ "$SYNC_PROBES" = 6 ] || fail "expected six sync.getRecord probes, driver graded $SYNC_PROBES"

for tag in GETRECORD-PRESENT-D0 GETRECORD-PRESENT-D1 GETRECORD-PRESENT-D2 \
  GETRECORD-PRESENT-D3 GETRECORD-ABSENT-BELOW GETRECORD-ABSENT-MID; do
  grep -F -q "$tag: PASS" "$WORK/syncreads.out" || fail "sync.getRecord $tag did not answer a 200 CAR"
  grep -F -q "$tag-ROOT: PASS" "$WORK/syncreads.out" || fail "sync.getRecord $tag is not rooted at the pinned commit"
  grep -F -q "$tag-BLOCKS-CONTAIN: PASS" "$WORK/syncreads.out" || fail "sync.getRecord $tag omits a block the official CAR names"
  grep -F -q "$tag-BLOCKS-BOUNDED: PASS" "$WORK/syncreads.out" || fail "sync.getRecord $tag answered more blocks than the pinned ceiling"
done

# The three probes where our answer is not merely a superset but the same set.
for tag in GETRECORD-PRESENT-D0 GETRECORD-ABSENT-BELOW GETRECORD-ABSENT-MID; do
  grep -F -q "$tag-BLOCKS-EQUAL: PASS" "$WORK/syncreads.out" || fail "sync.getRecord $tag no longer answers the official block SET"
done

grep -F -q 'GETBLOCKS-PRESENT: PASS' "$WORK/syncreads.out" || fail 'sync.getBlocks is not byte-identical to the official CAR'
# The empty roots list, read out of the header this server EMITTED: `lib.car`'s
# decoder refuses a rootless CAR, so no round trip can make this claim.
grep -F -q 'GETBLOCKS-PRESENT-ROOTS: PASS' "$WORK/syncreads.out" || fail 'sync.getBlocks named a CAR root'
grep -F -q 'GETBLOCKS-PARTLY-MISSING: PASS' "$WORK/syncreads.out" || fail 'sync.getBlocks did not refuse a partly-missing request with the pinned message'
[ "$(tail -1 "$WORK/syncreads.out")" = 'TOTAL: PASS' ] || fail 'sync-read CAR driver did not end in TOTAL: PASS'

if [ ! -x "$WASM_EMITTER" ] || ! command -v node >/dev/null 2>&1 || ! command -v wasm-tools >/dev/null 2>&1; then
  [ "${MEDAKA_REQUIRE_WASM:-0}" != 1 ] || fail 'Wasm is required but emitter/node/wasm-tools is unavailable'
  echo 'PASS: repo — full official transcript, focused representative, applyWrites batch, the three blob routes , the seven #commit firehose events, the three activation-event frames and the eight sync-read CAR shapes on native; Wasm unavailable'
  exit 0
fi

if ! MEDAKA_ROOT="$ROOT" MEDAKA_WASM_EMITTER="$WASM_EMITTER" MEDAKA_STRICT=1 "$MEDAKA" build --target wasm "$DRIVER" -o "$WORK/driver.wasm" > "$WORK/wasm-build.log" 2>&1; then
  cat "$WORK/wasm-build.log" >&2
  fail 'Wasm driver build failed'
fi

MDK_ARGS="$CORPUS" node "$ROOT/test/wasm/run.js" "$WORK/driver.wasm" > "$WORK/wasm-raw.out" 2> "$WORK/wasm.err"
require_empty "$WORK/wasm.err" wasm
strip_exit_trailer "$WORK/wasm-raw.out" "$WORK/wasm.out"
cmp "$WORK/native.out" "$WORK/wasm.out" || fail 'native and Wasm normalized transcript output differ'

MDK_ARGS="$CORPUS --representative" node "$ROOT/test/wasm/run.js" "$WORK/driver.wasm" > "$WORK/wasm-rep-raw.out" 2> "$WORK/wasm-rep.err"
require_empty "$WORK/wasm-rep.err" 'wasm representative'
strip_exit_trailer "$WORK/wasm-rep-raw.out" "$WORK/wasm-rep.out"
cmp "$WORK/native-rep.out" "$WORK/wasm-rep.out" || fail 'native and Wasm normalized representative output differ'

echo 'PASS: repo — full official TIDs/records/MST/commits/signatures/CAR and the 27 focused rejection routes, native == Wasm on both; 19 hostile routes; 4 handler-layer transcript steps + 4 state-preserving rejections; 20 corpus-graded read routes; 4 official-atproto applyWrites batch checks + 3 batch state-preservation properties; 3 official-atproto blob checks + 4 corpus-graded blob route reads; 7 #commit firehose events byte-identical to the official bytes in both pinned block orders; the #identity, #account and #sync activation frames byte-identical to the official bodies; six sync.getRecord probes over a four-node MST containing every block the official CAR names (three of them its exact set), and sync.getBlocks present/partly-missing byte-identical to the official CAR shapes'
