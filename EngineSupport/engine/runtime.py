"""Configured native executables, portable staging, and one PDFium worker."""

from concurrent.futures import ThreadPoolExecutor
from contextlib import contextmanager
from pathlib import Path
import hashlib
import os
import tempfile

from .errors import EngineError

# Shared across Engine instances: PDFium calls never overlap or switch workers.
WORKER = ThreadPoolExecutor(max_workers=1, thread_name_prefix="zpdf-engine")


def qpdf_binary(configured=None):
    value = configured or os.environ.get("QPDF_BIN")
    if value:
        path = Path(value).expanduser().resolve()
    else:
        name = "qpdf.exe" if os.name == "nt" else "qpdf"
        path = Path(__file__).parent / "native" / name
    if not path.is_file():
        raise EngineError("DEPENDENCY_UNAVAILABLE", "Configure QPDF_BIN or package engine/native/qpdf[.exe].")
    return path


@contextmanager
def staging(directory, suffix=".pdf"):
    # mkstemp is closed before any native library/process accesses the path.
    fd, name = tempfile.mkstemp(prefix="zpdf-", suffix=suffix, dir=directory)
    os.close(fd)
    path = Path(name)
    try:
        yield path
    finally:
        # Cleanup must not turn a committed save into a reported failure. A
        # locked leftover can be removed later; it never becomes authoritative.
        try:
            path.unlink(missing_ok=True)
        except OSError:
            pass


def digest(path):
    h = hashlib.sha256()
    with Path(path).open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            h.update(block)
    return h.hexdigest()


def identity(path):
    st = Path(path).stat()
    return (st.st_dev, st.st_ino, st.st_size, st.st_mtime_ns, digest(path))


def install(staged, destination, overwrite):
    if overwrite:
        os.replace(staged, destination)
    else:
        # Atomic create-if-absent on Windows and macOS local filesystems.
        # No fallback to check-then-replace or partially copying a destination.
        try:
            os.link(staged, destination)
        except FileExistsError as exc:
            raise EngineError("DESTINATION_EXISTS", "Destination already exists.") from exc
        # The staging context removes the extra link after successful install.
