#include "gc.h"
#include <assert.h>
#include <inttypes.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

Stats stats;

#ifdef USE_BOEHM
#include <gc/gc.h>
void *prototype_inline_alloc(long long bytes);
size_t prototype_inline_root_bytes(void);
int prototype_inline_enabled(void);
void heap_init(size_t bytes) { (void)bytes; GC_INIT(); GC_set_free_space_divisor(1); }
void heap_destroy(void) {}
Word allocate(size_t words, uint64_t mask) {
  size_t bytes = words * sizeof(Word);
  void *object;
  if (!mask) object = GC_malloc_atomic(bytes);
#ifdef USE_INLINE
  else object = prototype_inline_alloc((long long)bytes);
#else
  else object = GC_malloc(bytes);
#endif
  assert(object);
  stats.allocations++; stats.payload_bytes += bytes;
  return (Word)object;
}
void store(Word object, size_t index, Word value) { ((Word *)object)[index] = value; }
void minor_collect(void) { GC_gcollect(); stats.minor_count++; }
void major_collect(void) { GC_gcollect(); stats.major_count++; }
int is_young(Word word) { (void)word; return 0; }
size_t nursery_header_size(void) { return 0; }
size_t old_header_size(void) { return 0; }
void print_stats(void) {
  printf("\"allocations\":%" PRIu64 ",\"payload_bytes\":%" PRIu64
         ",\"boehm_heap_bytes\":%zu,\"boehm_free_bytes\":%zu,"
         "\"boehm_heap_minus_free_bytes\":%zu,\"boehm_total_allocated_bytes\":%zu,"
         "\"inline_available\":%d,\"inline_root_bytes\":%zu,\"boehm_free_space_divisor\":%zu,"
         "\"boehm_version_packed\":%u,\"exact_live_bytes\":null",
         stats.allocations, stats.payload_bytes, GC_get_heap_size(), GC_get_free_bytes(),
         GC_get_heap_size() - GC_get_free_bytes(), GC_get_total_bytes(),
         prototype_inline_enabled(), prototype_inline_root_bytes(), GC_get_free_space_divisor(), GC_get_version());
}
#else

typedef struct Header {
  struct Header *next_old, *next_remembered, *work, *forward;
  size_t words;
  uint64_t mask;
  unsigned flags;
} Header;
typedef struct YoungHeader {
  size_t words;
  uint64_t mask;
  Header *forward;
} YoungHeader;
static Root *roots;
enum { REMEMBERED = 1, MARKED = 2 };
static unsigned char *nursery;
static size_t nursery_capacity, used, old_limit;
static Header *old, *remembered, *work;

