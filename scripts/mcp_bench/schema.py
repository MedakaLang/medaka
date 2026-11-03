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
        if p.is_absolute() or ".." in p.parts or str(p) != path or path in (".", "PROMPT.txt"):
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
    _object(value, {"schema_version", "run_id", "task_id", "arm", "outcome", "attempted", "completed", "passed", "failed", "skipped"}, "run")
    if type(value["schema_version"]) is not int or value["schema_version"] != 1:
        raise ValueError("schema_version: expected 1")
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
