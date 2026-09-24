#!/usr/bin/env python3
"""Install repository privacy checks in this clone (requires gitleaks)."""
from pathlib import Path
import shutil
import subprocess

root = Path(__file__).resolve().parents[1]
if not shutil.which('gitleaks'):
    raise SystemExit('Install gitleaks first: brew install gitleaks')
existing = subprocess.run(['git', 'config', '--get', 'core.hooksPath'], cwd=root,
                          capture_output=True, text=True).stdout.strip()
if existing and existing != '.githooks':
    raise SystemExit('Existing custom hooks found; integrate privacy checks without replacing them.')
for name in ('pre-commit', 'pre-push'):
    (root / '.githooks' / name).chmod(0o755)
subprocess.run(['git', 'config', '--local', 'core.hooksPath', '.githooks'], cwd=root, check=True)
subprocess.run(['git', 'config', '--local', 'push.default', 'simple'], cwd=root, check=True)
print('Privacy hooks installed. Use a GitHub noreply address in this clone.')
