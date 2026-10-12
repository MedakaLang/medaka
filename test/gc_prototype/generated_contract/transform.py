"""Closed straight-line LLVM experiment, checked against trusted fixture contracts.

This is not a general LLVM parser or a verifier for arbitrary Medaka programs.
Every semantic type comes from the independently authored fixture contract.
"""

import re


class Rejected(ValueError):
    pass


REG = r"%[A-Za-z_][A-Za-z_0-9]*"
WORD = rf"(?:{REG}|-?[0-9]+)"
SYMBOL = r"[A-Za-z_][A-Za-z_0-9]*"
HEADER = re.compile(rf"define (i32|i64) @({SYMBOL})\((.*?)\) \{{")


def need(condition, reason):
    if not condition:
        raise Rejected(reason)


def parse_module(source):
    functions = {}
    current = None
    for line in source.splitlines():
        line = line.strip()
        if not line or line.startswith(";"):
            continue
        if current is None:
            if line.startswith("declare "):
                continue  # Declarations are discarded, never linked implicitly.
            if line == "@mdk_disc_none = private unnamed_addr constant i64 -1":
                continue  # No instruction may reference this unused sentinel.
            match = HEADER.fullmatch(line)
            need(match, "unsupported module item (globals/aliases/definitions): " + line)
            result, name, parameters = match.groups()
            need(name not in functions, "duplicate function " + name)
            current = (result, name, parameters, [])
        elif line == "}":
            result, name, parameters, body = current
            need(body and body[0] == "entry:", "missing entry block: " + name)
            functions[name] = (result, parameters, body[1:])
            current = None
        else:
            current[3].append(line)
    need(current is None, "unclosed function")
    return functions