static size_t object_bytes(size_t words) { return sizeof(Header) + words * sizeof(Word); }
static size_t young_bytes(size_t words) { return sizeof(YoungHeader) + words * sizeof(Word); }
static Header *header(Word word) { return (Header *)word - 1; }
static YoungHeader *young_header(Word word) { return (YoungHeader *)word - 1; }
static Word payload(Header *h) { return (Word)(h + 1); }
size_t nursery_header_size(void) { return sizeof(YoungHeader); }
size_t old_header_size(void) { return sizeof(Header); }
static int pointer(Word word) { return word && !(word & 1); }
int is_young(Word word) {
  return pointer(word) && word >= (Word)nursery && word < (Word)nursery + used;
}
static void account_peak(void) {
  size_t bytes = nursery_capacity + stats.old_live_bytes + stats.root_bytes;
  if (bytes > stats.peak_accounted_bytes) stats.peak_accounted_bytes = bytes;
  if (stats.old_live_bytes > stats.peak_old_bytes) stats.peak_old_bytes = stats.old_live_bytes;
  if (stats.root_bytes > stats.peak_root_bytes) stats.peak_root_bytes = stats.root_bytes;
}
void heap_init(size_t bytes) {
  assert(bytes >= young_bytes(3));
  nursery_capacity = bytes; nursery = malloc(bytes); assert(nursery);
  old_limit = bytes * 4; account_peak();
}
void root_push(Root *root, Word *slot) {
  root->slot = slot; root->previous = roots; roots = root;
  stats.root_bytes += sizeof *root; account_peak();
}
void root_pop(Root *root) {
  assert(roots == root); roots = root->previous; stats.root_bytes -= sizeof *root;
}
static Header *new_old(size_t words, uint64_t mask) {
  size_t bytes = object_bytes(words);
  Header *h = calloc(1, bytes); assert(h);
  h->words = words; h->mask = mask; h->next_old = old; old = h;
  stats.old_live_bytes += bytes; stats.old_total_allocated_bytes += bytes;
  account_peak(); return h;
}
static Word promote(Word word) {
  if (!is_young(word)) return word;
  YoungHeader *from = young_header(word);
  if (from->forward) return payload(from->forward);
  Header *to = new_old(from->words, from->mask);
  memcpy(to + 1, from + 1, from->words * sizeof(Word));
  from->forward = to; to->work = work; work = to;
  stats.promoted_count++; stats.copied_bytes += object_bytes(from->words);
  stats.copied_payload_bytes += from->words * sizeof(Word);
  return payload(to);
}
static void scan_promote(Header *h) {
  Word *fields = (Word *)(h + 1);
  for (size_t i = 0; i < h->words && i < 64; ++i)
    if ((h->mask >> i) & 1) fields[i] = promote(fields[i]);
}
void minor_collect(void) {
  assert(work == NULL); stats.minor_count++;
  for (Root *r = roots; r; r = r->previous) {
    Word relocated = promote(*r->slot);
#ifndef GC_MUTATE_ROOTS
    *r->slot = relocated;
#else
    (void)relocated;
#endif
  }
  while (remembered) {
    Header *h = remembered; remembered = h->next_remembered;
    h->flags &= ~REMEMBERED; h->next_remembered = NULL; scan_promote(h);
  }
  while (work) {
    Header *h = work; work = h->work; h->work = NULL; scan_promote(h);
  }
  memset(nursery, 0xa5, used); used = 0;
}
static void mark(Word word) {
  if (!pointer(word)) return;
  assert(!is_young(word));
  Header *h = header(word);
  if (!(h->flags & MARKED)) { h->flags |= MARKED; h->work = work; work = h; }
}
void major_collect(void) {
  minor_collect(); stats.major_count++;
  for (Root *r = roots; r; r = r->previous) mark(*r->slot);
  while (work) {
    Header *h = work; work = h->work; h->work = NULL;
    Word *fields = (Word *)(h + 1);
    for (size_t i = 0; i < h->words && i < 64; ++i)
      if ((h->mask >> i) & 1) mark(fields[i]);
  }
  Header **link = &old;
  while (*link) {
    Header *h = *link;
    if (h->flags & MARKED) { h->flags &= ~MARKED; link = &h->next_old; }
    else {
      size_t bytes = object_bytes(h->words); *link = h->next_old;
      stats.old_live_bytes -= bytes; stats.reclaimed_bytes += bytes; free(h);
    }
  }
  old_limit = stats.old_live_bytes * 2 + nursery_capacity * 4;
}
Word allocate(size_t words, uint64_t mask) {
  assert(words > 0 && words <= (SIZE_MAX - sizeof(Header)) / sizeof(Word));
  assert(words >= 64 || (mask >> words) == 0);
  size_t bytes = young_bytes(words);
  if (stats.old_live_bytes >= old_limit) major_collect();
  Word result;
  if (bytes > nursery_capacity) {
    result = payload(new_old(words, mask));
    stats.direct_old_allocations++; stats.direct_old_payload_bytes += words * sizeof(Word);
    stats.allocation_header_bytes += sizeof(Header);
  }
  else {
    if (bytes > nursery_capacity - used) {
      minor_collect();
      if (stats.old_live_bytes >= old_limit) major_collect();
    }
    YoungHeader *h = (YoungHeader *)(nursery + used); used += bytes;
    memset(h, 0, bytes); h->words = words; h->mask = mask;
    result = (Word)(h + 1);
    stats.nursery_allocations++; stats.nursery_payload_bytes += words * sizeof(Word);
    stats.allocation_header_bytes += sizeof(YoungHeader);
  }
  stats.allocations++; stats.payload_bytes += words * sizeof(Word);
  return result;
}
void store(Word object, size_t index, Word value) {
  int young = is_young(object);
  size_t words;
  uint64_t mask;
  if (young) { YoungHeader *h = young_header(object); words = h->words; mask = h->mask; }
  else { Header *h = header(object); words = h->words; mask = h->mask; }
  assert(index < words);
  assert(!pointer(value) || (index < 64 && ((mask >> index) & 1)));
  ((Word *)object)[index] = value;
#ifndef GC_MUTATE_BARRIER
  if (!young && is_young(value)) {
    Header *h = header(object);
    if (!(h->flags & REMEMBERED)) {
      h->flags |= REMEMBERED; h->next_remembered = remembered; remembered = h;
    }
  }
#endif
}
void heap_destroy(void) {
  while (old) { Header *h = old; old = h->next_old; free(h); }
  free(nursery); nursery = NULL; roots = NULL; remembered = work = NULL;
}
void print_stats(void) {
  printf("\"allocations\":%" PRIu64 ",\"payload_bytes\":%" PRIu64
         ",\"allocation_header_bytes\":%" PRIu64 ",\"nursery_header_bytes\":%zu,\"old_header_bytes\":%zu,"
         "\"nursery_capacity_bytes\":%zu,\"minor_count\":%" PRIu64 ",\"major_count\":%" PRIu64
         ",\"copied_bytes\":%" PRIu64 ",\"copied_payload_bytes\":%" PRIu64
         ",\"promoted_count\":%" PRIu64
         ",\"reclaimed_bytes\":%" PRIu64 ",\"old_live_bytes\":%zu,\"peak_old_bytes\":%zu,"
         "\"peak_accounted_bytes\":%zu,\"nursery_used_bytes\":%zu,"
         "\"old_total_allocated_bytes\":%" PRIu64 ",\"peak_root_bytes\":%zu,\"exact_live_bytes\":%zu,"
         "\"nursery_allocations\":%" PRIu64 ",\"nursery_payload_bytes\":%" PRIu64
         ",\"direct_old_allocations\":%" PRIu64 ",\"direct_old_payload_bytes\":%" PRIu64,
         stats.allocations, stats.payload_bytes, stats.allocation_header_bytes, sizeof(YoungHeader), sizeof(Header),
         nursery_capacity, stats.minor_count, stats.major_count, stats.copied_bytes, stats.copied_payload_bytes,
         stats.promoted_count, stats.reclaimed_bytes, stats.old_live_bytes, stats.peak_old_bytes,
         stats.peak_accounted_bytes, used, stats.old_total_allocated_bytes, stats.peak_root_bytes, stats.old_live_bytes,
         stats.nursery_allocations, stats.nursery_payload_bytes, stats.direct_old_allocations, stats.direct_old_payload_bytes);
}
#endif
