#ifndef PROTOTYPE_GC_H
#define PROTOTYPE_GC_H
#include <stddef.h>
#include <stdint.h>
#include <assert.h>
#include <string.h>

typedef uintptr_t Word;
typedef struct Root { Word *slot; struct Root *previous; } Root;
typedef struct Stats {
  uint64_t allocations, payload_bytes, allocation_header_bytes;
  uint64_t minor_count, major_count, copied_bytes, copied_payload_bytes;
  uint64_t promoted_count, reclaimed_bytes, old_total_allocated_bytes;
  uint64_t nursery_allocations, nursery_payload_bytes, direct_old_allocations, direct_old_payload_bytes;
  uint64_t pool_allocations, pool_releases, pooled_allocations, pool_reused_slots;
  size_t old_live_payload_bytes, old_object_count, old_slot_bytes;
  size_t pool_reserved_bytes, peak_pool_reserved_bytes, pool_count;
  size_t large_reserved_bytes, large_object_count, descriptor_bytes;
  size_t work_queue_bytes, remembered_queue_bytes;
  size_t old_live_bytes, peak_old_bytes, peak_accounted_bytes, root_bytes, peak_root_bytes;
} Stats;
extern Stats stats;
typedef struct GcLayout {
  size_t words;
  uint64_t mask;
  uintptr_t info, epoch;
} GcLayout;
typedef struct GcFastState {
  unsigned char *nursery;
  size_t capacity, used, old_limit;
} GcFastState;
extern GcFastState gc_fast;
extern uintptr_t gc_heap_epoch;
uintptr_t register_layout(size_t words, uint64_t mask);
Word allocate_prepared_slow(GcLayout layout);
Word allocate_prepared_out_of_line(GcLayout layout);
void store_prepared_out_of_line(GcLayout layout, Word object, size_t index, Word value);
void remember_prepared(Word object);

/* Layout values contain stable descriptor indices and expire with their heap.
   Never retain a pointer into the growable descriptor table. */
static inline GcLayout prepare_layout(size_t words, uint64_t mask) {
  assert(words > 0 && words <= (SIZE_MAX - 3 * sizeof(Word)) / sizeof(Word));
  assert(words >= 64 || (mask >> words) == 0);
  assert(gc_heap_epoch);
  return (GcLayout){words, mask, register_layout(words, mask), gc_heap_epoch};
}
static inline int prepared_pointer(Word value) { return value && !(value & 1); }
#ifndef USE_BOEHM
static inline int prepared_young(Word value) {
  return prepared_pointer(value) && value >= (Word)gc_fast.nursery
      && value < (Word)gc_fast.nursery + gc_fast.used;
}
#elif defined(USE_CALLER_INLINE)
#include "boehm_caller.h"
#endif
static inline __attribute__((always_inline)) Word allocate_prepared(GcLayout layout) {
  assert(layout.epoch == gc_heap_epoch);
  size_t bytes = layout.words * sizeof(Word);
#ifdef USE_BOEHM
#ifdef USE_CALLER_INLINE
  void *object = layout.mask ? prototype_caller_alloc((long long)bytes) : GC_malloc_atomic(bytes);
#else
  (void)bytes;
  return allocate_prepared_slow(layout);
#endif
#ifdef USE_CALLER_INLINE
  assert(object);
  /* Boehm only promises cleared payloads for pointer-bearing allocations. */
  if (!layout.mask) memset(object, 0, bytes);
  stats.allocations++; stats.payload_bytes += bytes;
  return (Word)object;
#endif
#else
  size_t total = sizeof(Word) + bytes;
  if (stats.old_live_bytes >= gc_fast.old_limit || total > gc_fast.capacity - gc_fast.used)
    return allocate_prepared_slow(layout);
  Word *header = (Word *)(gc_fast.nursery + gc_fast.used);
  gc_fast.used += total;
#ifndef GC_MUTATE_ZERO
  memset(header, 0, total);
#endif
  header[0] = layout.info;
  stats.nursery_allocations++; stats.nursery_payload_bytes += bytes;
  stats.allocation_header_bytes += sizeof(Word);
  stats.allocations++; stats.payload_bytes += bytes;
  return (Word)(header + 1);
#endif
}
/* Initialize after allocating and reloading roots. Pointer values passed before
   the allocation slow path may have been relocated by that allocation. */
static inline __attribute__((always_inline)) void store_prepared(GcLayout layout, Word object, size_t index, Word value) {
  assert(layout.epoch == gc_heap_epoch);
  assert(index < layout.words);
  assert(!prepared_pointer(value) || (index < 64 && ((layout.mask >> index) & 1)));
#ifndef USE_BOEHM
  Word *header = (Word *)object - 1;
  assert((*header & ~(Word)7) == layout.info);
#endif
  ((Word *)object)[index] = value;
#if !defined(USE_BOEHM) && !defined(GC_MUTATE_BARRIER)
  if (!prepared_young(object) && prepared_young(value) && !(*header & 1))
    remember_prepared(object);
#endif
}
void heap_init(size_t nursery_bytes);
void heap_destroy(void);
#ifdef USE_BOEHM
static inline void root_push(Root *root, Word *slot) { (void)root; (void)slot; }
static inline void root_pop(Root *root) { (void)root; }
#else
void root_push(Root *root, Word *slot);
void root_pop(Root *root);
#endif
Word allocate(size_t words, uint64_t pointer_mask);
void store(Word object, size_t index, Word value);
void minor_collect(void);
void major_collect(void);
int is_young(Word word);
void print_stats(void);
size_t nursery_header_size(void);
size_t old_header_size(void);
static inline Word integer(uint64_t value) { return (Word)(value << 1) | 1; }
static inline uint64_t unbox(Word value) { return value >> 1; }
static inline Word load(Word object, size_t index) { return ((Word *)object)[index]; }
#endif
