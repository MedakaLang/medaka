"""Pure validation of private worker protocol records and serial exchanges."""
from copy import deepcopy

VERSION = 1
IDENTITIES = {"workspace", "toolchain", "snapshot", "profile"}


def obj(value, fields):
    if not isinstance(value, dict) or set(value) != set(fields):
        raise ValueError("unexpected object fields")


def text(value):
    if not isinstance(value, str) or not value.strip():
        raise ValueError("expected nonempty text")


def identity(value):
    obj(value, {"value", "provenance"})
    if value["provenance"] not in ("attested", "inferred", "unavailable"):
        raise ValueError("invalid identity provenance")
    if value["provenance"] == "unavailable":
        if value["value"] is not None:
            raise ValueError("unavailable identity has a value")
    else:
        text(value["value"])


def validate_sequence(messages):
    """Validate a complete serial session; never establish identity truth from a label."""
    seen, pending = set(), None
    initialized = False
    offered = None
    worker = None
    replacing = None
    closed = False
    for msg in messages:
        if not isinstance(msg, dict) or closed:
            raise ValueError("invalid or closed session")
        kind = msg.get("type")
        if kind == "initialize":
            obj(msg, {"type", "versions"})
            if offered is not None or not isinstance(msg["versions"], list) or not msg["versions"] or any(type(v) is not int or v < 1 for v in msg["versions"]) or len(set(msg["versions"])) != len(msg["versions"]):
                raise ValueError("invalid version offer")
            offered = msg["versions"]
        elif kind == "initialized":
            obj(msg, {"type", "version", "capabilities", "worker", "error"})
            if offered is None or initialized or worker is not None:
                raise ValueError("unexpected initialized")
            if msg["error"] is not None:
                text(msg["error"])
                if msg["version"] is not None or msg["capabilities"] != [] or msg["worker"] is not None:
                    raise ValueError("invalid negotiation refusal")
                closed = True
                continue
            if type(msg["version"]) is not int or msg["version"] != VERSION or msg["version"] not in offered:
                raise ValueError("incompatible private version")
            if not isinstance(msg["capabilities"], list) or any(not isinstance(c, str) or not c.strip() for c in msg["capabilities"]) or len(set(msg["capabilities"])) != len(msg["capabilities"]):
                raise ValueError("invalid capabilities")
            text(msg["worker"])
            worker, initialized = msg["worker"], True
        elif kind in ("request", "replace"):
            fields = {"type", "id", "context", "operation"} if kind == "request" else {"type", "id", "artifact"}
            obj(msg, fields)
            if not initialized or pending is not None:
                raise ValueError("session not ready or request in flight")
            text(msg["id"])
            if msg["id"] in seen:
                raise ValueError("duplicate request id")
            seen.add(msg["id"])
            if kind == "request":
                obj(msg["context"], IDENTITIES)
                for item in msg["context"].values():
                    identity(item)
                obj(msg["operation"], {"name", "arguments"})
                text(msg["operation"]["name"])
                if not isinstance(msg["operation"]["arguments"], dict):
                    raise ValueError("invalid arguments")
            else:
                obj(msg["artifact"], {"id", "digest"})
                text(msg["artifact"]["id"])
                text(msg["artifact"]["digest"])
                replacing = msg["artifact"]["id"]
            pending = (kind, msg["id"])
        elif kind == "response":
            obj(msg, {"type", "id", "status", "result", "error"})
            if pending != ("request", msg["id"]) or msg["status"] not in ("complete", "partial", "error"):
                raise ValueError("unexpected response")
            if msg["status"] == "error":
                text(msg["error"])
                if msg["result"] is not None:
                    raise ValueError("error has result")
            elif msg["error"] is not None or msg["result"] is None:
                raise ValueError("response needs result only")
            pending = None
        elif kind == "replacement":
            obj(msg, {"type", "id", "status", "worker", "error"})
            if pending != ("replace", msg["id"]) or msg["status"] not in ("switched", "failed"):
                raise ValueError("unexpected replacement")
            if msg["status"] == "failed":
                text(msg["error"])
                if msg["worker"] != worker:
                    raise ValueError("failed replacement changed worker")
            else:
                if msg["error"] is not None or msg["worker"] != replacing:
                    raise ValueError("invalid replacement switch")
                worker = replacing
            pending, replacing = None, None
        elif kind == "shutdown":
            obj(msg, {"type"})
            if not initialized or pending is not None:
                raise ValueError("shutdown while not ready")
            closed = True
        else:
            raise ValueError("unknown message")
    if not closed or pending is not None:
        raise ValueError("incomplete session")
    return deepcopy(messages)
