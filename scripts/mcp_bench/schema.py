"""Pure, closed-schema validation for benchmark records."""
from copy import deepcopy
from pathlib import PurePosixPath
from typing import Any, NewType

Task = NewType("Task", dict)
Event = NewType("Event", dict)
Run = NewType("Run", dict)


def _object(value: Any, fields: set[str], name: str) -> None:
    if not isinstance(value, dict) or set(value) != fields:
        raise ValueError(f"{name}: expected exactly {sorted(fields)}")


def _text(value: Any, name: str) -> None:
    if not isinstance(value, str) or not value.strip():
        raise ValueError(f"{name}: expected nonempty text")


def _count(value: Any, name: str) -> None:
    if type(value) is not int or value < 0:
        raise ValueError(f"{name}: expected nonnegative integer")


def validate_task(value: dict) -> Task:
    _object(value, {"id", "category", "prompt", "files", "controls", "rubric"}, "task")
    for field in ("id", "category", "prompt"):
        _text(value[field], field)
    if not isinstance(value["files"], dict) or not value["files"]:
        raise ValueError("files: expected nonempty mapping")
    for path, source in value["files"].items():
        _text(path, "path")
        p = PurePosixPath(path)
        if p.is_absolute() or ".." in p.parts or str(p) != path or path == "." or p.parts[0] == "PROMPT.txt":
            raise ValueError("files: unsafe path")
        if not isinstance(source, str):
            raise ValueError("files: expected source text")
    if not isinstance(value["controls"], list) or not value["controls"]:
        raise ValueError("controls: expected nonempty list")
    for control in value["controls"]:
        _object(control, {"id", "question", "answer", "basis"}, "control")
        for field in control:
            _text(control[field], field)
    if len({c["id"] for c in value["controls"]}) != len(value["controls"]):
        raise ValueError("controls: duplicate id")
    if not isinstance(value["rubric"], list) or not value["rubric"]:
        raise ValueError("rubric: expected nonempty list")
    for criterion in value["rubric"]:
        _object(criterion, {"id", "answer", "basis"}, "criterion")
        for field in criterion:
            _text(criterion[field], field)
    if len({c["id"] for c in value["rubric"]}) != len(value["rubric"]):
        raise ValueError("rubric: duplicate id")
    return Task(deepcopy(value))


def validate_event(value: dict) -> Event:
    _object(value, {"schema_version", "session_id", "request_id", "tool", "classification", "event", "outcome", "duration_ns", "response_bytes"}, "event")
    if type(value["schema_version"]) is not int or value["schema_version"] != 1:
        raise ValueError("schema_version: expected 1")
    for field in ("session_id", "request_id", "tool"):
        _text(value[field], field)
    if value["classification"] not in ("probe", "organic"):
        raise ValueError("classification: unknown")
    if value["event"] not in ("start", "finish", "protocol", "cancel_requested"):
        raise ValueError("event: unknown")
    if value["outcome"] not in (None, "success", "tool_error", "protocol_error"):
        raise ValueError("outcome: unknown")
    if value["event"] == "finish" and value["outcome"] not in ("success", "tool_error", "protocol_error"):
        raise ValueError("finish: missing outcome")
    if value["event"] != "finish" and value["outcome"] is not None:
        raise ValueError("non-finish: unexpected outcome")
    for field in ("duration_ns", "response_bytes"):
        if value[field] is not None:
            _count(value[field], field)
        if value["event"] == "finish" and value[field] is None:
            raise ValueError(f"finish: missing {field}")
        if value["event"] != "finish" and value[field] is not None:
            raise ValueError(f"non-finish: unexpected {field}")
    return Event(deepcopy(value))


