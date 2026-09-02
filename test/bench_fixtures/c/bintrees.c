/* C sanity ceiling for test/bench_fixtures/bintrees.mdk — same tree shape and
 * allocation count (build depth 15, 200 iterations, 2^16-1 Node mallocs/tree
 * each), using malloc/free instead of Boehm GC. NOT traversal-equivalent:
 * check() here short-circuits at `l == NULL` (a depth-15 node, whose l/r are
 * both NULL) and never recurses into it, invoking check() exactly once per
 * Node — 2^16-1 = 65,535 calls/tree (measured by instrumented count). The
 * Medaka bintrees.mdk's `make` materializes explicit `Leaf` values as the
 * children of each depth-0 `Node` (2^16 of them, zero-cost since Leaf is a
 * nullary/immediate constructor — the alloc count above still matches), and
 * its `check` pattern-matches on Leaf too, invoking check() once per Tree
 * VALUE (Node + Leaf) — 2^17-1 = 131,071 calls/tree, exactly 2x the C
 * version's traversal work, not 4x. Compiled with -O2. Establishes an upper
 * bound on how fast this shape of allocation-heavy computation can go on
 * this box, for compiler/PERF-RUNTIME.md's C sanity paragraph —
 * informational only for bintrees, not an apples-to-apples traversal
 * comparison. Not built or run by any gate. */
#include <stdio.h>
#include <stdlib.h>

typedef struct Node {
  struct Node *l, *r;
} Node;

static Node *make(int d) {
  Node *n = malloc(sizeof(Node));
  if (d == 0) {
    n->l = NULL;
    n->r = NULL;
  } else {
    n->l = make(d - 1);
    n->r = make(d - 1);
  }
  return n;
}

static long check(Node *n) {
  if (n->l == NULL) return 0;
  return 1 + check(n->l) + check(n->r);
}

static void free_tree(Node *n) {
  if (n->l != NULL) {
    free_tree(n->l);
    free_tree(n->r);
  }
  free(n);
}

int main(void) {
  long acc = 0;
  for (int i = 0; i < 200; i++) {
    Node *t = make(15);
    acc += check(t);
    free_tree(t);
  }
  printf("%ld\n", acc);
  return 0;
}
