/* C sanity ceiling for test/bench_fixtures/bintrees.mdk — same binary-tree
 * churn (build depth 15, 200 iterations, count nodes), using malloc/free
 * instead of Boehm GC. Compiled with -O2. Establishes an upper bound on how
 * fast this shape of allocation-heavy computation can go on this box, for
 * compiler/PERF-RUNTIME.md's C sanity paragraph. Not built or run by any
 * gate. */
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
