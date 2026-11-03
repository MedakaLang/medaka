import copy
import json
import tempfile
import unittest
from pathlib import Path

from report import load_budgets
from schema import validate_budgets


class BudgetTest(unittest.TestCase):
    def fixture(self):
        names = ("cold_init_ns", "queued_interval_ns", "query_latency_ns", "instrumentation_overhead_ns", "peak_rss_bytes", "context_usage")
        metrics = {}
        for name in names:
            measured = name in names[:2]
            metrics[name] = {"status": "measured" if measured else "unavailable",
                             "limit": 7 if measured else None,
                             "unit": "bytes" if name == "peak_rss_bytes" else "unknown" if name == "context_usage" else "ns",
                             "scope": "fake scope", "rationale": "fake evidence"}
        return {"schema_version": 1, "metrics": metrics}

    def test_valid_fake_document_and_loader(self):
        value = self.fixture()
        self.assertEqual(value, validate_budgets(value))
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "budgets.json"
            path.write_text(json.dumps(value))
            self.assertEqual(value, load_budgets(path))

    def test_missing_malformed_and_misleading_entries(self):
        variants = []
        value = self.fixture(); del value["metrics"]["context_usage"]; variants.append(value)
        value = self.fixture(); value["schema_version"] = True; variants.append(value)
        value = self.fixture(); value["metrics"]["cold_init_ns"]["limit"] = True; variants.append(value)
        value = self.fixture(); value["metrics"]["cold_init_ns"]["unit"] = "bytes"; variants.append(value)
        value = self.fixture(); value["metrics"]["query_latency_ns"]["limit"] = 7; variants.append(value)
        value = self.fixture(); value["metrics"]["peak_rss_bytes"].update(status="measured", limit=7); variants.append(value)
        value = self.fixture(); value["metrics"]["context_usage"]["rationale"] = " "; variants.append(value)
        value = self.fixture(); value["metrics"]["queued_interval_ns"].update(status="unavailable", limit=None); variants.append(value)
        for value in variants:
            with self.subTest(value=value), self.assertRaises(ValueError):
                validate_budgets(copy.deepcopy(value))
