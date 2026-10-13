/* Retention census for test/retain_census.sh (#4090).
 *
 * Every allocation carries one hidden header word naming where it was made, and the
 * caller gets the cell 8 bytes past it (Boehm recognises interior pointers, so the
 * cell keeps its header alive):
 *
 *   MAGIC << 48 | class << 47 | id << 24 | min(n, 2^24 - 1)
 *
 * class 0: an emitted mdk_alloc site, id = its row in sites.tsv (escape.py).
 * class 1: a runtime (C) caller of mdk_alloc, id = a slot keyed by return address;
 *          or, with id >= APP_BASE, a cons cell built by `++` at the call site
 *          `id - APP_BASE` in appsites.tsv (append_sites.py).
 *
 * Every RETAIN_STEP bytes allocated (default 1e9) the census forces a full
 * collection and walks the reachable objects, summing bytes per header.  With
 * RETAIN_REF_SITES (emitted site ids) and/or RETAIN_REF_APP (`++` site ids), it also
 * counts, per referrer header, the fields that point into an object of that target
 * set: what holds the targets live.  Output goes to RETAIN_OUT. */
#define GC_THREADS
#include <gc.h>
#include <gc/gc_mark.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#ifndef NSITES
#error NSITES
#endif

#define MAGIC 0xC5A5ULL
#define RT_SLOTS 8192
#define APP_BASE 0x400000u
#define APP_SLOTS 16384
#define REF_SLOTS 65536

static unsigned long long site_b[NSITES], site_n[NSITES];
static unsigned long long rt_b[RT_SLOTS], rt_n[RT_SLOTS];
static void *rt_pc[RT_SLOTS];
static unsigned long long app_b[APP_SLOTS], app_n[APP_SLOTS];
static unsigned long long untagged_b, untagged_n;
static unsigned char tgt_site[NSITES], tgt_app[APP_SLOTS];
static unsigned long long ref_key[REF_SLOTS], ref_cnt[REF_SLOTS];
static int refs_on, census_no, in_census;
static unsigned long long since, step, total_alloc;
static FILE *out;

static unsigned rt_slot(void *pc) {
  unsigned long h = ((unsigned long)pc >> 2) % RT_SLOTS;
  while (rt_pc[h] && rt_pc[h] != pc) h = (h + 1) % RT_SLOTS;
  rt_pc[h] = pc;
  return (unsigned)h;
}

/* the 24 class+id bits of a header word, or -1 when the object carries none */
static long header_key(unsigned long long w) {
  if ((w >> 48) != MAGIC) return -1;
  return (long)((w >> 24) & 0xffffff);
}

static int is_target(long key) {
  if (key < 0) return 0;
  unsigned id = (unsigned)(key & 0x7fffff);
  if (!(key >> 23)) return id < NSITES && tgt_site[id];
  return id >= APP_BASE && id - APP_BASE < APP_SLOTS && tgt_app[id - APP_BASE];
}

static void ref_note(long key) {
  unsigned long long k = (unsigned long long)key + 1;
  unsigned long h = (k * 0x9E3779B97F4A7C15ULL) >> 48;
  while (ref_key[h] && ref_key[h] != k) h = (h + 1) % REF_SLOTS;
  ref_key[h] = k;
  ref_cnt[h]++;
}

static void GC_CALLBACK visit(void *obj, size_t bytes, void *cd) {
  (void)cd;
  long key = header_key(*(unsigned long long *)obj);
  if (key < 0) {
    untagged_b += bytes; untagged_n++;
    return;
  }
  unsigned id = (unsigned)(key & 0x7fffff);
  if (!(key >> 23)) {
    if (id < NSITES) { site_b[id] += bytes; site_n[id]++; }
  } else if (id >= APP_BASE) {
    if (id - APP_BASE < APP_SLOTS) { app_b[id - APP_BASE] += bytes; app_n[id - APP_BASE]++; }
  } else if (id < RT_SLOTS) {
    rt_b[id] += bytes; rt_n[id]++;
  }
  if (refs_on && !is_target(key)) {
    /* conservative, like the collector: any word that lands in a target object */
    const unsigned long long *f = (const unsigned long long *)obj;
    for (size_t i = 1; i < bytes / 8; i++) {
      unsigned long long p = f[i];
      if ((p & 7) || p < 4096) continue;
      void *b = GC_base((void *)p);
      if (b && is_target(header_key(*(unsigned long long *)b))) ref_note(key);
    }
  }
}

static void *GC_CALLBACK enumerate(void *cd) {
  GC_enumerate_reachable_objects_inner(visit, cd);
  return NULL;
}

