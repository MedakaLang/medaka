# META
source_lines=106
stages=DESUGAR,MARK
# SOURCE
import support.ordmap.{OrdMap, omEmpty, omLookup, omInsert, omDelete, omSize}
import frontend.syntax_source.{syntaxSourceText, syntaxTokens}
import tools.source_snapshot.{SnapshotId(..)}
import tools.snapshot_syntax.{
  ParseOptions, PreparedSyntax, snapshotSyntaxId, snapshotSyntaxVersion,
  snapshotSyntaxSource
}

public export data SyntaxCacheLimits = SyntaxCacheLimits Int Int Int Int
data CacheEntry = CacheEntry ParseOptions PreparedSyntax Int Int
export data SyntaxCache =
  SyntaxCache SyntaxCacheLimits (OrdMap CacheEntry) (List String) Int Int

export
defaultSyntaxCacheLimits : SyntaxCacheLimits
defaultSyntaxCacheLimits = SyntaxCacheLimits 4 65536 131072 65536

export
emptySyntaxCache : SyntaxCacheLimits -> SyntaxCache
emptySyntaxCache limits = SyntaxCache limits omEmpty [] 0 0

export
lookupSyntax : SnapshotId ->
  Option Int ->
  ParseOptions ->
  SyntaxCache ->
  Option PreparedSyntax
lookupSyntax (SnapshotId uri generation) version options (SyntaxCache _ entries _ _ _) =
  do
    (CacheEntry stored prepared _ _) <- omLookup uri entries
    let (SnapshotId _ current) = snapshotSyntaxId prepared
    if generation == current
      && version == snapshotSyntaxVersion prepared
      && options == stored then
      Some prepared
    else
      None

export
invalidateSyntax : String -> SyntaxCache -> SyntaxCache
invalidateSyntax uri (cache@(SyntaxCache limits entries order source tokens)) =
  match omLookup uri entries
    None => cache
    Some (CacheEntry _ _ s t) =>
      SyntaxCache
        limits
        (omDelete uri entries)
        (filter (/= uri) order)
        (source - s)
        (tokens - t)

export
clearSyntax : SyntaxCache -> SyntaxCache
clearSyntax (SyntaxCache limits _ _ _ _) = emptySyntaxCache limits

export
syntaxCacheEntryLimit : SyntaxCache -> Int
syntaxCacheEntryLimit (SyntaxCache (SyntaxCacheLimits count _ _ _) _ _ _ _) =
  count

export
syntaxCacheSize : SyntaxCache -> Int
syntaxCacheSize (SyntaxCache _ entries _ _ _) = omSize entries

export
syntaxCacheWeight : SyntaxCache -> (Int, Int)
syntaxCacheWeight (SyntaxCache _ _ _ source tokens) = (source, tokens)

trimCache : SyntaxCache -> SyntaxCache
trimCache (cache@(SyntaxCache (SyntaxCacheLimits count _ sourceLimit tokenLimit) _ order source tokens)) =
  if syntaxCacheSize cache <= count
    && source <= sourceLimit
    && tokens <= tokenLimit then
    cache
  else match order
    [] => cache
    uri :: _ => trimCache (invalidateSyntax uri cache)

export
insertSyntax : ParseOptions -> PreparedSyntax -> SyntaxCache -> SyntaxCache
insertSyntax options prepared cache =
  let (SnapshotId uri _) = snapshotSyntaxId prepared
  let without = invalidateSyntax uri cache
  match snapshotSyntaxSource prepared
    None => without
    Some syntax =>
      let (SyntaxCache (limits@(SyntaxCacheLimits count perEntry sourceLimit tokenLimit)) entries order source tokens) =
        without
      let s = stringLength (syntaxSourceText syntax)
      let t = arrayLength (syntaxTokens syntax)
      if count <= 0
        || perEntry < 0
        || sourceLimit < 0
        || tokenLimit < 0
        || s > perEntry
        || s > sourceLimit
        || t > tokenLimit then
        without
      else
        trimCache
          (SyntaxCache
            limits
            (omInsert uri (CacheEntry options prepared s t) entries)
            (order ++ [uri])
            (source + s)
            (tokens + t))
