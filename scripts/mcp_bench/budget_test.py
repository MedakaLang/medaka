import copy
import json
import tempfile
import unittest
from pathlib import Path

from report import load_budgets
from schema import validate_budgets


class BudgetTest(unittest.TestCase):
    def measured_fixture(self):
        value = self.fixture()
        value['schema_version'] = 2
        methods = {'cold_init_ns': 'collector_entry_to_first_response',
                   'queued_interval_ns': 'adjacent_queued_arrivals',
                   'query_latency_ns': 'serial_send_to_validated_response',
                   'instrumentation_overhead_ns': 'matched_absolute_round_trip_delta',
                   'peak_memory_charge_bytes': 'cgroup_v2_memory.peak',
                   'input_tokens_context_proxy': 'host_accounted_input_tokens'}
        for name in ('peak_memory_charge_bytes', 'input_tokens_context_proxy'):
            value['metrics'][name] = {'unit': 'bytes' if name.endswith('bytes') else 'tokens',
                                      'scope': 'synthetic scope', 'rationale': 'synthetic evidence'}
        for name, entry in value['metrics'].items():
            if name in methods:
                entry.update(status='measured', limit=7,
                             evidence={'method': methods[name], 'samples': 5, 'observed_max': 6,
                                       'artifact_sha256': 'a' * 64})
            else:
                entry['evidence'] = None
        return value

    def test_version_two_accepts_measurements_and_rejects_false_claims(self):
        value = self.measured_fixture()
        self.assertEqual(value, validate_budgets(value))
        mutations = [lambda v: v['metrics']['query_latency_ns'].update(evidence=None),
                     lambda v: v['metrics']['query_latency_ns'].update(limit=None),
                     lambda v: v['metrics']['context_usage'].update(status='measured', limit=7),
                     lambda v: v['metrics']['peak_rss_bytes'].update(evidence={}),
                     lambda v: v['metrics']['peak_memory_charge_bytes']['evidence'].update(method='RSS'),
                     lambda v: v['metrics']['query_latency_ns']['evidence'].update(samples=0),
                     lambda v: v['metrics']['query_latency_ns']['evidence'].update(samples=True),
                     lambda v: v['metrics']['query_latency_ns']['evidence'].update(observed_max=8),
                     lambda v: v['metrics']['query_latency_ns']['evidence'].update(artifact_sha256='missing'),
                     lambda v: v['metrics'].pop('input_tokens_context_proxy')]
        for mutation in mutations:
            candidate = copy.deepcopy(value)
            mutation(candidate)
            with self.subTest(value=candidate), self.assertRaises(ValueError):
                validate_budgets(candidate)

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