static void census(void) {
  in_census = 1;
  GC_gcollect();
  memset(site_b, 0, sizeof site_b); memset(site_n, 0, sizeof site_n);
  memset(rt_b, 0, sizeof rt_b); memset(rt_n, 0, sizeof rt_n);
  memset(app_b, 0, sizeof app_b); memset(app_n, 0, sizeof app_n);
  memset(ref_key, 0, sizeof ref_key); memset(ref_cnt, 0, sizeof ref_cnt);
  untagged_b = untagged_n = 0;
  GC_call_with_alloc_lock(enumerate, NULL);
  census_no++;
  fprintf(out, "census\t%d\t%llu\t%zu\n", census_no, total_alloc, GC_get_heap_size());
  for (long i = 0; i < NSITES; i++)
    if (site_n[i]) fprintf(out, "site\t%ld\t%llu\t%llu\n", i, site_n[i], site_b[i]);
  for (long i = 0; i < RT_SLOTS; i++)
    if (rt_n[i]) fprintf(out, "rt\t%ld\t%p\t%llu\t%llu\n", i, rt_pc[i], rt_n[i], rt_b[i]);
  for (long i = 0; i < APP_SLOTS; i++)
    if (app_n[i]) fprintf(out, "app\t%ld\t%llu\t%llu\n", i, app_n[i], app_b[i]);
  fprintf(out, "untagged\t%llu\t%llu\n", untagged_n, untagged_b);
  for (long i = 0; i < REF_SLOTS; i++)
    if (ref_cnt[i]) fprintf(out, "ref\t%llu\t%llu\n", ref_key[i] - 1, ref_cnt[i]);
  fflush(out);
  in_census = 0;
}

static void parse_ids(const char *s, unsigned char *set, long n) {
  while (s && *s) {
    char *end;
    long id = strtol(s, &end, 10);
    if (end == s) break;
    if (id >= 0 && id < n) { set[id] = 1; refs_on = 1; }
    s = *end == ',' ? end + 1 : end;
  }
}

static void note_alloc(long long n) {
  if (!step) {
    const char *s = getenv("RETAIN_STEP");
    const char *p = getenv("RETAIN_OUT");
    step = s ? strtoull(s, NULL, 10) : 1000000000ULL;
    if (p) out = fopen(p, "w");
    parse_ids(getenv("RETAIN_REF_SITES"), tgt_site, NSITES);
    parse_ids(getenv("RETAIN_REF_APP"), tgt_app, APP_SLOTS);
  }
  total_alloc += (unsigned long long)n;
  since += (unsigned long long)n;
  if (out && since >= step && !in_census) { since = 0; census(); }
}

static void *tagged(void *base, unsigned long long cls, unsigned long long id, long long n) {
  unsigned long long nn = n < 0xffffff ? (unsigned long long)n : 0xffffff;
  *(unsigned long long *)base = (MAGIC << 48) | (cls << 47) | ((id & 0x7fffff) << 24) | nn;
  return (char *)base + 8;
}

void *mdk_alloc_site(long long n, long long id) {
  note_alloc(n);
  return tagged(GC_malloc((size_t)n + 8), 0, (unsigned long long)id, n);
}
void *mdk_alloc_atomic_site(long long n, long long id) {
  note_alloc(n);
  return tagged(GC_malloc_atomic((size_t)n + 8), 0, (unsigned long long)id, n);
}

__attribute__((noinline)) void *mdk_alloc(long long n) {
  unsigned s = rt_slot(__builtin_return_address(0));
  note_alloc(n);
  return tagged(GC_malloc((size_t)n + 8), 1, s, n);
}
__attribute__((noinline)) void *mdk_alloc_atomic(long long n) {
  unsigned s = rt_slot(__builtin_return_address(0));
  note_alloc(n);
  return tagged(GC_malloc_atomic((size_t)n + 8), 1, s, n);
}

/* `xs ++ ys` on a List, as runtime/medaka_rt.c's mdk_list_append builds it, with each
 * new cons cell tagged by the call site. */
long long mdk_cons(long long head, long long tail);
long long mdk_append(long long a, long long b);
static long long cons_tag = -1;

long long mdk_list_append_site(long long xs, long long ys, long long id) {
  long long n = 0;
  for (long long w = xs; (w & 1) == 0; w = ((const long long *)w)[2]) n++;
  if (n == 0) return ys;
  if (cons_tag == -1) cons_tag = ((const long long *)mdk_cons(1, 1))[0];
  long long *heads = (long long *)GC_malloc(8 * (size_t)n);
  long long i = 0;
  for (long long w = xs; (w & 1) == 0; w = ((const long long *)w)[2])
    heads[i++] = ((const long long *)w)[1];
  long long acc = ys;
  for (long long j = n - 1; j >= 0; j--) {
    note_alloc(24);
    long long *c = (long long *)tagged(GC_malloc(32), 1, APP_BASE + (unsigned long long)id, 24);
    c[0] = cons_tag; c[1] = heads[j]; c[2] = acc;
    acc = (long long)c;
  }
  return acc;
}

long long mdk_append_site(long long a, long long b, long long id) {
  if (cons_tag == -1) cons_tag = ((const long long *)mdk_cons(1, 1))[0];
  if ((a & 1) == 0 && ((const long long *)a)[0] == cons_tag)
    return mdk_list_append_site(a, b, id);
  return mdk_append(a, b);
}

__attribute__((destructor)) static void finish(void) {
  if (out) { fprintf(out, "end\t%llu\n", total_alloc); fclose(out); out = NULL; }
}
