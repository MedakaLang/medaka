# META
source_lines=12
stages=TYPES
# SOURCE
-- polymorphic combinators: pure HM inference, no prelude
id x = x
const x y = x
apply f x = f x
compose f g x = f (g x)
flip f x y = f y x
pair x y = (x, y)
fst3 (a, b) = a
snd3 (a, b) = b
swapT (a, b) = (b, a)
twice f x = f (f x)
on f g x y = f (g x) (g y)
# TYPES
id : a -> a
const : a -> b -> a
apply : (a -> <b> c) -> a -> <b> c
compose : (a -> <b> c) -> (d -> <e> a) -> d -> <e | b> c
flip : (a -> <b> c -> <d> e) -> c -> a -> <b | d> e
pair : a -> b -> (a, b)
fst3 : (a, b) -> a
snd3 : (a, b) -> b
swapT : (a, b) -> (b, a)
twice : (a -> <b> a) -> a -> <b> a
on : (a -> <b> a -> <c> d) -> (e -> <f> a) -> e -> e -> <f | b | c> d
