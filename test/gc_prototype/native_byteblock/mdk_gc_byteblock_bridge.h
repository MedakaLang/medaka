#ifndef MDK_GC_BYTEBLOCK_BRIDGE_H
#define MDK_GC_BYTEBLOCK_BRIDGE_H
#include "../gc.h"
#include <limits.h>
typedef Word MdkByteBlockWord;
typedef Root MdkByteBlockRoot;
_Static_assert(sizeof(Word) == 8 && sizeof(long long) == 8, "native word ABI");
Word mdk_gc_byteblock_atomic_v1(size_t bytes);
void mdk_gc_byteblock_check_allocation_v1(Word object, size_t requested);
void mdk_gc_byteblock_begin_copy_v1(Root *root, Word *slot);
void mdk_gc_byteblock_push_source_v1(Root *root, Word *slot);
void mdk_gc_byteblock_check_source_v1(Word source);
void mdk_gc_byteblock_end_copy_v1(Root *root);
void mdk_gc_byteblock_join_v1(int result);
void mdk_gc_byteblock_fail_v1(const char *reason);
static inline size_t mdk_gc_byteblock_extent_v1(long long count) {
  if (count < 0 || count > LLONG_MAX - 23)
    mdk_gc_byteblock_fail_v1("byteblock-signed-extent");
  unsigned long long bytes = 16ULL + ((unsigned long long)count + 7) / 8 * 8;
  if (bytes > SIZE_MAX || bytes / sizeof(Word) > (SIZE_MAX - 3 * sizeof(Word)) / sizeof(Word))
    mdk_gc_byteblock_fail_v1("byteblock-object-extent");
  return (size_t)bytes;
}
#endif
