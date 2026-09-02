# Findings — S-sqltoken-extract (sqlite: seek instead of scan, #2541)

Task: a mechanical, zero-behavior-change extraction of `sqlparse.mdk`'s five
lexeme-level parsers into a new AST-free `sqlite/lib/sqltoken.mdk`, inserted
mid-sprint to break a module cycle `S-plan` discovered. Landed
`7614039c10abd8b175d6b2e89d1d315c5ffde2bb`.

## F1 — Medaka's no-cycle rule reaches through three modules on a purely-lexical import

- **Category:** surprising-semantics (module system, not a bug)
- **Severity:** none — this is by design; the finding is that the *distance*
  of a cycle can be non-obvious
- **Detail:** `lib.schemadef` importing five purely-lexical parser functions
  from `lib.sqlparse` (no AST types involved) was enough to make ANY module
  `select.mdk` can import (which is most of the library, since `sqlparse`
  builds `select.mdk`'s own AST) form a cycle with a downstream consumer of
  `schemadef` — in this case `lib.indexlookup`. The cycle trace named 5 hops;
  the actual fix touched only one 2-file edge.
- **Disposition:** not-a-finding requiring compiler action — Medaka's
  "no re-export, no cycles" rule worked exactly as documented
  (`AGENTS.md`'s module-system section); this is a note for future sprint
  contract authors that a slice naming a "new module importing X" surface
  should have its transitive import graph checked before the slice is
  scoped, not discovered by a mid-sprint refusal.

No compiler/stdlib/tooling findings from this slice — it is a pure,
zero-behavior-change library refactor, verified line-for-line: all 97
non-import, non-blank lines removed from `sqlparse.mdk` appear byte-identically
in `sqltoken.mdk` (confirmed independently by the end-of-sprint review).
