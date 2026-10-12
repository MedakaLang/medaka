#include "gc.h"
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>

enum { SHAPES = 384, SLOTS = SHAPES * 2 };
static Word slots[SLOTS];
static Root roots[SLOTS];
static size_t widths[SLOTS];
static uint64_t identities[SLOTS], masks[SLOTS];

static size_t object_bytes(size_t words) {
  return old_header_size() + words * sizeof(Word);
}

static void check_empty(void) {
  assert(stats.old_live_bytes == 0 && stats.old_live_payload_bytes == 0);
  assert(stats.old_object_count == 0 && stats.old_slot_bytes == 0);
  assert(stats.pool_reserved_bytes == 0 && stats.pool_count == 0);
  assert(stats.large_reserved_bytes == 0 && stats.large_object_count == 0);
  assert(stats.pool_allocations == stats.pool_releases);
}

static void check_objects(void) {
  size_t live = 0, count = 0;
  for (size_t i = 0; i < SLOTS; ++i) {
    if (!slots[i]) continue;
    assert(!is_young(slots[i]));
    assert(load(slots[i], 0) == integer(identities[i]));
    assert(load(slots[i], widths[i] - 1) == integer(identities[i] + 10000));
    live += object_bytes(widths[i]);
    count++;
  }
  assert(stats.old_live_bytes == live);
  assert(stats.old_object_count == count);
  assert(stats.old_live_payload_bytes == live - count * old_header_size());
}

static void fill_slot(size_t i, uint64_t id) {
  widths[i] = 3 + i / 2;
  masks[i] = i % 2 ? UINT64_C(2) : 0;
  identities[i] = id;
  slots[i] = allocate(widths[i], masks[i]);
  store(slots[i], 0, integer(id));
  store(slots[i], widths[i] - 1, integer(id + 10000));
}

static void descriptor_growth_and_reuse(void) {
  for (size_t i = 0; i < SLOTS; ++i) fill_slot(i, i + 1);
  major_collect(); check_objects();
  for (size_t round = 0; round < 4; ++round) {
    for (size_t i = 0; i < SLOTS; ++i)
      if (i % 4 == round) slots[i] = 0;
    major_collect(); check_objects();
    for (size_t i = 0; i < SLOTS; ++i)
      if (!slots[i]) fill_slot(i, (round + 1) * 1000 + i + 1);
    major_collect(); check_objects();
  }
  for (size_t i = 0; i < SLOTS; ++i) slots[i] = 0;
  major_collect(); check_objects(); check_empty();
}

static void partial_pools(void) {
  size_t descriptor_bytes = stats.descriptor_bytes;
  for (size_t i = 0; i < SLOTS; ++i) {
    widths[i] = 255; identities[i] = 20000 + i;
    slots[i] = allocate(widths[i], 0);
    store(slots[i], 0, integer(identities[i]));
    store(slots[i], widths[i] - 1, integer(identities[i] + 10000));
  }
  major_collect(); check_objects();
  assert(stats.large_object_count == 0 && stats.pool_count > 1);
  size_t pools = stats.pool_count, reserved = stats.pool_reserved_bytes;
  uint64_t reused = stats.pool_reused_slots;
  for (size_t i = 0; i < SLOTS; i += 3) slots[i] = 0;
  major_collect(); check_objects();
  assert(stats.pool_count == pools && stats.pool_reserved_bytes == reserved);
  for (size_t i = 0; i < SLOTS; i += 3) {
    widths[i] = 254; identities[i] = 30000 + i;
    slots[i] = allocate(widths[i], 2);
    store(slots[i], 0, integer(identities[i]));
    store(slots[i], widths[i] - 1, integer(identities[i] + 10000));
  }
  major_collect(); check_objects();
  assert(stats.pool_count == pools && stats.pool_reserved_bytes == reserved);
  assert(stats.pool_reused_slots - reused == SLOTS / 3);
  assert(stats.descriptor_bytes == descriptor_bytes);
  for (size_t i = 0; i < SLOTS; ++i) slots[i] = 0;
  major_collect(); check_empty();
}

static void alias_barriers_and_cycles(void) {
  slots[0] = allocate(4, 14);
  store(slots[0], 0, integer(101));
  slots[1] = slots[0];
  minor_collect(); assert(slots[0] == slots[1]);
  for (size_t round = 0; round < 100; ++round) {
    slots[2] = allocate(4, 14);
    store(slots[2], 0, integer(round));
    store(slots[2], 1, slots[2]);
    store(slots[2], 2, slots[0]);
    store(slots[0], 1, slots[2]);
    store(slots[0], 2, slots[2]);
    store(slots[0], 3, slots[2]);
    slots[3] = slots[2];
    slots[2] = 0;
    minor_collect();
    assert(slots[0] == slots[1]);
    assert(load(slots[0], 1) == slots[3]);
    assert(load(slots[0], 2) == slots[3] && load(slots[0], 3) == slots[3]);
    assert(load(slots[3], 1) == slots[3] && load(slots[3], 2) == slots[0]);
    assert(load(slots[3], 0) == integer(round));
    major_collect(); assert(stats.old_live_bytes == 2 * object_bytes(4));
    slots[3] = 0;
  }
  store(slots[0], 1, 0); store(slots[0], 2, 0); store(slots[0], 3, 0);
  major_collect(); assert(stats.old_live_bytes == object_bytes(4));
  slots[0] = slots[1] = 0;
  major_collect(); check_empty();
}

