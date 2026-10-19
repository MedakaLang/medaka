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


class MovedTest(unittest.TestCase):
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


if __name__ == "__main__":
    unittest.main()
