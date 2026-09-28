#!/usr/bin/env python3
"""Render pds/test/vectors/lexicon_schemas.json as the Medaka data module
pds/lib/lexicon_schemas.mdk (unformatted; gen_lexicon_schemas.sh formats it).

Every key the JSON uses must be one this script knows how to carry: an
unknown key, type or format fails the run rather than being dropped, so the
module can never say less than the JSON does.
"""
import json
import sys

FORMATS = {
    "at-identifier": "FormatAtIdentifier",
    "at-uri": "FormatAtUri",
    "cid": "FormatCid",
    "datetime": "FormatDatetime",
    "did": "FormatDid",
    "handle": "FormatHandle",
    "language": "FormatLanguage",
    "nsid": "FormatNsid",
    "record-key": "FormatRecordKey",
    "tid": "FormatTid",
    "uri": "FormatUri",
}

KEYS = {
    "record": {"type", "key", "record"},
    "object": {"type", "required", "properties"},
    "string": {"type", "minLength", "maxLength", "maxGraphemes", "format", "default"},
    "integer": {"type", "minimum"},
    "boolean": {"type"},
    "bytes": {"type"},
    "blob": {"type", "accept", "maxSize"},
    "array": {"type", "items", "maxLength"},
    "ref": {"type", "ref"},
    "union": {"type", "refs", "closed"},
}


def fail(message):
    sys.exit(f"gen_lexicon_schemas: {message}")


def text(value):
    # json.dumps spells `"` and `\` as Medaka does, but a control character
    # as an escape Medaka lacks.
    if any(ord(c) < 0x20 for c in value):
        fail(f"a control character in {value!r}")
    return json.dumps(value, ensure_ascii=False)


def option(value, render):
    return "None" if value is None else f"(Some {render(value)})"


def number(value):
    if not isinstance(value, int) or isinstance(value, bool):
        fail(f"expected an integer, got {value!r}")
    return str(value) if value >= 0 else f"({value})"


def strings(values):
    return "[" + ", ".join(text(v) for v in values) + "]"


def checked(schema, where):
    kind = schema.get("type")
    if kind not in KEYS:
        fail(f"{where}: unknown type {kind!r}")
    extra = set(schema) - KEYS[kind]
    if extra:
        fail(f"{where}: unknown keys {sorted(extra)}")
    return kind


def shape(schema, where):
    if checked(schema, where) != "object":
        fail(f"{where}: expected an object")
    props = schema["properties"]
    for name in schema["required"]:
        if name not in props:
            fail(f"{where}: required {name!r} is not a property")
    fields = ", ".join(
        f"({text(name)}, {lex_type(value, f'{where}.{name}')})"
        for name, value in props.items()
    )
    return f"(LexShape {strings(schema['required'])} [{fields}])"


def lex_type(schema, where):
    kind = checked(schema, where)
    if kind == "boolean":
        return "LexBoolean"
    if kind == "bytes":
        return "LexBytes"
    if kind == "integer":
        return f"(LexInteger {option(schema.get('minimum'), number)})"
    if kind == "string":
        fmt = schema.get("format")
        if fmt is not None and fmt not in FORMATS:
            fail(f"{where}: unknown format {fmt!r}")
        return (
            "(LexText (LexString { "
            f"minLength = {option(schema.get('minLength'), number)}, "
            f"maxLength = {option(schema.get('maxLength'), number)}, "
            f"maxGraphemes = {option(schema.get('maxGraphemes'), number)}, "
            f"format = {option(fmt, lambda f: FORMATS[f])}, "
            f"defaultValue = {option(schema.get('default'), text)} "
            "}))"
        )
    if kind == "blob":
        return (
            f"(LexBlob {option(schema.get('accept'), strings)} "
            f"{option(schema.get('maxSize'), number)})"
        )
    if kind == "array":
        return (
            f"(LexArray {lex_type(schema['items'], where + '[]')} "
            f"{option(schema.get('maxLength'), number)})"
        )
    if kind == "ref":
        return f"(LexRef {text(schema['ref'])})"
    if kind == "union":
        closed = "True" if schema["closed"] else "False"
        return f"(LexUnion {strings(schema['refs'])} {closed})"
    if kind == "object":
        return f"(LexObject {shape(schema, where)})"
    fail(f"{where}: a {kind} is not a field type")


def record_key(key, where):
    if key in ("any", "nsid", "tid"):
        return {"any": "KeyAny", "nsid": "KeyNsid", "tid": "KeyTid"}[key]
    if key.startswith("literal:") and len(key) > 8:
        return f"(KeyLiteral {text(key[8:])})"
    fail(f"{where}: unknown record key {key!r}")


def definition(name, schema):
    if checked(schema, name) == "record":
        return f"LexRecordDef {record_key(schema['key'], name)} {shape(schema['record'], name)}"
    return f"LexTypeDef {lex_type(schema, name)}"


HEADER = """{- | The Lexicon definitions this server validates record writes against:
   the twenty record collections of the reference PDS's `knownSchemas` and
   every definition they reach, keyed `nsid#name`.

   Generated from `pds/test/vectors/lexicon_schemas.json` by
   `pds/tools/gen_lexicon_schemas.sh`; regenerate rather than edit.
   `pds/test/lexicon_schemas_test.mdk` holds this module equal to that
   file. -}

import lib.lexicon.{
  LexDef(..),
  LexFormat(..),
  LexKey(..),
  LexShape(..),
  LexString(..),
  LexType(..),
  Lexicons,
  lexicons,
}

-- | The definitions, in the JSON file's order.
export
lexiconDefs : List (String, LexDef)
lexiconDefs = [
"""

FOOTER = """]

-- | `lexiconDefs`, indexed.
export
knownLexicons : Lexicons
knownLexicons = lexicons lexiconDefs
"""


def main():
    if len(sys.argv) != 3:
        sys.exit("usage: gen_lexicon_schemas.py <lexicon_schemas.json> <out.mdk>")
    with open(sys.argv[1], encoding="utf-8") as f:
        schemas = json.load(f)
    rows = "".join(
        f"  ({text(name)}, {definition(name, schema)}),\n"
        for name, schema in schemas.items()
    )
    with open(sys.argv[2], "w", encoding="utf-8") as f:
        f.write(HEADER + rows + FOOTER)


main()
