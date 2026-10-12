/* Counted wrappers for the append runtime calls (see appends.py). */
#include <stdio.h>
#include <stdlib.h>
typedef long long i64;
i64 mdk_string_append(i64, i64);
i64 mdk_append(i64, i64);
i64 mdk_list_append(i64, i64);
static unsigned long long n[NSITES];
i64 cnt_mdk_string_append(i64 id, i64 a, i64 b) { n[id]++; return mdk_string_append(a, b); }
i64 cnt_mdk_append(i64 id, i64 a, i64 b) { n[id]++; return mdk_append(a, b); }
i64 cnt_mdk_list_append(i64 id, i64 a, i64 b) { n[id]++; return mdk_list_append(a, b); }
__attribute__((destructor)) static void dump(void) {
  const char *p = getenv("APPEND_COUNT_OUT");
  if (!p) return;
  FILE *f = fopen(p, "w");
  if (!f) return;
  for (long i = 0; i < NSITES; i++) if (n[i]) fprintf(f, "%ld\t%llu\n", i, n[i]);
  fclose(f);
}
