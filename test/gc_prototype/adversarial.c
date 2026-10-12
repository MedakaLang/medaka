#include "gc.h"
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static unsigned edges[5001][2], ids[32], seen[5001];
static unsigned rnd = 12345;
static unsigned random_word(void) { rnd = rnd * 1664525u + 1013904223u; return rnd; }
static size_t check_graph(Word w) {
  if (!w) return 0;
  unsigned id = (unsigned)unbox(load(w, 0));
  assert(id > 0 && id <= 5000);
  for (unsigned f = 0; f < 2; ++f) {
    Word child = load(w, f + 1);
    assert((child ? unbox(load(child, 0)) : 0) == edges[id][f]);
  }
  if (seen[id]) return 0;
  seen[id] = 1;
  return 1 + check_graph(load(w, 1)) + check_graph(load(w, 2));
}
int main(int argc, char **argv) {
  assert(argc == 2);
  heap_init((size_t)strtoull(argv[1], 0, 10));
  Word slots[32] = {0}; Root roots[32];
  for (unsigned i = 0; i < 32; ++i) root_push(&roots[i], &slots[i]);
  size_t stride = 0;
  for (unsigned id = 1; id <= 5000; ++id) {
    unsigned a = random_word() % 32, b = random_word() % 32;
    slots[a] = allocate(3, 6); ids[a] = id;
    store(slots[a], 0, integer(id));
    if (slots[b] && a != b) {
      store(slots[a], 1, slots[b]); edges[id][0] = ids[b];
      if (id % 3 == 0) {
        store(slots[b], 2, slots[a]); edges[ids[b]][1] = id;
      }
    }
    if (id % 7 == 0) { slots[b] = 0; ids[b] = 0; }
    if (id % 31 == 0) {
      major_collect(); memset(seen, 0, sizeof seen);
      size_t count = 0;
      for (unsigned i = 0; i < 32; ++i) {
        assert((slots[i] ? unbox(load(slots[i], 0)) : 0) == ids[i]);
        count += check_graph(slots[i]);
      }
      if (count && !stride) { stride = stats.old_live_bytes / count; assert(stride == 80); }
      assert(stats.old_live_bytes == count * stride);
    }
  }
  for (unsigned i = 32; i-- > 0;) { slots[i] = 0; root_pop(&roots[i]); }
  major_collect(); assert(stats.old_live_bytes == 0);
  Word big = 0, child = 0; Root rb, rc;
  root_push(&rb, &big); root_push(&rc, &child);
  big = allocate(64, UINT64_C(1) << 63); child = allocate(3, 0);
  store(child, 0, integer(42)); store(big, 63, child); child = 0;
  major_collect(); assert(load(load(big, 63), 0) == integer(42));
  assert(stats.old_live_bytes == 56 + 64 * 8 + 80);
  store(big, 63, 0); major_collect(); assert(stats.old_live_bytes == 56 + 64 * 8);
  big = 0; root_pop(&rc); root_pop(&rb); major_collect();
  assert(stats.old_live_bytes == 0 && stats.root_bytes == 0);
  assert(stats.allocations == stats.nursery_allocations + stats.direct_old_allocations);
  assert(stats.payload_bytes == stats.nursery_payload_bytes + stats.direct_old_payload_bytes);
  assert(stats.allocation_header_bytes == stats.nursery_allocations * nursery_header_size()
      + stats.direct_old_allocations * old_header_size());
  assert(stats.copied_bytes == stats.copied_payload_bytes + stats.promoted_count * old_header_size());
  assert(stats.old_total_allocated_bytes == stats.copied_bytes + stats.direct_old_payload_bytes
      + stats.direct_old_allocations * old_header_size());
  heap_destroy(); puts("review graph passed");
}
