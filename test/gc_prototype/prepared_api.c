#include "gc.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define REQUIRE(condition, name) do { \
  if (!(condition)) { \
    fprintf(stderr, "prepared-api assertion: %s\n", name); \
    abort(); \
  } \
} while (0)

static int outline;
static Word make(GcLayout layout) {
  return outline ? allocate_prepared_out_of_line(layout) : allocate_prepared(layout);
}
static void put(GcLayout layout, Word object, size_t index, Word value) {
  if (outline) store_prepared_out_of_line(layout, object, index, value);
  else store_prepared(layout, object, index, value);
}
static size_t bytes(size_t words) { return old_header_size() + words * sizeof(Word); }
static void empty(void) {
  major_collect();
  REQUIRE(stats.old_live_bytes == 0 && stats.old_object_count == 0,
          "prepared complete logical reclamation");
  REQUIRE(stats.pool_reserved_bytes == 0 && stats.large_reserved_bytes == 0,
          "prepared complete storage reclamation");
  REQUIRE(stats.root_bytes == 0, "prepared balanced root records");
}
static void zero_payload(Word object, size_t words) {
  for (size_t i = 0; i < words; ++i)
    REQUIRE(load(object, i) == 0, "prepared zero initialization");
}

static void roots_case(size_t capacity) {
  heap_init(capacity);
  GcLayout cell = prepare_layout(3, 2);
  Word child = 0, result = 0; Root rc, rr;
  root_push(&rc, &child); root_push(&rr, &result);
  child = make(cell); put(cell, child, 0, integer(17));
  Word before = child;
  while (gc_fast.capacity - gc_fast.used >= bytes(3)) result = make(cell);
  uint64_t minor = stats.minor_count;
  result = make(cell);
  REQUIRE(stats.minor_count > minor, "prepared nursery exhaustion slow path");
  /* A broken root update fails before any stale payload is dereferenced. */
  REQUIRE(child != before, "prepared root relocation");
  put(cell, result, 1, child);
  REQUIRE(load(load(result, 1), 0) == integer(17), "prepared reloaded initializer value");
  major_collect();
  child = make(cell); put(cell, child, 0, integer(23)); before = child;
  GcLayout large = prepare_layout(gc_fast.old_limit / sizeof(Word) + 1, 0);
  result = make(large);
  REQUIRE(stats.old_live_bytes >= gc_fast.old_limit, "prepared old threshold setup");
  uint64_t major = stats.major_count;
  result = make(cell);
  REQUIRE(stats.major_count > major, "prepared old threshold slow path");
  REQUIRE(child != before, "prepared threshold root relocation");
  put(cell, result, 1, child);
  REQUIRE(load(load(result, 1), 0) == integer(23), "prepared threshold initializer reload");
  child = result = 0; root_pop(&rr); root_pop(&rc); empty(); heap_destroy();
}

static void zero_case(size_t capacity) {
  heap_init(capacity);
  GcLayout cell = prepare_layout(3, 6);
  Word object = 0; Root root; root_push(&root, &object);
  while (gc_fast.capacity - gc_fast.used >= bytes(3)) {
    object = make(cell);
    for (size_t i = 0; i < 3; ++i) put(cell, object, i, integer(100 + i));
  }
  minor_collect();
  object = make(cell); zero_payload(object, 3);
  object = 0; root_pop(&root); empty(); heap_destroy();

  heap_init(32);
  GcLayout old = prepare_layout(4, 0);
  Word anchor = 0, dead = 0; Root ra, rd;
  root_push(&ra, &anchor); root_push(&rd, &dead);
  anchor = make(old); dead = make(old);
  for (size_t i = 0; i < 4; ++i) put(old, dead, i, integer(200 + i));
  dead = 0; major_collect();
  uint64_t reused = stats.pool_reused_slots;
  dead = make(old);
  REQUIRE(stats.pool_reused_slots > reused, "prepared mature slot reuse setup");
  zero_payload(dead, 4);
  anchor = dead = 0; root_pop(&rd); root_pop(&ra); empty(); heap_destroy();
}

static void barrier_case(size_t capacity) {
  heap_init(capacity);
  GcLayout cell = prepare_layout(3, 0);
  GcLayout old = prepare_layout(capacity / sizeof(Word) + 1, 2);
  Word child = 0, parent = 0; Root rc, rp;
  root_push(&rc, &child); root_push(&rp, &parent);
  child = make(cell); put(cell, child, 0, integer(29));
  parent = make(old);
  REQUIRE(!is_young(parent) && is_young(child), "prepared direct-old barrier setup");
  put(old, parent, 1, child); put(old, parent, 1, child);
  Word before = child;
  minor_collect();
  REQUIRE(child != before, "prepared barrier root relocation");
  /* Equality against the relocated root catches a missing barrier safely. */
  REQUIRE(load(parent, 1) == child, "prepared direct-old initialization barrier");
  child = 0; major_collect();
  REQUIRE(load(load(parent, 1), 0) == integer(29), "prepared child retained by initialized parent");
  REQUIRE(stats.old_live_bytes == bytes(old.words) + bytes(3), "prepared direct-old exact liveness");
  put(old, parent, 1, 0); major_collect();
  REQUIRE(stats.old_live_bytes == bytes(old.words), "prepared cleared initialized edge");
  parent = 0; root_pop(&rp); root_pop(&rc); empty(); heap_destroy();
}

