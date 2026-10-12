#include "gc.h"
#include <assert.h>
#include <inttypes.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

Stats stats;
GcFastState gc_fast;
uintptr_t gc_heap_epoch;

#ifdef USE_BOEHM
#include <gc/gc.h>
void *prototype_inline_alloc(long long bytes);
size_t prototype_inline_root_bytes(void);
int prototype_inline_enabled(void);
void heap_init(size_t bytes) {
  (void)bytes; assert(gc_heap_epoch != UINTPTR_MAX); gc_heap_epoch++;
  memset(&stats, 0, sizeof stats); GC_INIT(); GC_set_free_space_divisor(1);
}
void heap_destroy(void) {}
uintptr_t register_layout(size_t words, uint64_t mask) { (void)words; (void)mask; return 0; }
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
Word allocate_prepared_slow(GcLayout layout) {
  assert(layout.epoch == gc_heap_epoch);
#ifdef USE_CALLER_INLINE
  return allocate_prepared(layout);
#else
  Word object = allocate(layout.words, layout.mask);
  if (!layout.mask) memset((void *)object, 0, layout.words * sizeof(Word));
  return object;
#endif
}
Word allocate_prepared_out_of_line(GcLayout layout) { return allocate_prepared_slow(layout); }
void store_prepared_out_of_line(GcLayout layout, Word object, size_t index, Word value) {
  store_prepared(layout, object, index, value);
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

/* Live headers encode (descriptor index + 1) << 3 and collection flags.
   A forwarded nursery header instead encodes an aligned payload address | 4. */
typedef struct Header { uintptr_t info; } Header;
_Static_assert(sizeof(Word) == 8, "compact prototype requires 64-bit words");
typedef struct Descriptor { size_t words; uint64_t mask; } Descriptor;
typedef struct Pool {
  struct Pool *next, *available_next;
  Header *free;
  size_t slot_bytes, slots, live;
  unsigned char data[];
} Pool;
typedef struct Large {
  struct Large *next;
  size_t bytes;
  Header object;
} Large;
typedef struct Class { Pool *pools, *available; } Class;
typedef struct Queue { Header **items; size_t count, capacity; } Queue;
static const size_t class_sizes[] = {
  16, 32, 48, 64, 80, 96, 112, 128, 160, 192, 224, 256,
  320, 384, 448, 512, 640, 768, 896, 1024, 1280, 1536, 1792, 2048
};
#define CLASS_COUNT (sizeof class_sizes / sizeof class_sizes[0])
#define POOL_BYTES 16384
static Class classes[CLASS_COUNT];
static Descriptor *descriptors;
static uint32_t *descriptor_hash;
static size_t descriptor_count, descriptor_capacity, hash_capacity;
static Root *roots;
enum { REMEMBERED = 1, MARKED = 2, FORWARDED = 4 };
static Large *large_objects;
static Queue remembered, work;

static size_t object_bytes(size_t words) { return sizeof(Header) + words * sizeof(Word); }
static Header *header(Word word) { return (Header *)word - 1; }
static Word payload(Header *h) { return (Word)(h + 1); }
static Descriptor *descriptor(Header *h) {
  size_t id = h->info >> 3;
  assert(id && id <= descriptor_count);
  return &descriptors[id - 1];
}
size_t nursery_header_size(void) { return sizeof(Header); }
size_t old_header_size(void) { return sizeof(Header); }
static int pointer(Word word) { return word && !(word & 1); }
int is_young(Word word) {
  return pointer(word) && word >= (Word)gc_fast.nursery && word < (Word)gc_fast.nursery + gc_fast.used;
}
static size_t static_metadata_bytes(void) {
  return sizeof classes + sizeof class_sizes + sizeof work + sizeof remembered
      + sizeof descriptors + sizeof descriptor_hash + sizeof descriptor_count
      + sizeof descriptor_capacity + sizeof hash_capacity + sizeof roots + sizeof gc_fast
      + sizeof gc_heap_epoch + sizeof large_objects + sizeof stats;
}
static size_t accounted_bytes(void) {
  return gc_fast.capacity + stats.pool_reserved_bytes + stats.large_reserved_bytes
      + stats.descriptor_bytes + stats.work_queue_bytes + stats.remembered_queue_bytes + stats.root_bytes + static_metadata_bytes();
}
static void account_peak_extra(size_t extra) {
  size_t bytes = accounted_bytes() + extra;
  if (bytes > stats.peak_accounted_bytes) stats.peak_accounted_bytes = bytes;
  if (stats.old_live_bytes > stats.peak_old_bytes) stats.peak_old_bytes = stats.old_live_bytes;
  if (stats.root_bytes > stats.peak_root_bytes) stats.peak_root_bytes = stats.root_bytes;
  if (stats.pool_reserved_bytes > stats.peak_pool_reserved_bytes)
    stats.peak_pool_reserved_bytes = stats.pool_reserved_bytes;
}
static void account_peak(void) { account_peak_extra(0); }
static uint64_t descriptor_key(size_t words, uint64_t mask) {
  uint64_t key = mask ^ ((uint64_t)words * UINT64_C(0x9e3779b97f4a7c15));
  key ^= key >> 30; key *= UINT64_C(0xbf58476d1ce4e5b9);
  key ^= key >> 27; key *= UINT64_C(0x94d049bb133111eb);
  return key ^ (key >> 31);
}
static void grow_hash(void) {
  size_t capacity = hash_capacity ? hash_capacity * 2 : 32;
  uint32_t *table = calloc(capacity, sizeof *table); assert(table);
  account_peak_extra(capacity * sizeof *table);
  for (size_t id = 0; id < descriptor_count; ++id) {
    Descriptor *d = &descriptors[id];
    size_t slot = descriptor_key(d->words, d->mask) & (capacity - 1);
    while (table[slot]) slot = (slot + 1) & (capacity - 1);
    table[slot] = (uint32_t)(id + 1);
  }
  free(descriptor_hash); descriptor_hash = table; hash_capacity = capacity;
  stats.descriptor_bytes = descriptor_capacity * sizeof(Descriptor) + hash_capacity * sizeof(uint32_t);
}
static uintptr_t descriptor_info(size_t words, uint64_t mask) {
  if (!hash_capacity || (descriptor_count + 1) * 2 > hash_capacity) grow_hash();
  size_t slot = descriptor_key(words, mask) & (hash_capacity - 1);
  while (descriptor_hash[slot]) {
    size_t id = descriptor_hash[slot]; Descriptor *d = &descriptors[id - 1];
    if (d->words == words && d->mask == mask) return (uintptr_t)id << 3;
    slot = (slot + 1) & (hash_capacity - 1);
  }
  assert(descriptor_count < UINT32_MAX && descriptor_count < (UINTPTR_MAX >> 3));
  if (descriptor_count == descriptor_capacity) {
    size_t capacity = descriptor_capacity ? descriptor_capacity * 2 : 16;
    Descriptor *table = malloc(capacity * sizeof *table); assert(table);
    account_peak_extra(capacity * sizeof *table);
    if (descriptor_count) memcpy(table, descriptors, descriptor_count * sizeof *table);
    free(descriptors); descriptors = table; descriptor_capacity = capacity;
    stats.descriptor_bytes = descriptor_capacity * sizeof(Descriptor) + hash_capacity * sizeof(uint32_t);
  }
  descriptors[descriptor_count] = (Descriptor){words, mask};
  descriptor_hash[slot] = (uint32_t)++descriptor_count;
  account_peak(); return (uintptr_t)descriptor_count << 3;
}
static void queue_push(Queue *q, Header *h, size_t *bytes) {
  if (q->count == q->capacity) {
    size_t capacity = q->capacity ? q->capacity * 2 : 64;
    Header **items = malloc(capacity * sizeof *items); assert(items);
    account_peak_extra(capacity * sizeof *items);
    if (q->count) memcpy(items, q->items, q->count * sizeof *items);
    free(q->items); q->items = items; q->capacity = capacity;
    *bytes = capacity * sizeof *items; account_peak();
  }
  q->items[q->count++] = h;
}
void heap_init(size_t bytes) {
  assert(!gc_fast.nursery && bytes >= object_bytes(3) && bytes <= SIZE_MAX / 4);
  assert(gc_heap_epoch != UINTPTR_MAX); gc_heap_epoch++;
  memset(&stats, 0, sizeof stats);
  gc_fast.capacity = bytes; gc_fast.nursery = malloc(bytes); assert(gc_fast.nursery);
  gc_fast.old_limit = bytes * 4; account_peak();
}
void root_push(Root *root, Word *slot) {
  root->slot = slot; root->previous = roots; roots = root;
  stats.root_bytes += sizeof *root; account_peak();
}
void root_pop(Root *root) {
  assert(roots == root); roots = root->previous; stats.root_bytes -= sizeof *root;
}
static Header *free_next(Header *h) { return *(Header **)(h + 1); }
static void set_free_next(Header *h, Header *next) { *(Header **)(h + 1) = next; }
static Pool *new_pool(size_t class_index) {
  size_t slot_bytes = class_sizes[class_index], slots = POOL_BYTES / slot_bytes;
  size_t bytes = sizeof(Pool) + slots * slot_bytes;
  Pool *p = calloc(1, bytes); assert(p);
  p->slot_bytes = slot_bytes; p->slots = slots;
  for (size_t i = slots; i-- > 0;) {
    Header *h = (Header *)(p->data + i * slot_bytes);
    set_free_next(h, p->free); p->free = h;
  }
  Class *c = &classes[class_index]; p->next = c->pools; c->pools = p;
  p->available_next = c->available; c->available = p;
  stats.pool_reserved_bytes += bytes; stats.pool_count++; stats.pool_allocations++;
  account_peak(); return p;
}
static Header *new_old(uintptr_t info, const Header *source) {
  Descriptor *d = &descriptors[(info >> 3) - 1]; size_t bytes = object_bytes(d->words);
  Header *h;
  size_t class_index = 0;
  while (class_index < CLASS_COUNT && class_sizes[class_index] < bytes) ++class_index;
  if (class_index == CLASS_COUNT) {
    size_t reserved = offsetof(Large, object) + bytes;
    Large *l = calloc(1, reserved); assert(l);
    l->bytes = bytes; l->next = large_objects; large_objects = l; h = &l->object;
    stats.large_reserved_bytes += reserved; stats.large_object_count++;
  } else {
    Class *c = &classes[class_index]; Pool *p = c->available;
    if (!p) p = new_pool(class_index);
    h = p->free; p->free = free_next(h); p->live++;
    if (!p->free) { c->available = p->available_next; p->available_next = NULL; }
    /* Dead slots use bit 2 with a zero descriptor index to distinguish reuse. */
    if (h->info == FORWARDED) stats.pool_reused_slots++;
    if (source) {
      /* Promotion overwrites the complete logical payload; only padding needs clearing. */
      if (p->slot_bytes > bytes) memset((unsigned char *)h + bytes, 0, p->slot_bytes - bytes);
    } else memset(h, 0, p->slot_bytes);
    stats.old_slot_bytes += p->slot_bytes; stats.pooled_allocations++;
  }
  h->info = info;
  if (source) memcpy(h + 1, source + 1, bytes - sizeof(Header));
  stats.old_live_bytes += bytes; stats.old_live_payload_bytes += bytes - sizeof(Header);
  stats.old_object_count++; stats.old_total_allocated_bytes += bytes;
  /* Pooled slots add no reserved storage; new_pool already accounts pool growth. */
  if (class_index == CLASS_COUNT) account_peak();
  else if (stats.old_live_bytes > stats.peak_old_bytes) stats.peak_old_bytes = stats.old_live_bytes;
  return h;
}
uintptr_t register_layout(size_t words, uint64_t mask) {
  assert(gc_fast.nursery); return descriptor_info(words, mask);
}
Word allocate_prepared_slow(GcLayout layout) {
  assert(layout.epoch == gc_heap_epoch);
  assert((layout.info >> 3) && (layout.info >> 3) <= descriptor_count);
  assert(descriptors[(layout.info >> 3) - 1].words == layout.words);
  assert(descriptors[(layout.info >> 3) - 1].mask == layout.mask);
  size_t bytes = object_bytes(layout.words); Word result;
  if (stats.old_live_bytes >= gc_fast.old_limit) major_collect();
  if (bytes > gc_fast.capacity) {
    result = payload(new_old(layout.info, NULL));
    stats.direct_old_allocations++; stats.direct_old_payload_bytes += layout.words * sizeof(Word);
  } else {
    if (bytes > gc_fast.capacity - gc_fast.used) {
      minor_collect();
      if (stats.old_live_bytes >= gc_fast.old_limit) major_collect();
    }
    Header *h = (Header *)(gc_fast.nursery + gc_fast.used); gc_fast.used += bytes;
#ifndef GC_MUTATE_ZERO
    memset(h, 0, bytes);
#endif
    h->info = layout.info; result = payload(h);
    stats.nursery_allocations++; stats.nursery_payload_bytes += layout.words * sizeof(Word);
  }
  stats.allocation_header_bytes += sizeof(Header);
  stats.allocations++; stats.payload_bytes += layout.words * sizeof(Word);
  return result;
}
/* Calling the slow allocator here keeps the outline ablation independent of
   the caller-inline implementation, including its nursery-hit branch. */
Word allocate_prepared_out_of_line(GcLayout layout) { return allocate_prepared_slow(layout); }
void remember_prepared(Word object) {
  Header *h = header(object); h->info |= REMEMBERED;
  queue_push(&remembered, h, &stats.remembered_queue_bytes);
}
void store_prepared_out_of_line(GcLayout layout, Word object, size_t index, Word value) {
  store_prepared(layout, object, index, value);
}
static Word promote(Word word) {
  if (!is_young(word)) return word;
  Header *from = header(word);
  if (from->info & FORWARDED) return from->info & ~(uintptr_t)7;
  size_t words = descriptor(from)->words;
  Header *to = new_old(from->info, from);
  from->info = payload(to) | FORWARDED;
  queue_push(&work, to, &stats.work_queue_bytes);
  stats.promoted_count++; stats.copied_bytes += object_bytes(words);
  stats.copied_payload_bytes += words * sizeof(Word);
  return payload(to);
}
static void scan_promote(Header *h) {
  Descriptor d = *descriptor(h); Word *fields = (Word *)(h + 1);
  for (size_t i = 0; i < d.words && i < 64; ++i)
    if ((d.mask >> i) & 1) fields[i] = promote(fields[i]);
}
void minor_collect(void) {
  assert(work.count == 0); stats.minor_count++;
  for (Root *r = roots; r; r = r->previous) {
    Word relocated = promote(*r->slot);
#ifndef GC_MUTATE_ROOTS
    *r->slot = relocated;
#else
    (void)relocated;
#endif
  }
  while (remembered.count) {
    Header *h = remembered.items[--remembered.count];
    h->info &= ~(uintptr_t)REMEMBERED; scan_promote(h);
  }
  while (work.count) scan_promote(work.items[--work.count]);
  memset(gc_fast.nursery, 0xa5, gc_fast.used); gc_fast.used = 0;
}
static void mark(Word word) {
  if (!pointer(word)) return;
  assert(!is_young(word)); Header *h = header(word);
  (void)descriptor(h);
  if (!(h->info & MARKED)) {
    h->info |= MARKED; queue_push(&work, h, &stats.work_queue_bytes);
  }
}
static void reclaim(Header *h) {
  size_t bytes = object_bytes(descriptor(h)->words);
  stats.old_live_bytes -= bytes; stats.old_live_payload_bytes -= bytes - sizeof(Header);
  stats.old_object_count--; stats.reclaimed_bytes += bytes;
}
void major_collect(void) {
  minor_collect(); stats.major_count++;
  for (Root *r = roots; r; r = r->previous) mark(*r->slot);
  while (work.count) {
    Header *h = work.items[--work.count]; Descriptor d = *descriptor(h);
    Word *fields = (Word *)(h + 1);
    for (size_t i = 0; i < d.words && i < 64; ++i)
      if ((d.mask >> i) & 1) mark(fields[i]);
  }
  for (size_t ci = 0; ci < CLASS_COUNT; ++ci) {
    Class *c = &classes[ci]; c->available = NULL; Pool **link = &c->pools;
    while (*link) {
      Pool *p = *link; p->free = NULL;
      for (size_t i = p->slots; i-- > 0;) {
        Header *h = (Header *)(p->data + i * p->slot_bytes);
        if (h->info >> 3) {
          if (h->info & MARKED) { h->info &= ~(uintptr_t)MARKED; continue; }
          reclaim(h); stats.old_slot_bytes -= p->slot_bytes; p->live--; h->info = FORWARDED;
        }
        set_free_next(h, p->free); p->free = h;
      }
      /* Empty pools leave no reserved capacity; partially occupied pools retain
         their free slots until the next sweep and allocation cycle. */
      if (!p->live) {
        *link = p->next; stats.pool_reserved_bytes -= sizeof(Pool) + p->slots * p->slot_bytes;
        stats.pool_count--; stats.pool_releases++; free(p);
      } else {
        if (p->free) { p->available_next = c->available; c->available = p; }
        link = &p->next;
      }
    }
  }
  Large **link = &large_objects;
  while (*link) {
    Large *l = *link; Header *h = &l->object;
    if (h->info & MARKED) { h->info &= ~(uintptr_t)MARKED; link = &l->next; }
    else {
      reclaim(h); *link = l->next;
      stats.large_reserved_bytes -= offsetof(Large, object) + l->bytes;
      stats.large_object_count--; free(l);
    }
  }
  gc_fast.old_limit = stats.old_live_bytes > (SIZE_MAX - gc_fast.capacity * 4) / 2
      ? SIZE_MAX : stats.old_live_bytes * 2 + gc_fast.capacity * 4;
}
Word allocate(size_t words, uint64_t mask) {
  assert(words > 0 && words <= (SIZE_MAX - sizeof(Large)) / sizeof(Word));
  assert(words >= 64 || (mask >> words) == 0);
  size_t bytes = object_bytes(words);
  if (stats.old_live_bytes >= gc_fast.old_limit) major_collect();
  uintptr_t info = descriptor_info(words, mask); Word result;
  if (bytes > gc_fast.capacity) {
    result = payload(new_old(info, NULL));
    stats.direct_old_allocations++; stats.direct_old_payload_bytes += words * sizeof(Word);
  } else {
    if (bytes > gc_fast.capacity - gc_fast.used) {
      minor_collect();
      if (stats.old_live_bytes >= gc_fast.old_limit) major_collect();
    }
    Header *h = (Header *)(gc_fast.nursery + gc_fast.used); gc_fast.used += bytes;
    memset(h, 0, bytes); h->info = info; result = payload(h);
    stats.nursery_allocations++; stats.nursery_payload_bytes += words * sizeof(Word);
  }
  stats.allocation_header_bytes += sizeof(Header);
  stats.allocations++; stats.payload_bytes += words * sizeof(Word);
  return result;
}
void store(Word object, size_t index, Word value) {
  int young = is_young(object); Header *h = header(object); Descriptor *d = descriptor(h);
  assert(index < d->words);
  assert(!pointer(value) || (index < 64 && ((d->mask >> index) & 1)));
  ((Word *)object)[index] = value;
#ifndef GC_MUTATE_BARRIER
  if (!young && is_young(value) && !(h->info & REMEMBERED)) {
    h->info |= REMEMBERED; queue_push(&remembered, h, &stats.remembered_queue_bytes);
  }
#else
  (void)young;
#endif
}
void heap_destroy(void) {
  assert(!roots);
  for (size_t ci = 0; ci < CLASS_COUNT; ++ci) {
    Pool *p = classes[ci].pools;
    while (p) { Pool *next = p->next; free(p); p = next; }
    classes[ci] = (Class){0};
  }
  while (large_objects) { Large *next = large_objects->next; free(large_objects); large_objects = next; }
  free(gc_fast.nursery); free(descriptors); free(descriptor_hash); free(work.items); free(remembered.items);
  gc_fast.nursery = NULL; descriptors = NULL; descriptor_hash = NULL;
  gc_fast.capacity = gc_fast.used = descriptor_count = descriptor_capacity = hash_capacity = 0;
  work = remembered = (Queue){0};
  stats.old_live_bytes = stats.old_live_payload_bytes = stats.old_object_count = 0;
  stats.old_slot_bytes = stats.pool_reserved_bytes = stats.large_reserved_bytes = 0;
  stats.descriptor_bytes = stats.work_queue_bytes = stats.remembered_queue_bytes = 0;
  stats.pool_count = stats.large_object_count = 0;
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
         stats.allocations, stats.payload_bytes, stats.allocation_header_bytes, sizeof(Header), sizeof(Header),
         gc_fast.capacity, stats.minor_count, stats.major_count, stats.copied_bytes, stats.copied_payload_bytes,
         stats.promoted_count, stats.reclaimed_bytes, stats.old_live_bytes, stats.peak_old_bytes,
         stats.peak_accounted_bytes, gc_fast.used, stats.old_total_allocated_bytes, stats.peak_root_bytes, stats.old_live_bytes,
         stats.nursery_allocations, stats.nursery_payload_bytes, stats.direct_old_allocations, stats.direct_old_payload_bytes);
  size_t large_metadata = stats.large_object_count * offsetof(Large, object);
  size_t large_logical = stats.large_reserved_bytes - large_metadata;
  printf(",\"old_slot_bytes\":%zu,\"pool_reserved_bytes\":%zu,\"peak_pool_reserved_bytes\":%zu,"
         "\"pool_count\":%zu,\"pool_allocations\":%" PRIu64 ",\"pool_releases\":%" PRIu64
         ",\"pooled_allocations\":%" PRIu64 ",\"pool_reused_slots\":%" PRIu64
         ",\"pool_padding_bytes\":%zu,\"large_reserved_bytes\":%zu,\"large_metadata_bytes\":%zu,"
         "\"large_object_count\":%zu,\"descriptor_bytes\":%zu,\"descriptor_count\":%zu,"
         "\"work_queue_bytes\":%zu,\"remembered_queue_bytes\":%zu,\"accounted_bytes\":%zu,"
         "\"exact_live_payload_bytes\":%zu,\"static_metadata_bytes\":%zu,\"root_bytes\":%zu,\"old_object_count\":%zu",
         stats.old_slot_bytes, stats.pool_reserved_bytes, stats.peak_pool_reserved_bytes,
         stats.pool_count, stats.pool_allocations, stats.pool_releases,
         stats.pooled_allocations, stats.pool_reused_slots,
         stats.old_slot_bytes - (stats.old_live_bytes - large_logical), stats.large_reserved_bytes, large_metadata,
         stats.large_object_count, stats.descriptor_bytes, descriptor_count,
         stats.work_queue_bytes, stats.remembered_queue_bytes, accounted_bytes(),
         stats.old_live_payload_bytes, static_metadata_bytes(), stats.root_bytes, stats.old_object_count);
}
#endif
