"""Independent rejection witnesses for the closed generated-code experiment."""

from transform import Rejected, transform


def check_rejections(raw, contract, make_name, first_name):
    transform(raw, contract)

    def change(old, new):
        if raw.count(old) != 1:
            raise RuntimeError("independent rejection anchor changed: " + old)
        return raw.replace(old, new)

    finish = "  %t2 = ptrtoint ptr %t0 to i64\n  ret i64 %t2"
    field_load = "  %t2 = load i64, ptr %t1\n  ret i64 %t2"
    call = "@" + first_name + "(i64 %t0, i64 %t1)"
    witnesses = {
        "finished_constructor_recursion": (change(finish,
            "  %t2 = ptrtoint ptr %t0 to i64\n  %t99 = call i64 @" + make_name
            + "(i64 %arg0)\n  ret i64 %t2"), "recursion is outside straight-line experiment"),
        "indirect_call": (change(call, "%t0(i64 %t0, i64 %t1)"),
                          "unsupported instruction"),
        "atomic_alloc": (change("%t0 = call ptr @mdk_alloc(i64 16)",
            "%t0 = call ptr @mdk_alloc_atomic(i64 16)"), "unsupported instruction"),
        "mutation_after_constructor": (change(finish,
            "  %t2 = ptrtoint ptr %t0 to i64\n  store i64 3, ptr %t1\n  ret i64 %t2"),
            "unsupported instruction"),
        "unknown_constructor_tag": (change("  store i64 0, ptr %t0",
            "  store i64 42, ptr %t0"), "unknown constructor header"),
        "raw_integer_field": (change("  store i64 %arg0, ptr %t1",
            "  store i64 42, ptr %t1"), "constant is not a tagged Int"),
        "wrong_call_semantics": (change(call,
            "@" + first_name + "(i64 43, i64 %t1)"), "call argument type"),
        "wrong_return_semantics": (change(finish,
            "  %t2 = ptrtoint ptr %t0 to i64\n  ret i64 %arg0"), "return semantic type"),
        "raw_field_pointer_cross_call": (change(field_load,
            "  %t99 = call i64 @" + make_name + "(i64 3)\n" + field_load),
            "raw heap pointer lives across call: %t1"),
        "extra_unreachable_function": (raw
            + "\ndefine i64 @dead() {\nentry:\n  ret i64 3\n}\n",
            "extra or missing function contract"),
        "phi_instruction": (change(finish,
            "  %t2 = ptrtoint ptr %t0 to i64\n  %t99 = phi i64 [ 3, %entry ]\n  ret i64 %t2"),
            "unsupported instruction"),
    }
    results = []
    for name, (source, reason) in witnesses.items():
        try:
            transform(source, contract)
        except Rejected as error:
            if reason not in str(error):
                raise RuntimeError(f"{name}: wrong independent rejection: {error}") from error
            results.append({"rejection": name, "reason": str(error), "independent": True})
        else:
            raise RuntimeError("invalid IR unexpectedly accepted: " + name)
    return results
