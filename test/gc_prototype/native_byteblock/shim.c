#include "mdk_gc_byteblock_bridge.h"
#include <inttypes.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>

#ifdef USE_BOEHM
int prototype_inline_enabled(void) { return 0; }
size_t prototype_inline_root_bytes(void) { return 0; }
#endif

typedef struct Receipt { Word object; size_t requested; GcLayout actual; unsigned version; int checked; } Receipt;
static Receipt receipt;
static Root *source_root;
static Word *source_slot, source_before;
static size_t calls;
static int registered, moved, joined, guard_reached, source_young;
static pthread_t initializer;

static void diagnostics(const char *status) {
  fprintf(stderr, "BYTEBLOCK_GC {\"status\":\"%s\",\"calls\":%zu,\"minor\":%" PRIu64
    ",\"promoted\":%" PRIu64 ",\"copied_payload\":%" PRIu64 ",\"root_bytes\":%zu,"
    "\"source_moved\":%d,\"copy_guard_reached\":%d,\"joined\":%d,\"source_young\":%d,"
    "\"requested_bytes\":%zu,\"actual_bytes\":%zu,\"receipt_checked\":%d,\"direct_old\":%" PRIu64 "}\n",
    status, calls, stats.minor_count, stats.promoted_count, stats.copied_payload_bytes,
    stats.root_bytes, moved, guard_reached, joined, source_young, receipt.requested,
    receipt.actual.words * sizeof(Word), receipt.checked, stats.direct_old_allocations);
}
void mdk_gc_byteblock_fail_v1(const char *reason) {
  diagnostics(reason);
  fflush(stderr);
  /* Failure may occur on the worker; do not run heap destruction before join. */
  _Exit(78);
}
static void cleanup(void) {
  if (!joined || !pthread_equal(initializer, pthread_self()) || source_root || stats.root_bytes)
    mdk_gc_byteblock_fail_v1("byteblock-lifecycle");
  diagnostics("ok");
  heap_destroy();
}
__attribute__((constructor)) static void initialize(void) {
  initializer = pthread_self();
#ifdef MDK_BB_BOUND_CONTROL
#if MDK_BB_BOUND_CONTROL == 0
  (void)mdk_gc_byteblock_extent_v1(-1);
#elif MDK_BB_BOUND_CONTROL == 1
  (void)mdk_gc_byteblock_extent_v1(LLONG_MAX);
#else
  (void)mdk_gc_byteblock_atomic_v1(SIZE_MAX - 7);
#endif
  mdk_gc_byteblock_fail_v1("byteblock-bound-control-returned");
#endif
  const char *setting = getenv("MDK_BYTEBLOCK_NURSERY");
  char *end = NULL;
  unsigned long long parsed = setting ? strtoull(setting, &end, 10) : 32;
  if ((setting && (!*setting || *end || *setting == '-')) || parsed > SIZE_MAX)
    mdk_gc_byteblock_fail_v1("byteblock-nursery");
  size_t capacity = (size_t)parsed;
  if (capacity < 32 || capacity > SIZE_MAX / 4)
    mdk_gc_byteblock_fail_v1("byteblock-nursery");
  heap_init(capacity);
  if (atexit(cleanup)) mdk_gc_byteblock_fail_v1("byteblock-atexit");
}
void mdk_gc_byteblock_join_v1(int result) {
  if (result || !pthread_equal(initializer, pthread_self()))
    mdk_gc_byteblock_fail_v1("byteblock-join");
  joined = 1;
}
void mdk_gc_byteblock_begin_copy_v1(Root *root, Word *slot) {
  if (source_root || !receipt.checked || *slot != receipt.object)
    mdk_gc_byteblock_fail_v1("byteblock-source-origin");
  source_root = root; source_slot = slot; source_before = *slot; registered = 0;
}
void mdk_gc_byteblock_push_source_v1(Root *root, Word *slot) {
  if (root != source_root || slot != source_slot)
    mdk_gc_byteblock_fail_v1("byteblock-root-slot");
  root_push(root, slot); registered = 1;
}
static void check_registration(void) {
  guard_reached = 1;
  if (!registered || !source_root || !source_slot)
    mdk_gc_byteblock_fail_v1("missing-helper-root");
#ifndef USE_BOEHM
  if (source_root->slot != source_slot || source_root->previous || stats.root_bytes != sizeof(Root))
    mdk_gc_byteblock_fail_v1("missing-helper-root");
#endif
}
Word mdk_gc_byteblock_atomic_v1(size_t bytes) {
  if (bytes < 16 || bytes % sizeof(Word) || bytes / sizeof(Word) > (SIZE_MAX - 3 * sizeof(Word)) / sizeof(Word))
    mdk_gc_byteblock_fail_v1("byteblock-object-extent");
  ++calls;
  if (calls == 2) {
    check_registration();
#ifndef USE_BOEHM
    source_young = is_young(*source_slot);
    if (source_young && nursery_header_size() + receipt.requested > gc_fast.capacity)
      mdk_gc_byteblock_fail_v1("byteblock-nursery-route");
    minor_collect();
    moved = *source_slot != source_before;
    if (source_young && (!moved || !stats.promoted_count || !stats.copied_payload_bytes))
      mdk_gc_byteblock_fail_v1("byteblock-movement-witness");
#endif
  }
  size_t words = bytes / sizeof(Word);
  uint64_t mask = 0;
#ifdef MDK_BB_MUTATE_EXTENT
  words = 2;
#endif
#ifdef MDK_BB_MUTATE_MASK
  mask = 1;
#endif
  GcLayout actual = prepare_layout(words, mask);
  Word object = allocate_prepared(actual);
  receipt = (Receipt){object, bytes, actual, 1, 0};
#ifdef MDK_BB_MUTATE_VERSION
  receipt.version = 2;
#endif
  return object;
}
void mdk_gc_byteblock_check_allocation_v1(Word object, size_t requested) {
  if (receipt.version != 1) mdk_gc_byteblock_fail_v1("byteblock-layout-version");
  if (object != receipt.object || requested != receipt.requested || receipt.actual.words * sizeof(Word) != requested)
    mdk_gc_byteblock_fail_v1("byteblock-extent-mismatch");
  if (receipt.actual.mask) mdk_gc_byteblock_fail_v1("byteblock-atomic-mask");
  if (receipt.actual.epoch != gc_heap_epoch)
    mdk_gc_byteblock_fail_v1("byteblock-layout-epoch");
#ifndef USE_BOEHM
  if (nursery_header_size() != sizeof(Word) || ((((Word *)object)[-1]) & ~(Word)7) != receipt.actual.info)
    mdk_gc_byteblock_fail_v1("byteblock-layout-descriptor");
#endif
  receipt.checked = 1;
}
void mdk_gc_byteblock_check_source_v1(Word source) {
  check_registration();
  if (source != *source_slot) mdk_gc_byteblock_fail_v1("stale-source-word");
}
void mdk_gc_byteblock_end_copy_v1(Root *root) {
  if (root != source_root || !registered) mdk_gc_byteblock_fail_v1("byteblock-root-pop");
  root_pop(root); source_root = NULL; source_slot = NULL; registered = 0;
}
