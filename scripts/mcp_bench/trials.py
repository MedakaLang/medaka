"""Pure trial preparation, transcript import, and independent grading."""
from copy import deepcopy
import re

from schema import validate_task

ARMS = ("shell-only", "mcp")
OUTCOMES = ("success", "incorrect", "unsupported", "timeout", "infrastructure_error",
            "tool_error", "protocol_error", "crash", "cancelled", "unknown")
_REF = re.compile(r"sha256:[0-9a-f]{64}\Z")


def _fields(value, names, label):
    if not isinstance(value, dict) or set(value) != set(names):
        raise ValueError(f"{label}: expected exactly {sorted(names)}")


def _text(value, label):
    if not isinstance(value, str) or not value.strip():
        raise ValueError(f"{label}: expected nonempty text")


def _ref(value):
    if not isinstance(value, str) or not _REF.fullmatch(value):
        raise ValueError("evidence reference: expected sha256 digest")


def trial_manifest(task, arm, config):
    """Return a fresh allowlisted trial spec; rubric and answers stay private."""
    task = validate_task(task)
    if arm not in ARMS:
        raise ValueError("unknown trial arm")
    _fields(config, ("run_id", "model", "effort", "harness_version"), "config")
    for name, value in config.items():
        _text(value, name)
    return {"schema_version": "trial-spec-1", "run_id": config["run_id"],
            "task_id": task["id"], "arm": arm, "model": config["model"],
            "effort": config["effort"], "harness_version": config["harness_version"],
            "deadline_seconds": 600, "tool_call_limit": 30,
            "prompt": task["prompt"], "files": deepcopy(task["files"]),
            "controls": [{"id": c["id"], "question": c["question"]} for c in task["controls"]]}


def import_transcript(spec, transcript):
    """Copy host observations, preserving bytes and explicit unknown counters."""
    _fields(spec, ("schema_version", "run_id", "task_id", "arm", "model", "effort",
                   "harness_version", "deadline_seconds", "tool_call_limit", "prompt", "files", "controls"), "spec")
    if spec["schema_version"] != "trial-spec-1" or spec["arm"] not in ARMS or spec["deadline_seconds"] != 600 or spec["tool_call_limit"] != 30:
        raise ValueError("invalid trial spec")
    _fields(transcript, ("attempts",), "transcript")
    attempts = transcript["attempts"]
    if not isinstance(attempts, list) or not 1 <= len(attempts) <= 2:
        raise ValueError("expected one attempt and at most one retry")
    if len(attempts) == 2 and (not isinstance(attempts[0], dict) or attempts[0].get("outcome") != "infrastructure_error"):
        raise ValueError("only infrastructure errors may be retried")
    for attempt in attempts:
        _fields(attempt, ("outcome", "answer", "events", "usage", "evidence_ref"), "attempt")
        if attempt["outcome"] not in OUTCOMES:
            raise ValueError("unknown outcome")
        if attempt["answer"] is not None and not isinstance(attempt["answer"], str):
            raise ValueError("answer must be text or unknown")
        _ref(attempt["evidence_ref"])
        if not isinstance(attempt["events"], list):
            raise ValueError("events must be a list")
        for event in attempt["events"]:
            _fields(event, ("tool", "request", "result"), "event")
            _text(event["tool"], "tool")
            if not isinstance(event["request"], bytes) or not isinstance(event["result"], bytes):
                raise ValueError("tool request and result must be bytes")
        _fields(attempt["usage"], ("input_tokens", "output_tokens", "read_count", "complete"), "usage")
        for name in ("input_tokens", "output_tokens", "read_count"):
            count = attempt["usage"][name]
            if count is not None and (type(count) is not int or count < 0):
                raise ValueError(f"invalid {name}")
        if type(attempt["usage"]["complete"]) is not bool:
            raise ValueError("usage completeness must be boolean")
    return {"schema_version": "trial-run-1", "run_id": spec["run_id"],
            "task_id": spec["task_id"], "arm": spec["arm"], "model": spec["model"],
            "effort": spec["effort"], "harness_version": spec["harness_version"],
            "attempts": deepcopy(attempts)}


def grade(task, answer, evidence):
    """Grade structured independent judgments, never infer them from model text."""
    task = validate_task(task)
    if answer is not None and not isinstance(answer, str):
        raise ValueError("answer must be text or unknown")
    _fields(evidence, ("criteria", "controls"), "evidence")
    results = []
    for group, source in (("criteria", task["rubric"]), ("controls", task["controls"])):
        supplied = evidence[group]
        if not isinstance(supplied, dict) or not set(supplied) <= {x["id"] for x in source}:
            raise ValueError(f"{group}: unknown criterion")
        for item in source:
            judgment = supplied.get(item["id"])
            if judgment is None:
                results.append({"group": group, "id": item["id"], "passed": None})
                continue
            _fields(judgment, ("passed", "basis", "evidence_ref"), "judgment")
            if type(judgment["passed"]) is not bool or judgment["basis"] != item["basis"]:
                raise ValueError("judgment requires boolean and task basis")
            _ref(judgment["evidence_ref"])
            results.append({"group": group, "id": item["id"], **deepcopy(judgment)})
    passed = sum(x["passed"] is True for x in results)
    failed = sum(x["passed"] is False for x in results)
    skipped = len(results) - passed - failed
    # Missing answer or evidence cannot be converted to a successful verdict.
    outcome = "incorrect" if failed else "unknown" if skipped or answer is None else "success"
    return {"outcome": outcome, "attempted": len(results), "completed": passed + failed,
            "passed": passed, "failed": failed, "skipped": skipped, "results": results}
