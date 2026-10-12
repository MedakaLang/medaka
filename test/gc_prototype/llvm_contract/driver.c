#include "gc.h"
#include <stddef.h>
#include <stdio.h>

_Static_assert(sizeof(Word) == 8, "LLVM fixture requires 64-bit words");
_Static_assert(sizeof(Root) == 16 && offsetof(Root, previous) == 8,
               "LLVM fixture root layout must match gc.h");

extern Word contract_reload(void);
extern Word contract_arguments(void);
extern Word contract_tail(Word incoming, Word remaining);

int main(void) {
  heap_init(256);
  Word result = contract_reload();
  if (result) {
    fprintf(stderr, "LLVM contract: moved root reload failed\n");
    heap_destroy();
    return 1;
  }
  if (contract_arguments()) {
    fprintf(stderr, "LLVM contract: earlier argument relocation failed\n");
    heap_destroy();
    return 2;
  }
  Word input = allocate(2, 2);
  store(input, 0, integer(8));
  store(input, 1, integer(137));
  Word output = contract_tail(input, 10000);
  if (load(output, 1) != integer(137) || stats.root_bytes != 0) {
    fprintf(stderr, "LLVM contract: tail transfer or root balance failed\n");
    heap_destroy();
    return 3;
  }
  major_collect();
  if (stats.old_live_bytes != 0) {
    fprintf(stderr, "LLVM contract: roots remained after return\n");
    heap_destroy();
    return 4;
  }
  heap_destroy();
  puts("LLVM rooting contract: checked 3 (reload, arguments, musttail)");
  return 0;
}
