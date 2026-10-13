; Hand-written contract only: the Medaka emitter does not generate these roots.
%Root = type { ptr, ptr }

declare i64 @allocate(i64, i64)
declare void @root_push(ptr, ptr)
declare void @root_pop(ptr)
declare void @minor_collect()

define i64 @contract_reload() noinline sanitize_address {
entry:
  %slot = alloca i64, align 8
  %root = alloca %Root, align 8
  store i64 1, ptr %slot, align 8
  call void @root_push(ptr %root, ptr %slot)
  %before = call i64 @allocate(i64 2, i64 2)
  %object = inttoptr i64 %before to ptr
  store i64 17, ptr %object, align 8
  %field = getelementptr i64, ptr %object, i64 1
  store i64 275, ptr %field, align 8
  store i64 %before, ptr %slot, align 8
  call void @minor_collect()
  %live = load i64, ptr %slot, align 8 ; mutation: omit relocated reload
  %moved = icmp ne i64 %live, %before
  %relocated = inttoptr i64 %live to ptr
  %relocated.field = getelementptr i64, ptr %relocated, i64 1
  %payload = load i64, ptr %relocated.field, align 8
  %correct = icmp eq i64 %payload, 275
  %valid = and i1 %moved, %correct
  call void @root_pop(ptr %root)
  %result = select i1 %valid, i64 0, i64 1
  ret i64 %result
}

; The helper allocates while its caller's earlier argument remains rooted.
define internal i64 @contract_later_argument() noinline sanitize_address {
entry:
  %slot = alloca i64, align 8
  %root = alloca %Root, align 8
  store i64 1, ptr %slot, align 8
  call void @root_push(ptr %root, ptr %slot)
  %word = call i64 @allocate(i64 2, i64 2)
  %object = inttoptr i64 %word to ptr
  store i64 17, ptr %object, align 8
  %field = getelementptr i64, ptr %object, i64 1
  store i64 87, ptr %field, align 8
  store i64 %word, ptr %slot, align 8
  call void @minor_collect()
  %live = load i64, ptr %slot, align 8
  call void @root_pop(ptr %root)
  ret i64 %live
}

define internal i64 @contract_sum(i64 %left, i64 %right) noinline sanitize_address {
entry:
  %lp = inttoptr i64 %left to ptr
  %rp = inttoptr i64 %right to ptr
  %lf = getelementptr i64, ptr %lp, i64 1
  %rf = getelementptr i64, ptr %rp, i64 1
  %lv = load i64, ptr %lf, align 8
  %rv = load i64, ptr %rf, align 8
  %lu = lshr i64 %lv, 1
  %ru = lshr i64 %rv, 1
  %sum = add i64 %lu, %ru
  ret i64 %sum
}

define i64 @contract_arguments() noinline sanitize_address {
entry:
  %slot = alloca i64, align 8
  %root = alloca %Root, align 8
  store i64 1, ptr %slot, align 8
  call void @root_push(ptr %root, ptr %slot)
  %early = call i64 @allocate(i64 2, i64 2)
  %object = inttoptr i64 %early to ptr
  store i64 17, ptr %object, align 8
  %field = getelementptr i64, ptr %object, i64 1
  store i64 43, ptr %field, align 8
  store i64 %early, ptr %slot, align 8
  %later = call i64 @contract_later_argument()
  %live = load i64, ptr %slot, align 8 ; mutation: omit earlier argument reload
  %sum = call i64 @contract_sum(i64 %live, i64 %later)
  call void @root_pop(ptr %root)
  %valid = icmp eq i64 %sum, 64
  %result = select i1 %valid, i64 0, i64 2
  ret i64 %result
}

; Pop the caller's frame only after allocating argument work and reloading.
; The callee publishes its incoming argument before any allocation/safepoint.
define i64 @contract_tail(i64 %incoming, i64 %remaining) noinline sanitize_address {
entry:
  %slot = alloca i64, align 8
  %root = alloca %Root, align 8
  store i64 %incoming, ptr %slot, align 8
  call void @root_push(ptr %root, ptr %slot)
  %done = icmp eq i64 %remaining, 0
  br i1 %done, label %finish, label %again
finish:
  call void @minor_collect()
  %final = load i64, ptr %slot, align 8
  call void @root_pop(ptr %root)
  ret i64 %final
again:
  %garbage = call i64 @allocate(i64 1, i64 0)
  %gp = inttoptr i64 %garbage to ptr
  store i64 1, ptr %gp, align 8
  call void @minor_collect()
  %live = load i64, ptr %slot, align 8
  %next = sub i64 %remaining, 1
  call void @root_pop(ptr %root)
  %result = musttail call i64 @contract_tail(i64 %live, i64 %next)
  ret i64 %result
}
