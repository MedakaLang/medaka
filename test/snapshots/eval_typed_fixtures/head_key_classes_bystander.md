# META
source_lines=55
stages=EVAL
# SOURCE
-- BYSTANDER fixture for #1111 Stage A-2 unit A-2.2 (widen the head-tycon
-- projections so a dispatch key can carry identity).
--
-- The unit is ANSWER-PRESERVING: `headTyconMono`/`headTyconTy` return a
-- `HeadKey` instead of an `Option String`, and every consumer projects straight
-- back to the bare name.  So there is no "feature" to exercise, and per
-- AGENTS.md the required shape is the other one — the construct is present and
-- the assertion is about code that must not have moved.
--
-- Every head class the widened projection can produce is dispatched through
-- here, and the LAST line is the one that matters: `bystander` names none of
-- this machinery and must still answer 40.
--   * `Int` / `(a, b)` — a head the LANGUAGE provides (`OriginBuiltin`), which
--     A-2.2 maps to an identity-BEARING key.  The tuple arm is the one with no
--     node to read an origin off, so its answer is decided by the projection.
--   * `Box` — a USER-declared head.  This is the flat/single-file driver path,
--     where resolve stamps no module id, so A-2.2 maps it to the identity-LESS
--     key.  Both key classes must still land in the same bucket they did.
--   * the receiver inside `tagTwice` — a RIGID type variable, which
--     DICT-SEMANTICS §8 I6.1 says is not a declaration and must carry NO
--     identity.  A-2.2 deliberately does not give it one; it must keep
--     dispatching through the caller's dict exactly as before.
interface Tag a where
  tag : a -> String

data Box a = Box a

impl Tag (Box a) where
  tag b = "box"

impl Tag Int where
  tag n = "int"

impl Tag (a, b) where
  tag p = "pair"

-- The RIGID-headed dispatch path: inside this body the receiver's head is the
-- type PARAMETER `a`, so the goal-side projection answers with a rigid head and
-- the call routes through the `=>`-bound dict rather than any impl bucket.
tagTwice : Tag a => a -> String
tagTwice x = tag x ++ tag x

-- THE BYSTANDER.  It mentions no interface, no impl and no user type; nothing
-- about it goes near a head-tycon projection.  If A-2.2 moved this, the
-- widening changed an answer.
bystander : Int -> Int
bystander n = n * 3 + 1

main =
  let _ = println (tag 7)
  let _ = println (tag (Box 1))
  let _ = println (tag (1, True))
  let _ = println (tagTwice 7)
  let _ = println (tagTwice (Box 1))
  println (bystander 13)
# EVAL
int
box
pair
intint
boxbox
40