def transform(source, contract, mutation=None):
    functions = parse_module(source)
    signatures = contract["functions"]
    records = contract["records"]
    need(set(functions) == set(signatures) | {"mdk_program_main"},
         "extra or missing function contract")
    by_tag = {}
    for name, record in records.items():
        need(name != "Int" and record["tag"] not in by_tag, "duplicate record tag")
        need(1 <= len(record["fields"]) <= 63, "unsupported record arity")
        need(all(t == "Int" or t in records for t in record["fields"]),
             "unknown record field type")
        by_tag[record["tag"]] = name
    referenced_records = set()
    edges = {name: set() for name in functions}
    generated = ["%Root = type { ptr, ptr }",
                 "declare ptr @gc_allocate(i64, i64)",
                 "declare void @gc_push(ptr, ptr)",
                 "declare void @gc_pop(ptr)",
                 "declare void @mdk_set_args(i32, ptr)",
                 "declare void @mdk_print_int(i64)"]
    mutation_sites = 0

    for name, (result, parameters, body) in functions.items():
        entry = name == "mdk_program_main"
        signature = {"args": [], "result": "Int"} if entry else signatures[name]
        types = {}
        pointers = {}
        definitions = set()
        slots = []
        emitted = []
        serial = 0
        returned = False
        prints = 0
        setup = 0
        raw_print = None

        def define(register):
            need(re.fullmatch(r"%(?:t|arg)[0-9]+", register), "unsupported register " + register)
            need(register not in definitions, "duplicate SSA definition " + register)
            definitions.add(register)

        def register_word(register, kind, field=False):
            nonlocal mutation_sites
            define(register)
            need(kind == "Int" or kind in records, "unknown semantic type " + kind)
            types[register] = kind
            slots.append((register, field))
            emitted.append(f"  store i64 {register}, ptr %gc_slot_{register[1:]}")
            if field and mutation == "drop_field_root" and kind in records:
                mutation_sites += 1

        def word_type(word):
            if word.startswith("%"):
                need(word in types, "operand lacks tagged semantic provenance: " + word)
                return types[word]
            need(re.fullmatch(r"-?[0-9]+", word), "unsupported constant operand " + word)
            number = int(word)
            need(-(1 << 63) <= number < (1 << 63) and number & 1,
                 "constant is not a tagged Int: " + word)
            return "Int"

        def use(word, stale=False):
            nonlocal serial, mutation_sites
            word_type(word)
            if not word.startswith("%"):
                return word
            if stale:
                mutation_sites += 1
                return word
            serial += 1
            fresh = f"%gc_reload_{serial}"
            emitted.append(f"  {fresh} = load i64, ptr %gc_slot_{word[1:]}")
            return fresh

        def check_pointer_liveness(position):
            future = "\n".join(body[position + 1:])
            for pointer in pointers:
                need(not re.search(re.escape(pointer) + r"(?![A-Za-z_0-9])", future),
                     "raw heap pointer lives across call: " + pointer)

        if entry:
            need(result == "i32" and parameters == "i32 %argc, ptr %argv", "entry ABI")
        else:
            need(result == "i64", "non-tagged function ABI")
            pieces = parameters.split(", ") if parameters else []
            need(len(pieces) == len(signature["args"]), "parameter arity contract")
            for index, (piece, kind) in enumerate(zip(pieces, signature["args"])):
                need(piece == f"i64 %arg{index}", "parameter ABI contract")
                register_word(f"%arg{index}", kind)
        position = 0
        while position < len(body):
            line = body[position]
            need(not returned, "instruction after return")
            allocation = re.fullmatch(rf"({REG}) = call ptr @mdk_alloc\(i64 ([0-9]+)\)", line)
            if allocation:
                check_pointer_liveness(position)
                pointer, size = allocation.groups()
                words = int(size) // 8
                need(int(size) % 8 == 0 and 2 <= words <= 64, "allocation size")
                end = position + 2 * words
                need(end <= len(body), "incomplete constructor region")
                header = re.fullmatch(rf"store i64 ([0-9]+), ptr {re.escape(pointer)}", body[position + 1])
                need(header and int(header[1]) in by_tag, "unknown constructor header")
                kind = by_tag[int(header[1])]
                referenced_records.add(kind)
                fields = records[kind]["fields"]
                need(len(fields) + 1 == words, "constructor size/schema disagreement")
                define(pointer)
                pointers[pointer] = (kind, 0)
                emitted.append(f"  {pointer} = call ptr @gc_allocate(i64 {words}, i64 {(1 << words) - 2})")
                emitted.append("  " + body[position + 1])
                for index, expected in enumerate(fields, 1):
                    gep = re.fullmatch(rf"({REG}) = getelementptr i8, ptr {re.escape(pointer)}, i64 {8 * index}", body[position + 2 * index])
                    need(gep, "constructor field address/order")
                    field_pointer = gep[1]
                    define(field_pointer)
                    pointers[field_pointer] = (kind, index)
                    store = re.fullmatch(rf"store i64 ({WORD}), ptr {re.escape(field_pointer)}", body[position + 2 * index + 1])
                    need(store and word_type(store[1]) == expected, "constructor field type")
                    emitted.append("  " + body[position + 2 * index])
                    emitted.append(f"  store i64 {use(store[1])}, ptr {field_pointer}")
                conversion = re.fullmatch(rf"({REG}) = ptrtoint ptr {re.escape(pointer)} to i64", body[end]) if end < len(body) else None
                need(conversion, "constructor does not finish as tagged base")
                emitted.append("  " + body[end])
                register_word(conversion[1], kind)
                position = end + 1
                continue
            match = re.fullmatch(rf"({REG}) = call i64 @({SYMBOL})\((.*?)\)", line)
            if match:
                register, callee, operands = match.groups()
                need(callee in signatures, "unsupported runtime/indirect call: " + callee)
                check_pointer_liveness(position)
                edges[name].add(callee)
                pieces = operands.split(", ") if operands else []
                args = []
                need(len(pieces) == len(signatures[callee]["args"]), "call arity")
                for piece, expected in zip(pieces, signatures[callee]["args"]):
                    arg = re.fullmatch(rf"i64 ({WORD})", piece)
                    need(arg and word_type(arg[1]) == expected, "call argument type")
                    args.append("i64 " + use(arg[1], mutation == "stale_argument" and entry and expected in records))
                emitted.append(f"  {register} = call i64 @{callee}({', '.join(args)})")
                register_word(register, signatures[callee]["result"])
            elif (match := re.fullmatch(rf"({REG}) = inttoptr i64 ({WORD}) to ptr", line)):
                register, word = match.groups()
                kind = word_type(word)
                need(kind in records, "inttoptr lacks record provenance")
                define(register)
                pointers[register] = (kind, 0)
                emitted.append(f"  {register} = inttoptr i64 {use(word)} to ptr")
            elif (match := re.fullmatch(rf"({REG}) = getelementptr i8, ptr ({REG}), i64 ([0-9]+)", line)):
                register, pointer, offset = match.groups()
                need(pointer in pointers and pointers[pointer][1] == 0, "GEP lacks base provenance")
                kind = pointers[pointer][0]
                index = int(offset) // 8
                need(int(offset) % 8 == 0 and 1 <= index <= len(records[kind]["fields"]), "field offset outside record schema")
                define(register)
                pointers[register] = (kind, index)
                emitted.append("  " + line)
            elif (match := re.fullmatch(rf"({REG}) = load i64, ptr ({REG})", line)):
                register, pointer = match.groups()
                need(pointer in pointers and pointers[pointer][1] > 0, "load lacks field provenance")
                kind, index = pointers[pointer]
                emitted.append("  " + line)
                register_word(register, records[kind]["fields"][index - 1], field=True)
            elif entry and line == "call void @mdk_set_args(i32 %argc, ptr %argv)":
                need(position == 0, "startup must precede expression work")
                setup += 1
                emitted.append("  " + line)
            elif entry and (match := re.fullmatch(rf"({REG}) = ashr i64 ({WORD}), 1", line)):
                register, word = match.groups()
                need(word_type(word) == "Int" and raw_print is None, "print untag requires Int")
                define(register)
                raw_print = register
                emitted.append(f"  {register} = ashr i64 {use(word)}, 1")
            elif entry and (match := re.fullmatch(rf"call void @mdk_print_int\(i64 ({REG})\)", line)):
                need(match[1] == raw_print and position == len(body) - 2, "print must consume terminal raw Int")
                prints += 1
                emitted.append("  " + line)
            elif (match := re.fullmatch(rf"ret (i32|i64) ({WORD})", line)):
                need(position == len(body) - 1, "return must be terminal")
                need(match[1] == result, "return ABI")
                operand = match[2]
                if entry:
                    need(operand == "0" and setup == 1 and prints == 1, "entry result/printing")
                else:
                    need(word_type(operand) == signature["result"], "return semantic type")
                    operand = use(operand)
                for register, field in reversed(slots):
                    if not (mutation == "drop_field_root" and field and types[register] in records):
                        emitted.append(f"  call void @gc_pop(ptr %gc_root_{register[1:]})")
                emitted.append(f"  ret {result} {operand}")
                returned = True
            else:
                raise Rejected("unsupported instruction: " + line)
            position += 1
        need(returned, "function without terminal return")
        prologue = []
        for register, field in slots:
            stem = register[1:]
            prologue += [f"  %gc_slot_{stem} = alloca i64, align 8",
                         f"  %gc_root_{stem} = alloca %Root, align 8",
                         f"  store i64 1, ptr %gc_slot_{stem}"]
            if not (mutation == "drop_field_root" and field and types[register] in records):
                prologue.append(f"  call void @gc_push(ptr %gc_root_{stem}, ptr %gc_slot_{stem})")
        generated += [f"define {result} @{name}({parameters}) sanitize_address {{", "entry:",
                      *prologue, *emitted, "}"]

    visited = set()
    active = set()

    def visit(name):
        need(name not in active, "recursion is outside straight-line experiment")
        if name not in visited:
            active.add(name)
            for callee in edges[name]:
                visit(callee)
            active.remove(name)
            visited.add(name)

    for name in edges:
        visit(name)
    need(referenced_records == set(records), "extra or missing record contract")
    need(mutation is None or mutation_sites > 0, "mutation did not exercise a site")
    return "\n".join(generated) + "\n"
