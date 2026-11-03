import copy
import json
from pathlib import Path
import unittest

from protocol import validate_sequence


class ProtocolTest(unittest.TestCase):
    def setUp(self):
        self.init = [{"type": "initialize", "versions": [1]},
                     {"type": "initialized", "version": 1, "capabilities": ["check"], "worker": "old", "error": None}]
        self.context = {k: {"value": k, "provenance": "inferred"} for k in ("workspace", "toolchain", "snapshot", "profile")}
        self.request = {"type": "request", "id": "1", "context": self.context, "operation": {"name": "openWorkspace", "arguments": {}}}
        self.response = {"type": "response", "id": "1", "status": "complete", "result": {"worker": "old"}, "error": None}
        self.close = {"type": "shutdown"}

    def session(self, *items):
        return copy.deepcopy(self.init + list(items) + [self.close])

    def test_manifest(self):
        manifest = json.loads((Path(__file__).parent / "protocol.json").read_text())
        self.assertEqual(manifest["private_versions"], [1])
        self.assertEqual(set(manifest["response_statuses"]), {"complete", "partial", "error"})

    def test_complete_partial_and_error(self):
        for status, result, error in [("complete", {"worker": "old"}, None), ("partial", {"incomplete": True}, None), ("error", None, "failed")]:
            response = dict(self.response, status=status, result=result, error=error)
            validate_sequence(self.session(self.request, response))
        with self.assertRaises(ValueError):
            validate_sequence(self.session(self.request, dict(self.response, status="error", error="failed")))

    def test_version_and_refusal(self):
        with self.assertRaises(ValueError):
            validate_sequence([{"type": "initialize", "versions": [2]}, self.init[1], self.close])
        validate_sequence([{"type": "initialize", "versions": [2]}, {"type": "initialized", "version": None, "capabilities": [], "worker": None, "error": "incompatible"}])

    def test_identity_and_ids(self):
        for provenance, value in [("attested", "worker-value"), ("inferred", "hash"), ("unavailable", None)]:
            req = copy.deepcopy(self.request)
            req["context"]["toolchain"] = {"value": value, "provenance": provenance}
            validate_sequence(self.session(req, self.response))
        req = copy.deepcopy(self.request)
        req["context"]["toolchain"] = {"value": "guessed", "provenance": "unavailable"}
        with self.assertRaises(ValueError):
            validate_sequence(self.session(req, self.response))
        with self.assertRaises(ValueError):
            validate_sequence(self.session(self.request, self.response, self.request, self.response))

    def test_replacement_success_failure_and_inflight(self):
        replace = {"type": "replace", "id": "2", "workspace": "workspace", "artifact": {"id": "new", "digest": "sha256:abc"}}
        failed = {"type": "replacement", "id": "2", "workspace": "workspace", "status": "failed", "worker": "old", "error": "bad artifact"}
        validate_sequence(self.session(self.request, self.response, replace, failed))
        validate_sequence(self.session(self.request, self.response, replace, dict(failed, status="switched", worker="new", error=None)))
        with self.assertRaises(ValueError):
            validate_sequence(self.session(self.request, self.response, replace, dict(failed, worker="new")))
        with self.assertRaises(ValueError):
            validate_sequence(self.session(self.request, replace, failed, self.response))

    def test_workspace_replacement_routing(self):
        a = copy.deepcopy(self.request)
        b = copy.deepcopy(self.request)
        b['id'] = 'b'
        b['context']['workspace']['value'] = 'B'
        br = dict(self.response, id='b')
        replace = {'type': 'replace', 'id': 'r', 'workspace': 'B',
                   'artifact': {'id': 'new', 'digest': 'sha256:abc'}}
        reply = {'type': 'replacement', 'id': 'r', 'workspace': 'B',
                 'status': 'switched', 'worker': 'new', 'error': None}
        validate_sequence(self.session(a, self.response, b, br, replace, reply))
        with self.assertRaisesRegex(ValueError, 'unknown workspace'):
            validate_sequence(self.session(replace, reply))
        with self.assertRaisesRegex(ValueError, 'workspace mismatch'):
            validate_sequence(self.session(a, self.response, b, br, replace, dict(reply, workspace='workspace')))

    def test_unknown_and_missing_fields(self):
        with self.assertRaises(ValueError):
            validate_sequence(self.session(dict(self.request, extra=True), self.response))
        with self.assertRaises(ValueError):
            validate_sequence(self.session(self.request, dict(self.response, id="wrong")))


if __name__ == "__main__":
    unittest.main()
