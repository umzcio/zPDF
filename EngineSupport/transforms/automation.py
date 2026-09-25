"""Action Wizard support: run a step whose "nothing to do" outcome is not an
error (e.g. flatten layers on a document without layers)."""
from engine.errors import EngineError, require
from transforms import op, REGISTRY

# Errors that mean "this step doesn't apply to this document".
NOT_APPLICABLE = {"NO_LAYERS", "NO_HEADINGS", "ALREADY_TAGGED", "NOT_TAGGED"}


@op("optional")
def optional(ctx, step, skip=None):
    """Runs `step` ({"op": ..., params}); listed error codes are skipped, not fatal."""
    require(isinstance(step, dict) and step.get("op") in REGISTRY and step.get("op") != "optional",
            "UNSUPPORTED_OPERATION", "Unknown document operation in an optional step.")
    codes = set(skip) if skip else NOT_APPLICABLE
    params = {k: v for k, v in step.items() if k != "op"}
    try:
        result = REGISTRY[step["op"]](ctx, **params)
    except EngineError as exc:
        if exc.code in codes:
            return {"skipped": True, "step": step["op"], "reason": exc.message}
        raise
    except TypeError as exc:
        raise EngineError("INVALID_ARGUMENT", f"Invalid parameters for {step['op']}.") from exc
    return {"skipped": False, "step": step["op"], **(result or {})}
