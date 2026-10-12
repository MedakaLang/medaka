/* Per-site allocation counters for the escape census.  Linked alongside a copy
 * of runtime/medaka_rt.c whose mdk_alloc/mdk_alloc_atomic are renamed to
 * mdk_alloc_rt_real/... and wrapped here so runtime-internal callers are counted
 * by return address.  Dump at exit to $ALLOC_COUNT_OUT. */
#define GC_THREADS
#include <gc.h>
#include <stdio.h>
#include <stdlib.h>

#ifndef NSITES
#error NSITES
#endif

static unsigned long long site_n[NSITES], site_b[NSITES];

void *mdk_alloc_site(long long n, long long id) {
  site_n[id]++; site_b[id] += (unsigned long long)n;
  return GC_malloc((size_t)n);
}
void *mdk_alloc_atomic_site(long long n, long long id) {
  site_n[id]++; site_b[id] += (unsigned long long)n;
  return GC_malloc_atomic((size_t)n);
}

#define RT_SLOTS 8192
static void *rt_pc[RT_SLOTS];
static unsigned long long rt_n[RT_SLOTS], rt_b[RT_SLOTS];

static void rt_note(void *pc, long long n) {
  unsigned long h = ((unsigned long)pc >> 2) % RT_SLOTS;
  while (rt_pc[h] && rt_pc[h] != pc) h = (h + 1) % RT_SLOTS;
  rt_pc[h] = pc; rt_n[h]++; rt_b[h] += (unsigned long long)n;
}

__attribute__((noinline)) void *mdk_alloc(long long n) {
  rt_note(__builtin_return_address(0), n);
  return GC_malloc((size_t)n);
}
__attribute__((noinline)) void *mdk_alloc_atomic(long long n) {
  rt_note(__builtin_return_address(0), n);
  return GC_malloc_atomic((size_t)n);
}

__attribute__((destructor)) static void dump(void) {
  const char *p = getenv("ALLOC_COUNT_OUT");
  if (!p) return;
  FILE *f = fopen(p, "w");
  if (!f) return;
  fprintf(f, "total_bytes\t%zu\n", GC_get_total_bytes());
  for (long i = 0; i < NSITES; i++)
    if (site_n[i]) fprintf(f, "site\t%ld\t%llu\t%llu\n", i, site_n[i], site_b[i]);
  for (long i = 0; i < RT_SLOTS; i++)
    if (rt_pc[i]) fprintf(f, "rt\t%p\t%llu\t%llu\n", rt_pc[i], rt_n[i], rt_b[i]);
  fclose(f);
}
