import copy
import json
from pathlib import Path
import tempfile
import unittest

from schema import validate_event, validate_run, validate_task

HERE = Path(__file__).resolve().parent
CATEGORIES = {"imported_definition", "shadowed_references", "stdlib_api_discovery", "diagnostic_repair", "dispatch_explanation", "compiler_edit_worktree_validation"}
CONTROLS = {"same-name-alias", "parameter", "reexport", "incomplete-source", "other-type", "same-path"}


def materialize(task, destination):
    """Write only trial inputs; rubric and control answers remain with the grader."""
    task = validate_task(task)
    for name, source in task["files"].items():
        path = destination / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(source, encoding="utf-8")
    (destination / "PROMPT.txt").write_text(task["prompt"] + "\n" + "\n".join(c["question"] for c in task["controls"]) + "\n", encoding="utf-8")


class SchemaTests(unittest.TestCase):
    def setUp(self):
        self.tasks = json.loads((HERE / "tasks.json").read_text())
        self.event = dict(schema_version=1, session_id="s", request_id="r", tool="check", classification="probe", event="finish", outcome="success", duration_ns=1, response_bytes=2)
        self.run = dict(schema_version=1, run_id="r", task_id="t", arm="shell", outcome="success", attempted=1, completed=1, passed=1, failed=0, skipped=0)

    def test_corpus_and_controls_complete(self):
        self.assertEqual(len(self.tasks), 6)
        self.assertEqual({t['category'] for t in self.tasks}, CATEGORIES)
        self.assertEqual({c['id'] for t in self.tasks for c in t['controls']}, CONTROLS)
        self.assertEqual(len({t['id'] for t in self.tasks}), 6)
        for task in self.tasks:
            self.assertEqual(validate_task(task), task)

    def test_closed_identity_outcome_and_denominators(self):
        for validator, record, fields in ((validate_task, self.tasks[0], ('id', 'category')), (validate_event, self.event, ('session_id', 'request_id', 'outcome')), (validate_run, self.run, ('run_id', 'task_id', 'arm', 'outcome', 'attempted', 'completed', 'passed', 'failed', 'skipped'))):
            for field in fields:
                bad = copy.deepcopy(record)
                del bad[field]
                with self.subTest(field=field, kind='missing'), self.assertRaises(ValueError):
                    validator(bad)
            bad = copy.deepcopy(record)
            bad['unknown'] = 'x'
            with self.assertRaises(ValueError):
                validator(bad)
        for validator, record in ((validate_event, self.event), (validate_run, self.run)):
            bad = dict(record, outcome='unrecognized')
            with self.assertRaises(ValueError):
                validator(bad)
        for change in ({'passed': 0, 'completed': 0, 'attempted': 0}, {'attempted': 2}, {'passed': True}):
            with self.assertRaises(ValueError):
                validate_run(dict(self.run, **change))

    def test_controls_are_backed_by_inputs_and_source(self):
        tasks = {task['id']: task for task in self.tasks}
        self.assertIn('import alpha as A', tasks['import-definition']['files']['main.mdk'])
        self.assertIn('import beta as B', tasks['import-definition']['files']['main.mdk'])
        self.assertEqual(tasks['import-definition']['files']['beta.mdk'], 'export value = 22\n')
        self.assertIn('f x = x + 1', tasks['shadow-references']['files']['main.mdk'])
        self.assertIn('g = x + 2', tasks['shadow-references']['files']['main.mdk'])
        self.assertEqual(tasks['repair-diagnostic']['files']['incomplete.mdk'], 'main = 1 +\n')
        self.assertIn('impl Describe String where', tasks['dispatch']['files']['main.mdk'])
        repo = HERE.parents[1]
        self.assertIn('export import core.{Filterable, filter, filterMap}', (repo / 'stdlib/list.mdk').read_text())
        self.assertIn('MEDAKA_STRICT', (repo / 'compiler/driver/medaka_cli.mdk').read_text())

    def test_materialization_only_exposes_inputs(self):
        for task in self.tasks:
            with tempfile.TemporaryDirectory() as tmp:
                root = Path(tmp)
                materialize(task, root)
                self.assertEqual({str(p.relative_to(root)) for p in root.rglob('*') if p.is_file()}, set(task['files']) | {'PROMPT.txt'})
                contents = (root / 'PROMPT.txt').read_text()
                self.assertEqual(contents, task['prompt'] + '\n' + '\n'.join(c['question'] for c in task['controls']) + '\n')
                for name, source in task['files'].items():
                    self.assertEqual((root / name).read_text(), source)
        bad = copy.deepcopy(self.tasks[0])
        bad['files']['../escape'] = 'x'
        with self.assertRaises(ValueError):
            validate_task(bad)


if __name__ == '__main__':
    unittest.main()
