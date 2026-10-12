#ifndef PROTOTYPE_GC_H
#define PROTOTYPE_GC_H
#include <stddef.h>
#include <stdint.h>

typedef uintptr_t Word;
typedef struct Root { Word *slot; struct Root *previous; } Root;
typedef struct Stats {
  uint64_t allocations, payload_bytes, allocation_header_bytes;
  uint64_t minor_count, major_count, copied_bytes, copied_payload_bytes;
  uint64_t promoted_count, reclaimed_bytes, old_total_allocated_bytes;
  uint64_t nursery_allocations, nursery_payload_bytes, direct_old_allocations, direct_old_payload_bytes;
  size_t old_live_bytes, peak_old_bytes, peak_accounted_bytes, root_bytes, peak_root_bytes;
} Stats;
extern Stats stats;
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
