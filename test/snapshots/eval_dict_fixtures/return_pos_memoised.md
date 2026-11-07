# META
source_lines=25
stages=EVAL
# SOURCE
-- A point-free (nullary) RETURN-POSITION impl method (`theUnit : a`, no
-- discriminating argument) is evaluated at each occurrence as a function of its
-- dictionary (I6 for impl methods), never memoised.  Referenced twice at the same
-- concrete type, the body's effect (`[eval]`) runs twice, so the program prints
-- `[eval] [eval] XX`.
interface HasUnit a where
  theUnit : a

data Box = Box String

impl HasUnit Box where
  theUnit =
    let _ = putStr "[eval] "
    Box "X"

unBox : Box -> String
unBox (Box s) = s

label : Box -> String
label _ =
  let a = unBox (theUnit : Box)
  let b = unBox (theUnit : Box)
  a ++ b

main = putStrLn (label (Box "ignored"))
# EVAL
[eval] [eval] XX