def validate_run(value: dict) -> Run:
    fields = {"schema_version", "run_id", "task_id", "arm", "outcome", "attempted", "completed", "passed", "failed", "skipped"}
    if isinstance(value, dict) and value.get("schema_version") == 2:
        fields |= {"wall_ns", "cpu_ns", "peak_rss_bytes", "resource_scope", "resource_reason"}
    _object(value, fields, "run")
    if type(value["schema_version"]) is not int or value["schema_version"] not in (1, 2):
        raise ValueError("schema_version: expected 1 or 2")
    if value["schema_version"] == 2:
        _count(value["wall_ns"], "wall_ns")
        _text(value["resource_scope"], "resource_scope")
        _object(value["resource_reason"], {"cpu_ns", "peak_rss_bytes"}, "resource_reason")
        for metric in ("cpu_ns", "peak_rss_bytes"):
            if value[metric] is None:
                _text(value["resource_reason"][metric], metric + " reason")
            else:
                _count(value[metric], metric)
                if value["resource_reason"][metric] is not None:
                    raise ValueError(metric + ": measured value must have no unavailability reason")
    for field in ("run_id", "task_id", "arm"):
        _text(value[field], field)
    if value["outcome"] not in ("success", "incorrect", "unsupported", "startup_failure", "tool_error", "protocol_error", "crash", "timeout", "cancelled", "observer_failure"):
        raise ValueError("outcome: unknown")
    for field in ("attempted", "completed", "passed", "failed", "skipped"):
        _count(value[field], field)
    if value["completed"] != value["passed"] + value["failed"] or value["attempted"] != value["completed"] + value["skipped"]:
        raise ValueError("denominator counts disagree")
    if value["outcome"] == "success" and (value["passed"] == 0 or value["failed"] or value["skipped"]):
        raise ValueError("success requires nonzero, entirely passing checks")
    return Run(deepcopy(value))


def validate_budgets(value: dict) -> dict:
    """Validate versioned budgets, including explicit measurement gaps."""
    _object(value, {"schema_version", "metrics"}, "budgets")
    if type(value["schema_version"]) is not int or value["schema_version"] not in (1, 2):
        raise ValueError("budgets: expected schema version 1 or 2")
    version = value['schema_version']
    metrics = value["metrics"]
    names = {"cold_init_ns", "queued_interval_ns", "query_latency_ns", "instrumentation_overhead_ns", "peak_rss_bytes", "context_usage"}
    if version == 2:
        names |= {'peak_memory_charge_bytes', 'input_tokens_context_proxy'}
    methods = {'cold_init_ns': 'collector_entry_to_first_response',
               'queued_interval_ns': 'adjacent_queued_arrivals',
               'query_latency_ns': 'serial_send_to_validated_response',
               'instrumentation_overhead_ns': 'matched_absolute_round_trip_delta',
               'peak_memory_charge_bytes': 'cgroup_v2_memory.peak',
               'peak_rss_bytes': 'process_tree_peak_rss',
               'input_tokens_context_proxy': 'host_accounted_input_tokens'}
    _object(metrics, names, "metrics")
    for name, entry in metrics.items():
        fields = {"status", "limit", "unit", "scope", "rationale"}
        if version == 2:
            fields.add('evidence')
        _object(entry, fields, name)
        for field in ("unit", "scope", "rationale"):
            _text(entry[field], name + " " + field)
        expected_unit = ("bytes" if name in ("peak_rss_bytes", 'peak_memory_charge_bytes') else
                         "unknown" if name == "context_usage" else
                         'tokens' if name == 'input_tokens_context_proxy' else "ns")
        if entry["unit"] != expected_unit:
            raise ValueError(name + ": incorrect unit")
        if name in ("cold_init_ns", "queued_interval_ns") and entry["status"] != "measured":
            raise ValueError(name + ": expected measured budget")
        if entry["status"] == "measured":
            if (version == 1 and name not in ("cold_init_ns", "queued_interval_ns")) or name not in methods:
                raise ValueError(name + ": no supported measurement")
            _count(entry["limit"], name + " limit")
            if entry["limit"] == 0:
                raise ValueError(name + ": limit must be positive")
            if version == 2:
                evidence = entry['evidence']
                _object(evidence, {'method', 'samples', 'observed_max', 'artifact_sha256'}, name + ' evidence')
                if evidence['method'] != methods[name]:
                    raise ValueError(name + ': unsupported measurement method')
                _count(evidence['samples'], name + ' samples')
                _count(evidence['observed_max'], name + ' observed_max')
                digest = evidence['artifact_sha256']
                if (not isinstance(digest, str) or len(digest) != 64
                        or any(c not in '0123456789abcdef' for c in digest)):
                    raise ValueError(name + ': invalid evidence digest')
                if not evidence['samples'] or entry['limit'] < evidence['observed_max']:
                    raise ValueError(name + ': unsupported measured ceiling')
        elif entry["status"] == "unavailable":
            if entry["limit"] is not None:
                raise ValueError(name + ": unavailable metric cannot have a limit")
            if version == 2 and entry['evidence'] is not None:
                raise ValueError(name + ': unavailable metric must have null evidence')
        else:
            raise ValueError(name + ": unknown status")
    return deepcopy(value)
