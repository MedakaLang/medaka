"""The rubric classes and their Haiku prompts.

The rule text is parsed from docs/design/STYLE-RUBRIC.md at run time, so a
prompt is always the class's current rubric row. What lives here is only what
the rubric cannot say: one narrow subject phrase per class, which Medaka notes
the judge needs, and whether the class needs reasoning across two snippets.

Every class in the rubric must have an entry in SUBJECTS; `bench.py questions
--check` fails otherwise.
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
RUBRIC_MD = ROOT / "docs" / "design" / "STYLE-RUBRIC.md"

# ---------------------------------------------------------------------------
# Medaka facts the judges need.
# ---------------------------------------------------------------------------
CORE_NOTES = (
    "Medaka is a strict, pure-by-default functional language with Haskell-like "
    "syntax and layout. `f : A -> B` is a signature; `f x = ...` a clause; "
    "`match e` is followed by indented `Pattern => body` arms; `_ =>` is a "
    "wildcard arm. `Option a = Some a | None` and `Result e a = Ok a | Err e`; "
    "`do` blocks sequence them (`x <- e` short-circuits on None/Err). "
    "`x |> f` is reverse application. Records are `{ f = v }` and updated with "
    "`{ r | f = v }`. `data` declares a sum type; `interface`/`impl` are type "
    "classes (`Eq`, `Ord`, `Display`, `Debug`, `Hashable`), and `deriving` "
    "generates impls. `--` starts a line comment, `{- | ... -}` is a doc "
    "comment, `-- lint-disable-next-line <rule> <reason>` suppresses one lint "
    "finding. `let _ = e` discards a value. The stdlib has `List`, `Array`, "
    "`Vector`, `Map`, `HashMap`, `Set`, and the usual `map`/`filter`/`any`/"
    "`all`/`find`/`count`/`elem`/`fold`/`foldRight`/`optionOr`/`orElse`/`mapErr`/`toResult`. "
    "Strings interpolate with `\"\\{e}\"`; triple-quoted strings are multi-line."
)

TEST_NOTES = (
    "Medaka tests live in `foo_test.mdk` siblings as `test \"name\" = ...` "
    "blocks or `prop` laws returning an `Expectation`, graded by `expectEqual`, "
    "`expectTrue`/`expectFalse`, `expectAll`, `expectAtLeast`, "
    "`expectSatisfies`, `expectErrContains` and similar. Doctests are `>>>` "
    "examples inside doc comments and serve as documentation. Shell gates "
    "(`test/*.sh`) carry a `shell-because:` header naming why they cannot be "
    "native tests."
)

STDLIB_DOC_NOTES = (
    "A stdlib doc comment (`{- | ... -}` in `stdlib/*.mdk`) documents the API "
    "for callers: a first sentence that stands alone, one or two examples, no "
    "history, issue numbers, implementation notes or maintainer warnings. A "
    "cost contract a caller relies on (\"O(1) average lookup\") is API, not "
    "implementation narration."
)

MONAD_NOTES = (
    "`Option a = Some a | None` and `Result e a = Ok a | Err e` are monads: "
    "`andThen : m a -> (a -> m b) -> m b` and `pure`. `do` is sugar over "
    "`andThen`/`pure`: a line `x <- e` binds the success payload of `e` and "
    "short-circuits on `None`/`Err`; `let x = e` is a pure binding; the last line "
    "is the result. So\n"
    "  match step1 x\n"
    "    Err e => Err e\n"
    "    Ok a => match step2 a\n"
    "      Err e => Err e\n"
    "      Ok b => step3 b\n"
    "is exactly\n"
    "  do\n"
    "    a <- step1 x\n"
    "    b <- step2 a\n"
    "    step3 b\n"
    "Failure arms that differ still sequence: each check becomes a named step "
    "whose failure is an error constructor, and the steps go in one `do`. "
    "`toResult err opt` turns an `Option` into a `Result`, so a chain mixing "
    "the two also fits one `do`. `orElse` (from `Alternative`) expresses a "
    "fallback staircase (`None => match ...`); it is strict in its second "
    "argument. Effectful steps are fine inside `do`."
)

COMMENT_POLICY = (
    "A source comment should state a constraint or fact that the code itself "
    "cannot show. History (what the code used to be, when or why it changed, "
    "which issue or pull request decided it) and litigation of a decision "
    "belong on the issue tracker or in a design document, not in the source, "
    "because they stop being true or useful once the change lands. Prose that "
    "argues against a wrong reading, or defends a choice, is NOT in that class: "
    "it is stating a constraint the code cannot show, which is what a comment is "
    "for."
)

NOTES = {
    "core": CORE_NOTES,
    "comments": COMMENT_POLICY + " The keep/cut test is per sentence, not per "
                "comment, and never a length rule.",
    "monads": MONAD_NOTES,
    "tests": TEST_NOTES,
    "stdlib_doc": STDLIB_DOC_NOTES,
}

# ---------------------------------------------------------------------------
# Per class: a subject phrase, extra notes, cross-snippet.
# The subject names the thing; the rubric row carries the rule
# and its exceptions. Write subjects from the rule, never from fixture items.
# ---------------------------------------------------------------------------
C = "comments"
M = "monads"
T = "tests"
SUBJECTS: dict[str, tuple[str, tuple[str, ...], bool]] = {
    # class: (subject phrase, extra note keys, cross_snippet)
    "data.sentinel": ("an in-band value (such as an empty string, -1 or 0) standing for absence or failure", (), False),
    "data.bool-blind": ("two or more adjacent Bool parameters, or a bare True/False literal passed at a call site", (), False),
    "data.stringly-error": ("a `Result String` whose error string crosses a module boundary, distinguishes failure kinds, has context concatenated onto it, or is inspected by content", (M,), False),
    "data.clone-type": ("a two-case data type that is a clone of Option or Result", (), False),
    "data.param-clump": ("the same three or more parameters travelling together through two or more functions, or three or more adjacent parameters of one primitive type", (), False),
    "data.tuple-as-record": ("a tuple of three or more fields used as a record across two or more signatures", (), False),
    "data.string-enum": ("a String compared against literals to choose behaviour outside the function that parses it (two or more distinct literals, or one literal tested in more than one place)", (), False),
    "data.string-key": ("a composite identity built by joining fields into a String inside the program", (), False),
    "data.container": ("a container misuse: keyed lookup or membership on a growing List, positional indexing into a list, `acc ++ [x]` in a recursion, or HashMap order reaching output", (), False),
    "iface.underused": ("a hand-written function duplicating what `deriving` or a standard interface (Eq, Ord, Display, Debug) provides, or a family of same-shaped functions over distinct types with no shared interface", (), False),
    "shape.do-cascade": ("a match on Option/Result with a pass-through failure arm, or a fallback staircase that `do` or `orElse` expresses", (M,), False),
    "shape.nested-match": ("deeply nested matches whose arms are 'check, then refuse or continue'", (M,), False),
    "shape.threaded-invariants": ("two or more arguments passed unchanged through every recursive call", (), False),
    "idiom.inside-out-pipeline": ("a pipeline of three or more transformation stages written as nested application instead of `|>`", (), False),
    "idiom.let-underscore-unit": ("`let _ = e` where `e` has type Unit", (), False),
    "defensive.discarded-result": ("a Result or Option value discarded without being handled", (M,), False),
    "dup.existing": ("a hand-rolled function that the stdlib or an existing helper already provides", (), True),
    "magic-literal": ("a raw numeric character code, or a constant's value repeated as a literal", (), False),
    "suppress.invalid-reason": ("a `lint-disable` whose reason is not a concrete semantic difference, an independence requirement, a measured cost, or a verified language limitation", (), False),
    "module.scattered-concern": ("new code adding a concern to a file that is not about it, or scattering one concern across distant regions", (), False),
    "comment.history": ("a comment sentence narrating what the code used to do or how it got here", (C,), False),
    "comment.provenance": ("a comment citing an issue number or plan id only to record which work item introduced the code", (C,), False),
    "comment.measurement": ("a comment containing hand-typed measurements or recorded observations (percentages, CPU-seconds, sizes, counts, or what a run printed at a named commit)", (C,), False),
    "comment.restates": ("a comment block of which half or more of the sentences restate what the code plainly says", (C,), False),
    "comment.ephemeral": ("a comment arguing with a reviewer or anchored to an in-flight change ('this slice', 'this PR')", (C,), False),
    "comment.speculative": ("a comment speculating about future changes ('if X ever gains Y')", (C,), False),
    "comment.shout": ("an emoji sigil (🚨, ⚠️, 🔒) or dense ALL-CAPS emphasis (three or more emphatic capitalised words in one comment block)", (C,), False),
    "doc.register": ("implementation narration inside a stdlib doc comment", (C, "stdlib_doc"), False),
    "test.weak-reject": ("a test asserting that something is rejected without naming the expected diagnostic code or message", (T,), False),
    "test.bool-helper": ("a test helper returning Bool that is graded with expectTrue/expectFalse", (T,), False),
    "test.length-not-contents": ("a test asserting a list's length where its contents are knowable", (T,), False),
    "test.escaped-program": ("a multi-line test program written as a `\\n`-escaped string", (T,), False),
    "test.hand-count": ("an exact, hand-maintained row or fixture count asserted by a test", (T,), False),
    "test.probe-in-production": ("a test probe living in a production module, or a probe returning a positional Bool tuple", (T,), False),
    "test.repeated-columns": ("a table column repeating one value in nearly every row", (T,), False),
    "test.doctest-costume": ("a doctest that needs fixture bindings or asserts `... == x` resulting in True", (T,), False),
    "test.vehicle": ("a test in the wrong vehicle: a prop whose law does not document the API, or a shell gate whose `shell-because:` is not a valid reason", (T,), False),
    "comment.stale": ("a comment that contradicts or no longer describes the code, or names something that does not exist", (C,), True),
    "comment.layout": ("a comment left ragged or broken mid-clause by an edit", (C,), False),
    "dup.in-diff": ("the same expression or body repeated within the excerpt, or repeating a body or expression that already exists in the same module (shown in evidence) instead of calling it", (), True),
    "dup.cross-file": ("a helper copied between files instead of shared", (), True),
    "dead.code": ("an unused binding, parameter, arm or import, a constructor with no producer, or an unreachable branch", (), False),
    "naming.misleading": ("a name that says something other than what the binding holds or does", (), False),
    "defensive.silent-default": ("an error or absence turned into a plausible value, making a failure quiet", (M,), False),
    "defensive.redundant": ("a re-check of what the types or the caller already guarantee", (), False),
    "diag.quality": ("a diagnostic message that is vague, double-reported, or gives no remedy", (), False),
    "test.gap": ("new behaviour or a new branch with no test", (T,), False),
}

# ---------------------------------------------------------------------------
# Parsing the rubric markdown.
# ---------------------------------------------------------------------------
SLUG_RE = re.compile(r"^`([a-z]+(?:[.-][a-z]+)*)`$")


def _cells(line: str) -> list[str]:
    """Split a markdown table row on pipes outside backticks."""
    out, cur, tick = [], [], False
    for ch in line.strip().strip("|"):
        if ch == "`":
            tick = not tick
        if ch == "|" and not tick:
            out.append("".join(cur).strip())
            cur = []
        else:
            cur.append(ch)
    out.append("".join(cur).strip())
    return out


def load_rubric(path: Path = RUBRIC_MD) -> dict[str, dict]:
    if not path.exists():
        sys.exit(f"rubric not found: {path}")
    classes: dict[str, dict] = {}
    section = ""
    for line in path.read_text().splitlines():
        if line.startswith("## "):
            section = line[3:].strip()
            if section.startswith("Language and tooling"):
                break
            continue
        if not line.startswith("| `"):
            continue
        cells = _cells(line)
        m = SLUG_RE.match(cells[0])
        if not m:
            continue
        classes[m.group(1)] = {
            "class": m.group(1),
            "section": section,
            "positive": cells[1],
            "exceptions": cells[2] if len(cells) > 3 else "",
            "ruling": cells[3] if len(cells) > 3 else "",
        }
    return classes


def rule_text(r: dict) -> str:
    exc = r["exceptions"] if r["exceptions"] and r["exceptions"].lower() != "none" else "none listed"
    return f"Flag: {r['positive']}\nDo not flag (exceptions and controls): {exc}"


def notes_for(cls: str) -> str:
    keys = ("core",) + SUBJECTS[cls][1]
    return "\n\n".join(NOTES[k] for k in keys)


def cross_snippet(cls: str) -> bool:
    return SUBJECTS[cls][2]


# ---------------------------------------------------------------------------
# Haiku / Opus: one class per prompt, evidence quoted verbatim.
# ---------------------------------------------------------------------------
OUTPUT_CONTRACT = (
    "Reply with one JSON object and nothing else:\n"
    '{"flag": true|false, "confidence": <0..1>, "evidence_quote": "<text>", '
    '"reason": "<one or two sentences>"}\n'
    "- flag: true only if the code shows an instance of THIS class, not "
    "another problem.\n"
    "- evidence_quote: when flag is true, copy verbatim a contiguous span "
    "(part of one line or several whole lines) from the excerpt or an evidence "
    "block that shows the instance. A quote that does not occur verbatim is "
    "discarded, and the finding with it. Empty string when flag is false.\n"
    "- confidence: how sure you are that your `flag` value is right."
)


def generative_system(r: dict, shots: list[tuple[str, bool, str]] = ()) -> str:
    cls = r["class"]
    parts = [
        f"You review Medaka source code for exactly one style class: `{cls}`"
        + (f" (ruling {r['ruling']})" if r["ruling"] else "") + ".",
        "## Medaka\n" + notes_for(cls),
        "## The rule\n" + rule_text(r),
        "## Scope\nReview is diff-scoped: treat the excerpt as code a diff adds. "
        "Rules apply to test code exactly as to source, except a fixture that "
        "deliberately exhibits a pattern (a must-fail pin, a lint rule's own "
        "fixture). Evidence blocks are context from elsewhere in the repository. "
        "Do not report other classes, idiom density, or formatting `medaka fmt` "
        "owns.",
        "## Output\n" + OUTPUT_CONTRACT,
    ]
    if shots:
        ex = ["## Labelled examples (other code from this repository)"]
        for i, (body, flag, why) in enumerate(shots, 1):
            ex.append(f"### Example {i}: {'FLAG' if flag else 'DO NOT FLAG'}\n{body}\n"
                      + (f"Why: {why}" if why else ""))
        parts.insert(4, "\n\n".join(ex))
    return "\n\n".join(parts)
