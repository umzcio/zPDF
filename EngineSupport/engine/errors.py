"""Errors crossing the engine boundary contain plain data only."""


class EngineError(Exception):
    def __init__(self, code, message, diagnostics=None):
        super().__init__(message)
        self.code = code
        self.message = message
        self.diagnostics = diagnostics or []


def require(condition, code, message):
    if not condition:
        raise EngineError(code, message)
