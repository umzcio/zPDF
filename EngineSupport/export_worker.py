"""App-owned launcher; the versioned exporter below is an unchanged snapshot."""
import os
import resource
import sys
import threading
import time
from pathlib import Path

# Hard bounds supplement the app's input/page limits and wall-clock deadline.
resource.setrlimit(resource.RLIMIT_CPU, (900, 900))
resource.setrlimit(resource.RLIMIT_FSIZE, (1024 * 1024 * 1024, 1024 * 1024 * 1024))
resource.setrlimit(resource.RLIMIT_NOFILE, (256, 256))
def memory_watchdog():
    while True:
        # macOS reports ru_maxrss in bytes. Stop a runaway decoder before it
        # exhausts the machine; the app owns cleanup and never publishes it.
        if resource.getrusage(resource.RUSAGE_SELF).ru_maxrss > 3 * 1024**3:
            os._exit(70)
        time.sleep(0.2)
threading.Thread(target=memory_watchdog, daemon=True).start()
sys.path.insert(0, str(Path(__file__).parent / "exporter"))
from zpdf_export.worker import Worker
Worker().run()