static void growth_case(size_t capacity) {
  enum { SHAPES = 768 };
  GcLayout layouts[SHAPES]; Word slots[SHAPES] = {0}; Root roots[SHAPES];
  heap_init(capacity);
  for (size_t i = 0; i < SHAPES; ++i) {
    layouts[i] = prepare_layout(3 + i / 2, i % 2 ? 2 : 0);
    root_push(&roots[i], &slots[i]);
  }
  for (size_t i = 0; i < SHAPES; ++i) {
    if (i == SHAPES / 2)
      for (size_t n = 400; n < 1200; ++n) (void)prepare_layout(n, 4);
    GcLayout repeated = prepare_layout(layouts[i].words, layouts[i].mask);
    REQUIRE(repeated.info == layouts[i].info && repeated.epoch == layouts[i].epoch,
            "prepared stable interned layout handle");
    slots[i] = make(layouts[i]); zero_payload(slots[i], layouts[i].words);
    put(layouts[i], slots[i], 0, integer(i + 1));
    put(layouts[i], slots[i], layouts[i].words - 1, integer(i + 10000));
  }
  major_collect(); size_t expected = 0;
  for (size_t i = 0; i < SHAPES; ++i) {
    REQUIRE(load(slots[i], 0) == integer(i + 1), "prepared descriptor growth payload identity");
    REQUIRE(load(slots[i], layouts[i].words - 1) == integer(i + 10000),
            "prepared descriptor growth trailing field");
    expected += bytes(layouts[i].words);
  }
  REQUIRE(stats.old_live_bytes == expected, "prepared descriptor growth exact liveness");
  for (size_t i = SHAPES; i-- > 0;) { slots[i] = 0; root_pop(&roots[i]); }
  empty(); uintptr_t epoch = layouts[0].epoch; heap_destroy();
  heap_init(capacity);
  REQUIRE(prepare_layout(3, 0).epoch != epoch, "prepared heap epoch changes on reinitialization");
  empty(); heap_destroy();
}

static void boundaries_case(size_t capacity) {
  static const size_t widths[] = {
    1, 2, 3, 4, 7, 8, 15, 16, 31, 32, 63, 64, 127, 128, 254, 255, 256, 257, 4096
  };
  enum { COUNT = sizeof widths / sizeof widths[0] };
  Word slots[COUNT] = {0}, child = 0; Root roots[COUNT], rc; GcLayout layouts[COUNT];
  heap_init(capacity); root_push(&rc, &child);
  GcLayout leaf = prepare_layout(3, 0);
  child = make(leaf); put(leaf, child, 0, integer(777));
  size_t expected = bytes(3);
  for (size_t i = 0; i < COUNT; ++i) {
    root_push(&roots[i], &slots[i]);
    size_t pointer_slot = widths[i] >= 64 ? 63 : 1;
    layouts[i] = prepare_layout(widths[i], widths[i] >= 3 ? UINT64_C(1) << pointer_slot : 0);
    slots[i] = make(layouts[i]); zero_payload(slots[i], widths[i]);
    put(layouts[i], slots[i], 0, integer(i + 1000));
    if (widths[i] >= 3) put(layouts[i], slots[i], pointer_slot, child);
    expected += bytes(widths[i]);
  }
  child = 0; major_collect();
  REQUIRE(stats.old_live_bytes == expected, "prepared mixed boundary exact liveness");
  for (size_t i = 0; i < COUNT; ++i) {
    REQUIRE(load(slots[i], 0) == integer(i + 1000), "prepared mixed boundary payload identity");
    if (widths[i] >= 3) {
      size_t pointer_slot = widths[i] >= 64 ? 63 : 1;
      REQUIRE(load(load(slots[i], pointer_slot), 0) == integer(777),
              "prepared mixed boundary pointer descriptor");
    }
  }
  for (size_t i = COUNT; i-- > 0;) { slots[i] = 0; root_pop(&roots[i]); }
  root_pop(&rc); empty(); heap_destroy();
}