# DESUGAR
(DUse false (UseGroup ("support" "ordmap") ((mem "OrdMap" false) (mem "omEmpty" false) (mem "omLookup" false) (mem "omInsert" false) (mem "omDelete" false) (mem "omSize" false))))
(DUse false (UseGroup ("frontend" "syntax_source") ((mem "syntaxSourceText" false) (mem "syntaxTokens" false))))
(DUse false (UseGroup ("tools" "source_snapshot") ((mem "SnapshotId" true))))
(DUse false (UseGroup ("tools" "snapshot_syntax") ((mem "ParseOptions" false) (mem "PreparedSyntax" false) (mem "snapshotSyntaxId" false) (mem "snapshotSyntaxVersion" false) (mem "snapshotSyntaxSource" false))))
(DData Public "SyntaxCacheLimits" () ((variant "SyntaxCacheLimits" (ConPos (TyCon "Int") (TyCon "Int") (TyCon "Int") (TyCon "Int")))) ())
(DData Private "CacheEntry" () ((variant "CacheEntry" (ConPos (TyCon "ParseOptions") (TyCon "PreparedSyntax") (TyCon "Int") (TyCon "Int")))) ())
(DData Abstract "SyntaxCache" () ((variant "SyntaxCache" (ConPos (TyCon "SyntaxCacheLimits") (TyApp (TyCon "OrdMap") (TyCon "CacheEntry")) (TyApp (TyCon "List") (TyCon "String")) (TyCon "Int") (TyCon "Int")))) ())
(DTypeSig true "defaultSyntaxCacheLimits" (TyCon "SyntaxCacheLimits"))
(DFunDef false "defaultSyntaxCacheLimits" () (EApp (EApp (EApp (EApp (EVar "SyntaxCacheLimits") (ELit (LInt 4))) (ELit (LInt 65536))) (ELit (LInt 131072))) (ELit (LInt 65536))))
(DTypeSig true "emptySyntaxCache" (TyFun (TyCon "SyntaxCacheLimits") (TyCon "SyntaxCache")))
(DFunDef false "emptySyntaxCache" ((PVar "limits")) (EApp (EApp (EApp (EApp (EApp (EVar "SyntaxCache") (EVar "limits")) (EVar "omEmpty")) (EListLit)) (ELit (LInt 0))) (ELit (LInt 0))))
(DTypeSig true "lookupSyntax" (TyFun (TyCon "SnapshotId") (TyFun (TyApp (TyCon "Option") (TyCon "Int")) (TyFun (TyCon "ParseOptions") (TyFun (TyCon "SyntaxCache") (TyApp (TyCon "Option") (TyCon "PreparedSyntax")))))))
(DFunDef false "lookupSyntax" ((PCon "SnapshotId" (PVar "uri") (PVar "generation")) (PVar "version") (PVar "options") (PCon "SyntaxCache" PWild (PVar "entries") PWild PWild PWild)) (EApp (EApp (EVar "andThen") (EApp (EApp (EVar "omLookup") (EVar "uri")) (EVar "entries"))) (ELam ((PVar "__do_x")) (EMatch (EVar "__do_x") (arm (PCon "CacheEntry" (PVar "stored") (PVar "prepared") PWild PWild) () (ELet false (PCon "SnapshotId" PWild (PVar "current")) (EApp (EVar "snapshotSyntaxId") (EVar "prepared")) (EIf (EBinOp "&&" (EBinOp "&&" (EBinOp "==" (EVar "generation") (EVar "current")) (EBinOp "==" (EVar "version") (EApp (EVar "snapshotSyntaxVersion") (EVar "prepared")))) (EBinOp "==" (EVar "options") (EVar "stored"))) (EApp (EVar "Some") (EVar "prepared")) (EVar "None"))))))))
(DTypeSig true "invalidateSyntax" (TyFun (TyCon "String") (TyFun (TyCon "SyntaxCache") (TyCon "SyntaxCache"))))
(DFunDef false "invalidateSyntax" ((PVar "uri") (PAs "cache" (PCon "SyntaxCache" (PVar "limits") (PVar "entries") (PVar "order") (PVar "source") (PVar "tokens")))) (EMatch (EApp (EApp (EVar "omLookup") (EVar "uri")) (EVar "entries")) (arm (PCon "None") () (EVar "cache")) (arm (PCon "Some" (PCon "CacheEntry" PWild PWild (PVar "s") (PVar "t"))) () (EApp (EApp (EApp (EApp (EApp (EVar "SyntaxCache") (EVar "limits")) (EApp (EApp (EVar "omDelete") (EVar "uri")) (EVar "entries"))) (EApp (EApp (EVar "filter") (ELam ((PVar "_s")) (EBinOp "/=" (EVar "_s") (EVar "uri")))) (EVar "order"))) (EBinOp "-" (EVar "source") (EVar "s"))) (EBinOp "-" (EVar "tokens") (EVar "t"))))))
(DTypeSig true "clearSyntax" (TyFun (TyCon "SyntaxCache") (TyCon "SyntaxCache")))
(DFunDef false "clearSyntax" ((PCon "SyntaxCache" (PVar "limits") PWild PWild PWild PWild)) (EApp (EVar "emptySyntaxCache") (EVar "limits")))
(DTypeSig true "syntaxCacheEntryLimit" (TyFun (TyCon "SyntaxCache") (TyCon "Int")))
(DFunDef false "syntaxCacheEntryLimit" ((PCon "SyntaxCache" (PCon "SyntaxCacheLimits" (PVar "count") PWild PWild PWild) PWild PWild PWild PWild)) (EVar "count"))
(DTypeSig true "syntaxCacheSize" (TyFun (TyCon "SyntaxCache") (TyCon "Int")))
(DFunDef false "syntaxCacheSize" ((PCon "SyntaxCache" PWild (PVar "entries") PWild PWild PWild)) (EApp (EVar "omSize") (EVar "entries")))
(DTypeSig true "syntaxCacheWeight" (TyFun (TyCon "SyntaxCache") (TyTuple (TyCon "Int") (TyCon "Int"))))
(DFunDef false "syntaxCacheWeight" ((PCon "SyntaxCache" PWild PWild PWild (PVar "source") (PVar "tokens"))) (ETuple (EVar "source") (EVar "tokens")))
(DTypeSig false "trimCache" (TyFun (TyCon "SyntaxCache") (TyCon "SyntaxCache")))
(DFunDef false "trimCache" ((PAs "cache" (PCon "SyntaxCache" (PCon "SyntaxCacheLimits" (PVar "count") PWild (PVar "sourceLimit") (PVar "tokenLimit")) PWild (PVar "order") (PVar "source") (PVar "tokens")))) (EIf (EBinOp "&&" (EBinOp "&&" (EBinOp "<=" (EApp (EVar "syntaxCacheSize") (EVar "cache")) (EVar "count")) (EBinOp "<=" (EVar "source") (EVar "sourceLimit"))) (EBinOp "<=" (EVar "tokens") (EVar "tokenLimit"))) (EVar "cache") (EMatch (EVar "order") (arm (PList) () (EVar "cache")) (arm (PCons (PVar "uri") PWild) () (EApp (EVar "trimCache") (EApp (EApp (EVar "invalidateSyntax") (EVar "uri")) (EVar "cache")))))))
(DTypeSig true "insertSyntax" (TyFun (TyCon "ParseOptions") (TyFun (TyCon "PreparedSyntax") (TyFun (TyCon "SyntaxCache") (TyCon "SyntaxCache")))))
(DFunDef false "insertSyntax" ((PVar "options") (PVar "prepared") (PVar "cache")) (EBlock (DoLet false false (PCon "SnapshotId" (PVar "uri") PWild) (EApp (EVar "snapshotSyntaxId") (EVar "prepared"))) (DoLet false false (PVar "without") (EApp (EApp (EVar "invalidateSyntax") (EVar "uri")) (EVar "cache"))) (DoExpr (EMatch (EApp (EVar "snapshotSyntaxSource") (EVar "prepared")) (arm (PCon "None") () (EVar "without")) (arm (PCon "Some" (PVar "syntax")) () (EBlock (DoLet false false (PCon "SyntaxCache" (PAs "limits" (PCon "SyntaxCacheLimits" (PVar "count") (PVar "perEntry") (PVar "sourceLimit") (PVar "tokenLimit"))) (PVar "entries") (PVar "order") (PVar "source") (PVar "tokens")) (EVar "without")) (DoLet false false (PVar "s") (EApp (EVar "stringLength") (EApp (EVar "syntaxSourceText") (EVar "syntax")))) (DoLet false false (PVar "t") (EApp (EVar "arrayLength") (EApp (EVar "syntaxTokens") (EVar "syntax")))) (DoExpr (EIf (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "<=" (EVar "count") (ELit (LInt 0))) (EBinOp "<" (EVar "perEntry") (ELit (LInt 0)))) (EBinOp "<" (EVar "sourceLimit") (ELit (LInt 0)))) (EBinOp "<" (EVar "tokenLimit") (ELit (LInt 0)))) (EBinOp ">" (EVar "s") (EVar "perEntry"))) (EBinOp ">" (EVar "s") (EVar "sourceLimit"))) (EBinOp ">" (EVar "t") (EVar "tokenLimit"))) (EVar "without") (EApp (EVar "trimCache") (EApp (EApp (EApp (EApp (EApp (EVar "SyntaxCache") (EVar "limits")) (EApp (EApp (EApp (EVar "omInsert") (EVar "uri")) (EApp (EApp (EApp (EApp (EVar "CacheEntry") (EVar "options")) (EVar "prepared")) (EVar "s")) (EVar "t"))) (EVar "entries"))) (EBinOp "++" (EVar "order") (EListLit (EVar "uri")))) (EBinOp "+" (EVar "source") (EVar "s"))) (EBinOp "+" (EVar "tokens") (EVar "t"))))))))))))
# MARK
(DUse false (UseGroup ("support" "ordmap") ((mem "OrdMap" false) (mem "omEmpty" false) (mem "omLookup" false) (mem "omInsert" false) (mem "omDelete" false) (mem "omSize" false))))
(DUse false (UseGroup ("frontend" "syntax_source") ((mem "syntaxSourceText" false) (mem "syntaxTokens" false))))
(DUse false (UseGroup ("tools" "source_snapshot") ((mem "SnapshotId" true))))
(DUse false (UseGroup ("tools" "snapshot_syntax") ((mem "ParseOptions" false) (mem "PreparedSyntax" false) (mem "snapshotSyntaxId" false) (mem "snapshotSyntaxVersion" false) (mem "snapshotSyntaxSource" false))))
(DData Public "SyntaxCacheLimits" () ((variant "SyntaxCacheLimits" (ConPos (TyCon "Int") (TyCon "Int") (TyCon "Int") (TyCon "Int")))) ())
(DData Private "CacheEntry" () ((variant "CacheEntry" (ConPos (TyCon "ParseOptions") (TyCon "PreparedSyntax") (TyCon "Int") (TyCon "Int")))) ())
(DData Abstract "SyntaxCache" () ((variant "SyntaxCache" (ConPos (TyCon "SyntaxCacheLimits") (TyApp (TyCon "OrdMap") (TyCon "CacheEntry")) (TyApp (TyCon "List") (TyCon "String")) (TyCon "Int") (TyCon "Int")))) ())
(DTypeSig true "defaultSyntaxCacheLimits" (TyCon "SyntaxCacheLimits"))
(DFunDef false "defaultSyntaxCacheLimits" () (EApp (EApp (EApp (EApp (EVar "SyntaxCacheLimits") (ELit (LInt 4))) (ELit (LInt 65536))) (ELit (LInt 131072))) (ELit (LInt 65536))))
(DTypeSig true "emptySyntaxCache" (TyFun (TyCon "SyntaxCacheLimits") (TyCon "SyntaxCache")))
(DFunDef false "emptySyntaxCache" ((PVar "limits")) (EApp (EApp (EApp (EApp (EApp (EVar "SyntaxCache") (EVar "limits")) (EVar "omEmpty")) (EListLit)) (ELit (LInt 0))) (ELit (LInt 0))))
(DTypeSig true "lookupSyntax" (TyFun (TyCon "SnapshotId") (TyFun (TyApp (TyCon "Option") (TyCon "Int")) (TyFun (TyCon "ParseOptions") (TyFun (TyCon "SyntaxCache") (TyApp (TyCon "Option") (TyCon "PreparedSyntax")))))))
(DFunDef false "lookupSyntax" ((PCon "SnapshotId" (PVar "uri") (PVar "generation")) (PVar "version") (PVar "options") (PCon "SyntaxCache" PWild (PVar "entries") PWild PWild PWild)) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EVar "omLookup") (EVar "uri")) (EVar "entries"))) (ELam ((PVar "__do_x")) (EMatch (EVar "__do_x") (arm (PCon "CacheEntry" (PVar "stored") (PVar "prepared") PWild PWild) () (ELet false (PCon "SnapshotId" PWild (PVar "current")) (EApp (EVar "snapshotSyntaxId") (EVar "prepared")) (EIf (EBinOp "&&" (EBinOp "&&" (EBinOp "==" (EVar "generation") (EVar "current")) (EBinOp "==" (EVar "version") (EApp (EVar "snapshotSyntaxVersion") (EVar "prepared")))) (EBinOp "==" (EVar "options") (EVar "stored"))) (EApp (EVar "Some") (EVar "prepared")) (EVar "None"))))))))
(DTypeSig true "invalidateSyntax" (TyFun (TyCon "String") (TyFun (TyCon "SyntaxCache") (TyCon "SyntaxCache"))))
(DFunDef false "invalidateSyntax" ((PVar "uri") (PAs "cache" (PCon "SyntaxCache" (PVar "limits") (PVar "entries") (PVar "order") (PVar "source") (PVar "tokens")))) (EMatch (EApp (EApp (EVar "omLookup") (EVar "uri")) (EVar "entries")) (arm (PCon "None") () (EVar "cache")) (arm (PCon "Some" (PCon "CacheEntry" PWild PWild (PVar "s") (PVar "t"))) () (EApp (EApp (EApp (EApp (EApp (EVar "SyntaxCache") (EVar "limits")) (EApp (EApp (EVar "omDelete") (EVar "uri")) (EVar "entries"))) (EApp (EApp (EMethodRef "filter") (ELam ((PVar "_s")) (EBinOp "/=" (EVar "_s") (EVar "uri")))) (EVar "order"))) (EBinOp "-" (EVar "source") (EVar "s"))) (EBinOp "-" (EVar "tokens") (EVar "t"))))))
(DTypeSig true "clearSyntax" (TyFun (TyCon "SyntaxCache") (TyCon "SyntaxCache")))
(DFunDef false "clearSyntax" ((PCon "SyntaxCache" (PVar "limits") PWild PWild PWild PWild)) (EApp (EVar "emptySyntaxCache") (EVar "limits")))
(DTypeSig true "syntaxCacheEntryLimit" (TyFun (TyCon "SyntaxCache") (TyCon "Int")))
(DFunDef false "syntaxCacheEntryLimit" ((PCon "SyntaxCache" (PCon "SyntaxCacheLimits" (PVar "count") PWild PWild PWild) PWild PWild PWild PWild)) (EDictApp "count"))
(DTypeSig true "syntaxCacheSize" (TyFun (TyCon "SyntaxCache") (TyCon "Int")))
(DFunDef false "syntaxCacheSize" ((PCon "SyntaxCache" PWild (PVar "entries") PWild PWild PWild)) (EApp (EVar "omSize") (EVar "entries")))
(DTypeSig true "syntaxCacheWeight" (TyFun (TyCon "SyntaxCache") (TyTuple (TyCon "Int") (TyCon "Int"))))
(DFunDef false "syntaxCacheWeight" ((PCon "SyntaxCache" PWild PWild PWild (PVar "source") (PVar "tokens"))) (ETuple (EVar "source") (EVar "tokens")))
(DTypeSig false "trimCache" (TyFun (TyCon "SyntaxCache") (TyCon "SyntaxCache")))
(DFunDef false "trimCache" ((PAs "cache" (PCon "SyntaxCache" (PCon "SyntaxCacheLimits" (PVar "count") PWild (PVar "sourceLimit") (PVar "tokenLimit")) PWild (PVar "order") (PVar "source") (PVar "tokens")))) (EIf (EBinOp "&&" (EBinOp "&&" (EBinOp "<=" (EApp (EVar "syntaxCacheSize") (EVar "cache")) (EDictApp "count")) (EBinOp "<=" (EVar "source") (EVar "sourceLimit"))) (EBinOp "<=" (EVar "tokens") (EVar "tokenLimit"))) (EVar "cache") (EMatch (EVar "order") (arm (PList) () (EVar "cache")) (arm (PCons (PVar "uri") PWild) () (EApp (EVar "trimCache") (EApp (EApp (EVar "invalidateSyntax") (EVar "uri")) (EVar "cache")))))))
(DTypeSig true "insertSyntax" (TyFun (TyCon "ParseOptions") (TyFun (TyCon "PreparedSyntax") (TyFun (TyCon "SyntaxCache") (TyCon "SyntaxCache")))))
(DFunDef false "insertSyntax" ((PVar "options") (PVar "prepared") (PVar "cache")) (EBlock (DoLet false false (PCon "SnapshotId" (PVar "uri") PWild) (EApp (EVar "snapshotSyntaxId") (EVar "prepared"))) (DoLet false false (PVar "without") (EApp (EApp (EVar "invalidateSyntax") (EVar "uri")) (EVar "cache"))) (DoExpr (EMatch (EApp (EVar "snapshotSyntaxSource") (EVar "prepared")) (arm (PCon "None") () (EVar "without")) (arm (PCon "Some" (PVar "syntax")) () (EBlock (DoLet false false (PCon "SyntaxCache" (PAs "limits" (PCon "SyntaxCacheLimits" (PVar "count") (PVar "perEntry") (PVar "sourceLimit") (PVar "tokenLimit"))) (PVar "entries") (PVar "order") (PVar "source") (PVar "tokens")) (EVar "without")) (DoLet false false (PVar "s") (EApp (EVar "stringLength") (EApp (EVar "syntaxSourceText") (EVar "syntax")))) (DoLet false false (PVar "t") (EApp (EVar "arrayLength") (EApp (EVar "syntaxTokens") (EVar "syntax")))) (DoExpr (EIf (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "<=" (EDictApp "count") (ELit (LInt 0))) (EBinOp "<" (EVar "perEntry") (ELit (LInt 0)))) (EBinOp "<" (EVar "sourceLimit") (ELit (LInt 0)))) (EBinOp "<" (EVar "tokenLimit") (ELit (LInt 0)))) (EBinOp ">" (EVar "s") (EVar "perEntry"))) (EBinOp ">" (EVar "s") (EVar "sourceLimit"))) (EBinOp ">" (EVar "t") (EVar "tokenLimit"))) (EVar "without") (EApp (EVar "trimCache") (EApp (EApp (EApp (EApp (EApp (EVar "SyntaxCache") (EVar "limits")) (EApp (EApp (EApp (EVar "omInsert") (EVar "uri")) (EApp (EApp (EApp (EApp (EVar "CacheEntry") (EVar "options")) (EVar "prepared")) (EVar "s")) (EVar "t"))) (EVar "entries"))) (EBinOp "++" (EVar "order") (EListLit (EVar "uri")))) (EBinOp "+" (EVar "source") (EVar "s"))) (EBinOp "+" (EVar "tokens") (EVar "t"))))))))))))
