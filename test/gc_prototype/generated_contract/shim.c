#include "gc.h"
#include <assert.h>
#include <inttypes.h>
#include <stdio.h>

_Static_assert(sizeof(Word) == 8 && sizeof(Root) == 16, "LLVM root ABI");
_Static_assert(offsetof(Root, previous) == 8, "LLVM root link offset");
static uint64_t calls;
void gc_push(Root *root, Word *slot) { root_push(root, slot); }
void gc_pop(Root *root) { root_pop(root); }
void *gc_allocate(uint64_t words, uint64_t mask) {
  assert(words >= 2 && words <= 64);
  assert(nursery_header_size() + words * sizeof(Word) <= 1024);
  calls++;
  if (calls < 64 && ((COLLECT_MASK >> calls) & 1)) minor_collect();
  return (void *)allocate(words, mask);
}
void mdk_set_args(int argc, void *argv) { (void)argc; (void)argv; }
void mdk_print_int(int64_t value) { printf("%" PRId64 "\n", value); }
int prototype_inline_enabled(void) { return 0; }
size_t prototype_inline_root_bytes(void) { return 0; }
extern int mdk_program_main(int argc, char **argv);
int main(int argc, char **argv) {
  heap_init(1024);
  int result = mdk_program_main(argc, argv);
  assert(result == 0 && stats.allocations >= 2 && stats.minor_count > 0);
  uint64_t selected = 0;
  for (uint64_t n = 1; n <= calls; n++) selected += (COLLECT_MASK >> n) & 1;
  assert(stats.allocations == calls && stats.minor_count == selected);
  assert(stats.root_bytes == 0 && stats.direct_old_allocations == 0);
#ifndef USE_BOEHM
  assert(stats.promoted_count > 0);
#endif
  major_collect();
  assert(stats.old_live_bytes == 0);
  fprintf(stderr, "generated roots: allocations=%" PRIu64 ", promoted=%" PRIu64
          ", roots=%zu, reclaimed-live=%zu\n", stats.allocations,
          stats.promoted_count, stats.root_bytes, stats.old_live_bytes);
  heap_destroy();
  return result;
}