enum { GRAPH_N = 2000, GRAPH_ROOTS = 32 };
static unsigned edges[GRAPH_N + 1][2], ids[GRAPH_ROOTS], seen[GRAPH_N + 1];
static GcLayout graph_layouts[GRAPH_N + 1];
static unsigned random_state;
static unsigned random_word(void) { random_state = random_state * 1664525u + 1013904223u; return random_state; }
static size_t model_bytes(unsigned id) {
  if (!id || seen[id]) return 0;
  seen[id] = 1;
  return bytes(graph_layouts[id].words) + model_bytes(edges[id][0]) + model_bytes(edges[id][1]);
}
static void check_graph(Word object) {
  if (!object) return;
  unsigned id = (unsigned)unbox(load(object, 0));
  REQUIRE(id > 0 && id <= GRAPH_N, "prepared graph object identity range");
  if (seen[id]) return;
  seen[id] = 1;
  for (unsigned f = 0; f < 2; ++f) {
    Word child = load(object, f + 1);
    REQUIRE((child ? unbox(load(child, 0)) : 0) == edges[id][f], "prepared graph model edge");
    check_graph(child);
  }
}
static void graph_case(size_t capacity) {
  static const size_t widths[] = {3, 4, 7, 8, 31, 32, 63, 64, 255, 256, 257};
  Word slots[GRAPH_ROOTS] = {0}; Root roots[GRAPH_ROOTS];
  heap_init(capacity); memset(edges, 0, sizeof edges); memset(ids, 0, sizeof ids); random_state = 12345;
  for (unsigned i = 0; i < GRAPH_ROOTS; ++i) root_push(&roots[i], &slots[i]);
  for (unsigned id = 1; id <= GRAPH_N; ++id) {
    unsigned a = random_word() % GRAPH_ROOTS, b = random_word() % GRAPH_ROOTS;
    graph_layouts[id] = prepare_layout(widths[id % (sizeof widths / sizeof widths[0])], 6);
    slots[a] = make(graph_layouts[id]); ids[a] = id;
    put(graph_layouts[id], slots[a], 0, integer(id));
    if (slots[b] && a != b) {
      put(graph_layouts[id], slots[a], 1, slots[b]); edges[id][0] = ids[b];
      if (id % 3 == 0) {
        put(graph_layouts[ids[b]], slots[b], 2, slots[a]); edges[ids[b]][1] = id;
      }
    }
    if (id % 7 == 0) { slots[b] = 0; ids[b] = 0; }
    if (id % 31 == 0 || id == GRAPH_N) {
      major_collect(); memset(seen, 0, sizeof seen); size_t expected = 0;
      for (unsigned i = 0; i < GRAPH_ROOTS; ++i) expected += model_bytes(ids[i]);
      REQUIRE(stats.old_live_bytes == expected, "prepared graph independent exact liveness");
      memset(seen, 0, sizeof seen);
      for (unsigned i = 0; i < GRAPH_ROOTS; ++i) {
        REQUIRE((slots[i] ? unbox(load(slots[i], 0)) : 0) == ids[i], "prepared graph root identity");
        check_graph(slots[i]);
      }
    }
  }
  for (unsigned i = GRAPH_ROOTS; i-- > 0;) { slots[i] = 0; root_pop(&roots[i]); }
  empty();
  REQUIRE(stats.allocations == stats.nursery_allocations + stats.direct_old_allocations,
          "prepared allocation counter partition");
  REQUIRE(stats.copied_bytes == stats.copied_payload_bytes + stats.promoted_count * old_header_size(),
          "prepared promotion header accounting");
  REQUIRE(stats.old_total_allocated_bytes == stats.reclaimed_bytes, "prepared final reclamation accounting");
  heap_destroy();
}

int main(int argc, char **argv) {
  REQUIRE(argc >= 2 && argc <= 4, "usage: prepared-api CAPACITY [CASE] [inline|outline]");
  size_t capacity = (size_t)strtoull(argv[1], NULL, 10);
  REQUIRE(capacity >= 32 && capacity <= 1048576, "prepared nursery capacity range");
  const char *only = argc >= 3 ? argv[2] : "all";
  if (argc == 4) {
    REQUIRE(strcmp(argv[3], "inline") == 0 || strcmp(argv[3], "outline") == 0, "prepared API mode");
    outline = strcmp(argv[3], "outline") == 0;
  }
  struct Case { const char *name; void (*run)(size_t); } cases[] = {
    {"roots", roots_case}, {"zero", zero_case}, {"barrier", barrier_case},
    {"growth", growth_case}, {"boundaries", boundaries_case}, {"graph", graph_case}
  };
  unsigned ran = 0;
  for (size_t i = 0; i < sizeof cases / sizeof cases[0]; ++i)
    if (strcmp(only, "all") == 0 || strcmp(only, cases[i].name) == 0) { cases[i].run(capacity); ++ran; }
  REQUIRE(ran > 0, "prepared recognized test case");
  puts("prepared API passed"); return 0;
}