static void remembered_vector_growth(void) {
  for (size_t i = 0; i < SHAPES; ++i) {
    slots[i] = allocate(3, 6); store(slots[i], 0, integer(i + 40000));
  }
  major_collect();
  for (size_t i = 0; i < SHAPES; ++i) {
    slots[SHAPES + i] = allocate(3, 6);
    store(slots[SHAPES + i], 0, integer(i + 50000));
    store(slots[SHAPES + i], 1, slots[i]);
    store(slots[i], 1, slots[SHAPES + i]);
    store(slots[i], 2, slots[SHAPES + i]);
  }
  for (size_t i = SHAPES; i < SLOTS; ++i) slots[i] = 0;
  major_collect(); assert(stats.old_live_bytes == SLOTS * object_bytes(3));
  for (size_t i = 0; i < SHAPES; ++i) {
    Word child = load(slots[i], 1);
    assert(child == load(slots[i], 2) && load(child, 1) == slots[i]);
    assert(load(slots[i], 0) == integer(i + 40000));
    assert(load(child, 0) == integer(i + 50000));
    if (i % 2 == 0) slots[i] = 0;
  }
  major_collect(); assert(stats.old_live_bytes == SHAPES * object_bytes(3));
  for (size_t i = 0; i < SHAPES; ++i) slots[i] = 0;
  major_collect(); check_empty();
}

static void mixed_boundaries(void) {
  static const size_t sizes[] = {
    1, 2, 3, 4, 7, 8, 15, 16, 31, 32, 63, 64, 127, 128,
    254, 255, 256, 257, 300, 4096
  };
  const size_t count = sizeof sizes / sizeof sizes[0];
  for (size_t round = 0; round < 5; ++round) {
    size_t live = 0;
    for (size_t i = 0; i < count; ++i) {
      slots[i] = allocate(sizes[i], 0);
      store(slots[i], sizes[i] - 1, integer(7000 + round * count + i));
      live += object_bytes(sizes[i]);
    }
    major_collect(); assert(stats.old_live_bytes == live);
    for (size_t i = 0; i < count; ++i) {
      assert(load(slots[i], sizes[i] - 1) == integer(7000 + round * count + i));
      if (i % 2 == 0) { slots[i] = 0; live -= object_bytes(sizes[i]); }
    }
    major_collect(); assert(stats.old_live_bytes == live);
    for (size_t i = 0; i < count; ++i) {
      if (!slots[i]) slots[i] = allocate(sizes[i], 0);
      else assert(load(slots[i], sizes[i] - 1) == integer(7000 + round * count + i));
    }
    major_collect();
    for (size_t i = 0; i < count; ++i) slots[i] = 0;
    major_collect(); check_empty();
  }
}

static void first_64_and_atomic(void) {
  slots[0] = allocate(256, UINT64_C(1) << 63);
  slots[1] = allocate(3, 0);
  store(slots[1], 0, integer(303));
  store(slots[0], 63, slots[1]); slots[1] = 0;
  slots[4] = allocate(3, 0);
  ((Word *)slots[0])[64] = slots[4]; slots[4] = 0;
  major_collect(); assert(load(load(slots[0], 63), 0) == integer(303));
  assert(stats.old_live_bytes == object_bytes(256) + object_bytes(3));
  slots[2] = allocate(4096, 0);
  slots[3] = allocate(3, 0);
  /* The descriptor excludes this exact pointer, even beyond bitmap word 63. */
  ((Word *)slots[2])[64] = slots[3];
  ((Word *)slots[2])[4095] = slots[3];
  slots[3] = 0;
  major_collect();
  assert(stats.old_live_bytes == object_bytes(256) + object_bytes(3) + object_bytes(4096));
  store(slots[0], 63, 0); major_collect();
  assert(stats.old_live_bytes == object_bytes(256) + object_bytes(4096));
  slots[0] = slots[2] = 0; major_collect(); check_empty();
}

int main(int argc, char **argv) {
  assert(argc == 2);
  heap_init((size_t)strtoull(argv[1], NULL, 10));
  assert(nursery_header_size() == 8 && old_header_size() == 8);
  for (size_t i = 0; i < SLOTS; ++i) root_push(&roots[i], &slots[i]);
  descriptor_growth_and_reuse();
  partial_pools();
  alias_barriers_and_cycles();
  remembered_vector_growth();
  mixed_boundaries();
  first_64_and_atomic();
  for (size_t i = SLOTS; i-- > 0;) root_pop(&roots[i]);
  major_collect(); assert(stats.old_live_bytes == 0 && stats.root_bytes == 0);
  assert(stats.allocations == stats.nursery_allocations + stats.direct_old_allocations);
  assert(stats.payload_bytes == stats.nursery_payload_bytes + stats.direct_old_payload_bytes);
  assert(stats.allocation_header_bytes == stats.allocations * 8);
  assert(stats.copied_bytes == stats.copied_payload_bytes + stats.promoted_count * 8);
  assert(stats.old_total_allocated_bytes == stats.copied_bytes + stats.direct_old_payload_bytes
      + stats.direct_old_allocations * 8);
  heap_destroy(); check_empty();
  assert(stats.descriptor_bytes == 0 && stats.work_queue_bytes == 0 && stats.remembered_queue_bytes == 0);
  heap_init(32); major_collect(); check_empty(); heap_destroy();
  puts("pool review passed");
}
