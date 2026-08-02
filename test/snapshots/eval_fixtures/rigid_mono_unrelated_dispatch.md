# META
source_lines=51
stages=CORE_IR
# SOURCE
-- #1110 ARCH A-1 PR A: `Mono.TRigid`, the rigid type-variable constructor split
-- out of `Mono.TCon` (compiler/types/typecheck.mdk).
--
-- ⚠️ THE ASSERTION HERE IS ABOUT THE CODE THAT MENTIONS NO TYPE VARIABLE AT ALL.
-- `Holder`'s field type names `q`, which is not a parameter of the declaration,
-- so elaborating it takes `fromAstTypeE`'s `TyVar` fallback and MINTS a rigid
-- into this program's type environment.  Nothing below `Holder` refers to it:
-- every interface head, every impl head and every operand from there down is
-- concrete.  Those answers must be exactly what they would be if `Holder` were
-- deleted.
--
-- Why this shape rather than "rigids work": a new `Mono` constructor is silently
-- swallowed by every `_ =>` wildcard arm in every function that does not yet
-- know about it, and a fixture that exercises the new constructor passes whether
-- or not those wildcards are right — every pre-existing golden pins the output
-- the author expected.  What a swallowed rigid actually breaks is UNRELATED
-- dispatch, because `headTyconMono` is the goal-side bucket key; so the
-- discriminating assertion is an ordinary dispatch answer taken in a rigid's
-- presence.
--
-- Expected value derived by hand BEFORE running anything (AGENTS.md: a captured
-- golden records what the engine did, not what is correct):
--   tag (Bead 4)   -> "bead"    · size (Bead 4)   -> 4
--   tag (Strand 3) -> "strand"  · size (Strand 3) -> 3 * 10 = 30
--   both (Bead 4)  -> "bead" ++ "/" ++ "4"  -> "bead/4"
--   total          -> 4 + 30 = 34
--   the tuple      -> (bead, 34, bead/4, strand/30)

data Holder = Holder { slot : q }

interface Bit a where
  tag : a -> String
  size : a -> Int

data Bead = Bead Int

data Strand = Strand Int

impl Bit Bead where
  tag _ = "bead"
  size (Bead n) = n

impl Bit Strand where
  tag _ = "strand"
  size (Strand n) = n * 10

both b = tag b ++ "/" ++ intToString (size b)

total = size (Bead 4) + size (Strand 3)

main = (tag (Bead 4), total, both (Bead 4), both (Strand 3))
# CORE_IR
(CProgram ((CBind "both" (CClause ((PVar "b")) (CBinPrim "++" (CBinPrim "++" (CApp (CVar "tag" AGlobal) (CVar "b" (ALocal 0 0))) (CLit (LString "/"))) (CApp (CVar "intToString" AGlobal) (CApp (CVar "size" AGlobal) (CVar "b" (ALocal 0 0))))))) (CBind "total" (CClause () (CBinPrim "+" (CApp (CVar "size" AGlobal) (CApp (CVar "Bead" AGlobal) (CLit (LInt 4)))) (CApp (CVar "size" AGlobal) (CApp (CVar "Strand" AGlobal) (CLit (LInt 3))))))) (CBind "main" (CClause () (CTuple (CApp (CVar "tag" AGlobal) (CApp (CVar "Bead" AGlobal) (CLit (LInt 4)))) (CVar "total" AGlobal) (CApp (CVar "both" AGlobal) (CApp (CVar "Bead" AGlobal) (CLit (LInt 4)))) (CApp (CVar "both" AGlobal) (CApp (CVar "Strand" AGlobal) (CLit (LInt 3)))))))) ((ca "Holder" 1) (ca "Bead" 1) (ca "Strand" 1)) ((ct "Holder" "Holder") (ct "Bead" "Bead") (ct "Strand" "Strand")) ((CImplEntry "tag" 0 (CImplTagged "Bead" "Bit|Bead|" "Bit" (0) (PWild) (CLit (LString "bead")))) (CImplEntry "size" 0 (CImplTagged "Bead" "Bit|Bead|" "Bit" (0) ((PCon "Bead" (PVar "n"))) (CVar "n" (ALocal 0 0)))) (CImplEntry "tag" 0 (CImplTagged "Strand" "Bit|Strand|" "Bit" (0) (PWild) (CLit (LString "strand")))) (CImplEntry "size" 0 (CImplTagged "Strand" "Bit|Strand|" "Bit" (0) ((PCon "Strand" (PVar "n"))) (CBinPrim "*" (CVar "n" (ALocal 0 0)) (CLit (LInt 10)))))))
