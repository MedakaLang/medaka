#define _POSIX_C_SOURCE 200809L
#include "gc.h"
#include <assert.h>
#include <inttypes.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <sys/resource.h>
#ifdef USE_BOEHM
#include <gc/gc.h>
#endif

static volatile uint64_t observed;
static GcLayout layouts[11];
static const size_t sized_words[] = {2, 3, 7, 16, 63, 64, 65, 127};
static const uint64_t sized_masks[] = {2, 2, 2, 0, 2, UINT64_C(1) << 63,
                                      2 | (UINT64_C(1) << 63), 0};
static void prepare_workload(void) {
  layouts[0] = prepare_layout(3, 2);
  layouts[1] = prepare_layout(3, 6);
  layouts[2] = prepare_layout(3, 0);
  for (size_t i = 0; i < 8; ++i) layouts[i + 3] = prepare_layout(sized_words[i], sized_masks[i]);
}
static inline GcLayout list_layout(void) { return (GcLayout){3, 2, layouts[0].info, layouts[0].epoch}; }
static inline GcLayout tree_layout(void) { return (GcLayout){3, 6, layouts[1].info, layouts[1].epoch}; }
static inline GcLayout atomic_layout(void) { return (GcLayout){3, 0, layouts[2].info, layouts[2].epoch}; }
static inline __attribute__((always_inline)) Word work_allocate(GcLayout layout) {
#if defined(INLINE_ALLOC)
  return allocate_prepared(layout);
#elif defined(USE_PREPARED) || defined(USE_PREPARED_ALLOC)
  return allocate_prepared_out_of_line(layout);
#else
  return allocate(layout.words, layout.mask);
#endif
}
static inline __attribute__((always_inline)) void work_store(GcLayout layout, Word object, size_t index, Word value) {
#if defined(INLINE_STORE)
  store_prepared(layout, object, index, value);
#elif defined(USE_PREPARED)
  store_prepared_out_of_line(layout, object, index, value);
#else
  (void)layout; store(object, index, value);
#endif
}
static uint64_t sum_sized(Word node) {
  uint64_t total = 0;
  while (node) {
    uint64_t encoded = unbox(load(node, 0)); size_t shape = encoded & 7;
    total += encoded >> 3; node = load(node, shape == 5 ? 63 : 1);
  }
  return total;
}
static uint64_t sum_list(Word node) {
  uint64_t total = 0;
  while (node) { total += unbox(load(node, 0)); node = load(node, 1); }
  return total;
}
static Word tree(size_t count, uint64_t *id) {
  if (!count) return 0;
  Word left = 0, right = 0;
  Root l, r; root_push(&l, &left); root_push(&r, &right);
  left = tree(count / 2, id);
  right = tree(count - count / 2 - 1, id);
  Word result = work_allocate(tree_layout());
  work_store(tree_layout(), result, 0, integer((*id)++));
  work_store(tree_layout(), result, 1, left); work_store(tree_layout(), result, 2, right);
  root_pop(&r); root_pop(&l); return result;
}
static uint64_t sum_tree(Word node) {
  return node ? unbox(load(node, 0)) + sum_tree(load(node, 1)) + sum_tree(load(node, 2)) : 0;
}
static void selftest(const char *only) {
  Word a = 0, b = 0; Root ra, rb;
  root_push(&ra, &a); root_push(&rb, &b);
  if (!only || strcmp(only, "root") == 0) {
    a = allocate(3, 2); store(a, 0, integer(17));
#ifndef USE_BOEHM
    Word before = a;
#endif
    minor_collect();
#ifndef USE_BOEHM
    assert(a != before);
#endif
    assert(load(a, 0) == integer(17));
  }
  if (!only || strcmp(only, "barrier") == 0) {
    a = allocate(3, 2); minor_collect();
    Word child = allocate(3, 2); store(child, 0, integer(29));
    store(a, 1, child); minor_collect();
#ifndef USE_BOEHM
    assert(load(a, 1) != child);
#endif
    assert(load(load(a, 1), 0) == integer(29));
  }
  if (!only) {
    a = allocate(3, 6); b = allocate(3, 6);
    store(a, 0, integer(11)); store(b, 0, integer(23));
    store(a, 1, b); store(a, 2, b); store(b, 1, a);
    minor_collect(); major_collect();
    assert(load(a, 1) == b && load(a, 2) == b && load(b, 1) == a);
    assert(load(b, 0) == integer(23));
    b = a; minor_collect(); assert(a == b);
    a = b = 0; major_collect();
#ifndef USE_BOEHM
    assert(stats.old_live_bytes == 0);
#endif
    for (size_t i = 0; i < 200; ++i) {
      b = allocate(3, 2); store(b, 0, integer(i)); store(b, 1, a); a = b; b = 0;
    }
    major_collect(); assert(sum_list(a) == 19900);
    a = 0; major_collect();
#ifndef USE_BOEHM
    assert(stats.old_live_bytes == 0 && stats.minor_count > 3);
#endif
    a = allocate(4096, 0); store(a, 4095, integer(91));
    major_collect(); assert(load(a, 4095) == integer(91));
    a = 0; major_collect();
#ifndef USE_BOEHM
    assert(stats.old_live_bytes == 0);
#endif
    for (size_t i = 0; i < 100; ++i) {
      a = allocate(4096, 0); store(a, 4095, integer(i));
    }
    major_collect(); assert(load(a, 4095) == integer(99));
    a = 0; major_collect();
#ifndef USE_BOEHM
    assert(stats.old_live_bytes == 0);
    a = allocate(3, 0); b = allocate(3, 2);
    /* A pointer-looking payload must not be visited under the atomic descriptor. */
    ((Word *)a)[0] = b; b = 0; major_collect();
    assert(stats.old_live_bytes == old_header_size() + 3 * sizeof(Word));
    a = 0; major_collect(); assert(stats.old_live_bytes == 0);
#endif
  }
  a = b = 0; root_pop(&rb); root_pop(&ra); major_collect();
  puts("selftest passed");
}
static uint64_t workload(const char *profile, size_t count) {
  Word head = 0, anchor = 0; Root h, a;
  root_push(&h, &head); root_push(&a, &anchor);
  uint64_t total = 0;
  if (strcmp(profile, "tree") == 0) {
    uint64_t id = 0; head = tree(count, &id); total = sum_tree(head);
  } else if (strcmp(profile, "atomic") == 0) {
    for (size_t i = 0; i < count; ++i) {
      head = work_allocate(atomic_layout()); work_store(atomic_layout(), head, 0, integer(i));
      work_store(atomic_layout(), head, 1, integer(i ^ 123)); work_store(atomic_layout(), head, 2, integer(0));
      total += unbox(load(head, 0));
    }
  } else if (strcmp(profile, "mixed") == 0) {
    for (size_t i = 0; i < count; ++i) {
      Word node = work_allocate(list_layout()); work_store(list_layout(), node, 0, integer(i));
      if (i % 64 == 0) { work_store(list_layout(), node, 1, anchor); anchor = node; }
      else { work_store(list_layout(), node, 1, head); head = node; }
      total += unbox(load(node, 0));
      if ((i + 1) % 64 == 0) head = 0;
    }
    head = 0;
    uint64_t retained = (count + 63) / 64;
    assert(sum_list(anchor) == 64 * retained * (retained - 1) / 2);
  } else if (strcmp(profile, "sizes") == 0) {
    Word atomic_roots[2] = {0, 0}; Root r0, r1;
    root_push(&r0, &atomic_roots[0]); root_push(&r1, &atomic_roots[1]);
    uint64_t retained_sum = 0, atomic_ids[2] = {0, 0};
    size_t retained_bytes = 0;
    for (size_t i = 0; i < count; ++i) {
      size_t shape = i & 7; GcLayout layout = layouts[shape + 3];
      Word node = work_allocate(layout);
      work_store(layout, node, 0, integer(((uint64_t)i << 3) | shape));
      /* The 61-step retention schedule visits every shape in the eight-step cycle. */
      int retained = (i + 1) % 61 == 0;
      if (layout.mask) {
        Word next = retained ? anchor : head;
        if (layout.mask & 2) work_store(layout, node, 1, next);
        if (layout.mask & (UINT64_C(1) << 63)) work_store(layout, node, 63, next);
        if (retained) {
          anchor = node; retained_sum += i;
          retained_bytes += old_header_size() + layout.words * sizeof(Word);
        } else head = node;
      } else {
        work_store(layout, node, layout.words - 1, integer(i ^ 123));
        if (retained) { size_t slot = shape == 3 ? 0 : 1; atomic_roots[slot] = node; atomic_ids[slot] = i; }
      }
      total += unbox(load(node, 0)) >> 3;
      if ((i + 1) % 64 == 0) head = 0;
    }
    head = 0; assert(sum_sized(anchor) == retained_sum);
    for (size_t slot = 0; slot < 2; ++slot) {
      if (atomic_roots[slot]) {
        assert((unbox(load(atomic_roots[slot], 0)) >> 3) == atomic_ids[slot]);
        retained_bytes += old_header_size() + sized_words[slot ? 7 : 3] * sizeof(Word);
      }
    }
    observed = total; major_collect();
#ifndef USE_BOEHM
    assert(stats.old_live_bytes == retained_bytes);
#else
    (void)retained_bytes;
    GC_reachable_here(anchor); GC_reachable_here(atomic_roots[0]); GC_reachable_here(atomic_roots[1]);
#endif
    atomic_roots[0] = atomic_roots[1] = head = anchor = 0;
    root_pop(&r1); root_pop(&r0); root_pop(&a); root_pop(&h);
    return total;
  } else {
    int ephemeral = strcmp(profile, "ephemeral") == 0;
    int mutation = strcmp(profile, "mutation") == 0;
    assert(ephemeral || mutation || strcmp(profile, "list") == 0);
    if (mutation) {
      anchor = work_allocate(list_layout()); minor_collect();
    }
    for (size_t i = 0; i < count; ++i) {
      Word node = work_allocate(list_layout());
      work_store(list_layout(), node, 0, integer(i)); work_store(list_layout(), node, 1, head); head = node;
      if ((ephemeral && (i + 1) % 256 == 0) || (mutation && (i + 1) % 64 == 0)) {
        if (mutation) work_store(list_layout(), anchor, 1, head);
        total += sum_list(head); head = 0;
      }
    }
    total += sum_list(head);
  }
  observed = total;
  /* Final collection makes old_live_bytes precise for the roots still retained here. */
  major_collect();
#ifndef USE_BOEHM
  if (strcmp(profile, "mixed") == 0)
    assert(stats.old_live_bytes == ((count + 63) / 64) * (old_header_size() + 3 * sizeof(Word)));
#endif
#ifdef USE_BOEHM
  GC_reachable_here(head); GC_reachable_here(anchor);
#endif
  head = anchor = 0; root_pop(&a); root_pop(&h);
  return total;
}
static double now(void) {
  struct timespec time; int status = clock_gettime(CLOCK_MONOTONIC, &time); assert(status == 0);
  return (double)time.tv_sec + (double)time.tv_nsec / 1e9;
}
int main(int argc, char **argv) {
  if (argc >= 2 && strcmp(argv[1], "--selftest") == 0) {
    heap_init(240); selftest(argc == 3 ? argv[2] : NULL); heap_destroy(); return 0;
  }
  if (argc != 4) { fprintf(stderr, "usage: %s PROFILE COUNT NURSERY_BYTES\n", argv[0]); return 2; }
  size_t count = strtoull(argv[2], NULL, 10), capacity = strtoull(argv[3], NULL, 10);
  assert(count > 0 && count < UINT64_C(1000000000) && capacity >= 240 && capacity <= SIZE_MAX / 4);
  heap_init(capacity);
  double preparation_start = now();
  prepare_workload();
  double preparation_seconds = now() - preparation_start;
  size_t descriptor_bytes_after_prepare = stats.descriptor_bytes;
  double start = now(); uint64_t checksum = workload(argv[1], count); double elapsed = now() - start;
  assert(checksum == (uint64_t)count * (count - 1) / 2);
  printf("{\"profile\":\"%s\",\"count\":%zu,\"checksum\":%" PRIu64 ",\"elapsed_seconds\":%.9f,",
         argv[1], count, checksum, elapsed);
  print_stats();
  printf(",\"layout_manifest_bytes\":%zu,\"preparation_seconds\":%.9f,\"descriptor_bytes_after_prepare\":%zu",
         sizeof layouts, preparation_seconds, descriptor_bytes_after_prepare);
  struct rusage usage; int status = getrusage(RUSAGE_SELF, &usage); assert(status == 0);
#ifdef __APPLE__
  size_t peak_rss = (size_t)usage.ru_maxrss;
#else
  size_t peak_rss = (size_t)usage.ru_maxrss * 1024;
#endif
  printf(",\"process_peak_rss_bytes\":%zu}\n", peak_rss);
  heap_destroy(); return 0;
}
