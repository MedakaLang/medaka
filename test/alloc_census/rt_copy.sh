#!/bin/sh
# rt_copy.sh <medaka_rt.c> <out.c> -- helper of test/alloc_census.sh and
# test/retain_census.sh: a copy of the runtime whose mdk_alloc/mdk_alloc_atomic are
# declarations only, so a census can link its own counting definitions. The
# libgc-8.2 inline allocator is a second definition of mdk_alloc and is switched
# off with it. Exits 1, naming the runtime lines it could not find, when the
# runtime has moved under it: a census linked against a stray definition fails
# its link, and both census scripts report a failed link as SKIPPED.
set -u
sed -e 's|^#if GC_VERSION_MAJOR == 8 \&\& GC_VERSION_MINOR == 2$|#if 0 /* census: inline allocator off */|' \
    -e 's|^void \*mdk_alloc(long long n) { return GC_malloc((size_t)n); }$|void *mdk_alloc(long long n);|' \
    -e 's|^void \*mdk_alloc_atomic(long long n) { return GC_malloc_atomic((size_t)n); }$|void *mdk_alloc_atomic(long long n);|' \
    "$1" > "$2"
n=$(grep -c -e '^#if 0 /\* census: inline allocator off \*/$' \
            -e '^void \*mdk_alloc(long long n);$' \
            -e '^void \*mdk_alloc_atomic(long long n);$' "$2")
if [ "$n" != 3 ]; then
  echo "rt_copy: found $n of the 3 runtime allocator lines; update test/alloc_census/rt_copy.sh"
  exit 1
fi
