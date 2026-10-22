"""Tests for review.py's skip of declarations moved unchanged.

Run: python3 -I scripts/review_bench/review_test.py
Each case builds a small synthetic git repo (a base commit and a head commit), points
review.py and evidence.py at it, and asks which declarations survive into units.
"""
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import evidence as EV  # noqa: E402
import review as RV  # noqa: E402


def sh(root: Path, *args: str) -> str:
    r = subprocess.run(["git", "-C", str(root), *args], capture_output=True, text=True, check=True)
    return r.stdout.strip()


class RepoCase(unittest.TestCase):
    def repo(self, base: dict, head: dict) -> tuple[str, str]:
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        root = Path(tmp.name)
        sh(root, "init", "-q")
        sh(root, "config", "user.email", "t@example.com")
        sh(root, "config", "user.name", "t")
        shas = []
        for files in (base, head):
            for p in list(root.rglob("*.mdk")):
                p.unlink()
            for name, text in files.items():
                (root / name).write_text(text)
            sh(root, "add", "-A")
            sh(root, "commit", "-q", "-m", "c")
            shas.append(sh(root, "rev-parse", "HEAD"))
        saved = EV.ROOT, RV.ROOT, dict(EV.Tree._all)
        EV.ROOT = RV.ROOT = root
        EV.Tree._all.clear()

        def restore():
            EV.ROOT, RV.ROOT = saved[0], saved[1]
            EV.Tree._all.clear()
            EV.Tree._all.update(saved[2])
        self.addCleanup(restore)
        return shas[0], shas[1]


class MovedTest(RepoCase):
    def specs(self, base: dict, head: dict, skip: bool = True):
        a, b = self.repo(base, head)
        dropped: list = []
        files = [p for p in head if p.endswith(".mdk")]
        specs, _ = RV.unit_specs(a, b, files, True, skip, dropped)
        return specs, dropped

    SHOUT = "-- \U0001F6A8 NEVER CALL THIS WITH A NEGATIVE COUNT\n"
    OLD = "-- \U0001F6A8 NEVER CALL THIS WITH A NEGATIVE COUNT\nexport double : Int -> Int\ndouble n = n * 2\n"

    def test_moved_with_dropped_sigil_and_visibility_is_skipped(self):
        new = "-- never call this with a negative count\npublic export double : Int -> Int\ndouble n =\n  n * 2\n"
        specs, dropped = self.specs({"a.mdk": self.OLD + "\nkeep x = x\n"}, {"a.mdk": "keep x = x\n", "b.mdk": new})
        self.assertEqual([], specs)
        self.assertEqual([{"name": "double", "file": "b.mdk", "reason": "moved-unchanged"}], dropped)

    def test_changed_token_is_not_skipped(self):
        new = "export double : Int -> Int\ndouble n = n * 3\n"
        specs, dropped = self.specs({"a.mdk": self.OLD}, {"b.mdk": new})
        self.assertEqual([], dropped)
        self.assertEqual(["double"], [s[3] for s in specs])

    def test_rename_is_not_skipped(self):
        new = "-- \U0001F6A8 NEVER CALL THIS WITH A NEGATIVE COUNT\nexport twice : Int -> Int\ntwice n = n * 2\n"
        specs, dropped = self.specs({"a.mdk": self.OLD}, {"b.mdk": new})
        self.assertEqual([], dropped)
        self.assertEqual(["twice"], [s[3] for s in specs])

    def test_keep_moved_default_off_reviews_everything(self):
        specs, dropped = self.specs({"a.mdk": self.OLD}, {"b.mdk": self.OLD}, skip=False)
        self.assertEqual([], dropped)
        self.assertEqual(["double"], [s[3] for s in specs])

    def test_copy_with_original_kept_is_not_skipped(self):
        specs, dropped = self.specs({"a.mdk": self.OLD}, {"a.mdk": self.OLD, "b.mdk": self.OLD})
        self.assertEqual([], dropped)
        self.assertEqual(["double"], [s[3] for s in specs])
        self.assertEqual(["b.mdk"], [s[0] for s in specs])

    def test_same_file_reorder_keeps_only_the_edited_declaration(self):
        base = "one x = x\n\ntwo x = x + 1\n"
        head = "two x = x + 1\n\none x = x + 2\n"
        specs, _ = self.specs({"a.mdk": base}, {"a.mdk": head})
        self.assertEqual(["one"], [s[3] for s in specs])


class PreexistingTest(RepoCase):
    """BaseText: a comment finding whose quote the base already held in a touched file."""

    COMMENT = "-- #156 S3a: ONE record for every pending dispatch-site shape.\n"
    OLD = COMMENT + "export double : Int -> Int\ndouble n = n * 2\n"
    # Moved to another file, re-wrapped, with one token of code changed: not skipped as
    # moved-unchanged, so the old comment sits on changed lines.
    NEW = "-- #156 S3a: ONE record for every\n-- pending dispatch-site shape.\nexport double : Int -> Int\ndouble n = n * 3\n"

    def base_text(self, base: dict, head: dict) -> RV.BaseText:
        a, b = self.repo(base, head)
        return RV.BaseText(lambda _u: (a, b))

    def test_moved_rewrapped_comment_is_preexisting(self):
        pre = self.base_text({"a.mdk": self.OLD + "\nkeep x = x\n"}, {"a.mdk": "keep x = x\n", "b.mdk": self.NEW})
        self.assertTrue(pre({}, "comment.provenance", "-- #156 S3a: ONE record for every\n-- pending dispatch-site shape."))

    def test_new_comment_is_not_preexisting(self):
        pre = self.base_text({"a.mdk": self.OLD}, {"a.mdk": "-- Phase 2 sprint 6c moved the cell here.\n" + self.OLD})
        self.assertFalse(pre({}, "comment.provenance", "-- Phase 2 sprint 6c moved the cell here."))

    def test_comment_stale_and_code_classes_are_never_preexisting(self):
        pre = self.base_text({"a.mdk": self.OLD}, {"b.mdk": self.NEW})
        self.assertFalse(pre({}, "comment.stale", self.COMMENT))
        self.assertFalse(pre({}, "data.sentinel", "double n = n * 2"))

    def test_short_quote_is_not_preexisting(self):
        pre = self.base_text({"a.mdk": "-- todo\nexport double : Int -> Int\ndouble n = n * 2\n"},
                             {"a.mdk": "-- todo\nexport double : Int -> Int\ndouble n = n * 3\n"})
        self.assertFalse(pre({}, "comment.ephemeral", "-- todo"))

    def test_only_touched_files_count(self):
        # The comment exists at the base only in c.mdk, which the diff leaves alone: a copy
        # into b.mdk is the diff's own comment.
        pre = self.base_text({"c.mdk": self.OLD, "a.mdk": "keep x = x\n"},
                             {"c.mdk": self.OLD, "a.mdk": "keep x = x + 1\n", "b.mdk": self.NEW})
        self.assertFalse(pre({}, "comment.provenance", self.COMMENT))

    def test_deleted_file_counts(self):
        pre = self.base_text({"a.mdk": self.OLD}, {"b.mdk": self.NEW})
        self.assertTrue(pre({}, "comment.provenance", self.COMMENT))


if __name__ == "__main__":
    unittest.main()
