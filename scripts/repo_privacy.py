#!/usr/bin/env python3
"""Fail closed before commits/pushes; inspect Git blobs, never just working files."""
import hashlib
import json
from pathlib import Path, PurePosixPath
import re
import shutil
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
TOP_FILES = {'.gitignore', '.gitattributes', 'README.md', 'PRIVACY.md', 'project.yml', 'appcast.xml'}
DIRECTORIES = {'zPDF', 'zPDFTests', 'EngineSupport', 'scripts', '.githooks', 'services'}
TEXT_SUFFIXES = {'.swift', '.py', '.md', '.json', '.toml', '.plist', '.entitlements', '.txt', '.ijg', '.xsd', '.sh', '.html', '.ts', '.mjs', '.jsonc'}
PRIVATE_PARTS = {'private', 'secrets', 'build', 'deriveddata', '__pycache__', '.venv', 'venv',
                 '.codex', '.agents', '.claude', '.ssh', '.aws', '.local-data', 'xcuserdata'}
HOME_PATH = re.compile(rb'/(?:Users|home)/[A-Za-z0-9_.-]+/')
TEMP_PATH = re.compile(rb'/private/' + rb'var/folders/')
NOREPLY = re.compile(r'^(?:\d+\+)?[A-Za-z0-9-]+@users\.noreply\.github\.com$')
MANIFEST = 'scripts/public-assets.json'


def git(*args):
    return subprocess.check_output(['git', *args], cwd=ROOT)


def fail(message):
    raise SystemExit('Privacy check blocked: ' + message)


def entries(tree):
    result = {}
    for record in git('ls-tree', '-r', '-z', tree).split(b'\0'):
        if record:
            metadata, name = record.split(b'\t', 1)
            mode, kind, oid = metadata.decode().split()
            result[name.decode()] = (mode, kind, oid)
    return result


def check_tree(tree, scan_secrets=False):
    files = entries(tree)
    if MANIFEST not in files:
        fail('missing reviewed binary/fixture manifest')
    assets = json.loads(git('cat-file', 'blob', files[MANIFEST][2]))
    snapshot = tempfile.TemporaryDirectory(prefix='zpdf-publication-scan-') if scan_secrets else None
    try:
        for name, (mode, kind, oid) in files.items():
            path = PurePosixPath(name)
            if mode not in {'100644', '100755'} or kind != 'blob':
                fail(f'symlink/submodule or unsupported file mode: {name}')
            if name not in TOP_FILES and path.parts[0] not in DIRECTORIES:
                fail(f'path outside publication allowlist: {name}')
            if any(p.lower() in PRIVATE_PARTS for p in path.parts) or any(
                marker in name.lower() for marker in ('.private.', '.local.', '.env', 'credentials', '.keychain')
            ):
                fail(f'private/local path: {name}')
            data = git('cat-file', 'blob', oid)
            if name in assets:
                if hashlib.sha256(data).hexdigest() != assets[name]['sha256']:
                    fail(f'reviewed asset changed; re-audit and update manifest: {name}')
            else:
                is_hook = path.parts[0] == '.githooks' and path.name in {'pre-commit', 'pre-push'}
                if name not in TOP_FILES and not is_hook and path.suffix.lower() not in TEXT_SUFFIXES:
                    fail(f'unreviewed file type (including documents/images): {name}')
                try:
                    data.decode('utf-8')
                except UnicodeDecodeError:
                    fail(f'unreviewed binary: {name}')
                if b'\0' in data:
                    fail(f'unreviewed binary: {name}')
            if HOME_PATH.search(data) or TEMP_PATH.search(data):
                fail(f'personal home/temp path in {name}')
            if snapshot:
                target = Path(snapshot.name) / name
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_bytes(data)
        if set(assets) - set(files):
            fail('manifest lists assets absent from Git')
        if snapshot:
            subprocess.run(['gitleaks', 'dir', snapshot.name, '--redact', '--no-banner',
                            '--ignore-gitleaks-allow'], check=True, cwd=ROOT)
    finally:
        if snapshot:
            snapshot.cleanup()
    print(f'Privacy check passed: {len(files)} reviewed paths; {len(assets)} pinned assets.')


def check_identity(email):
    if not NOREPLY.fullmatch(email):
        fail('use a GitHub noreply address for author and committer metadata')


def main():
    if not shutil.which('gitleaks'):
        fail('gitleaks is required; install with brew install gitleaks')
    if len(sys.argv) != 2 or sys.argv[1] not in {'staged', 'pre-push'}:
        fail('usage: repo_privacy.py staged|pre-push')
    if sys.argv[1] == 'staged':
        for var in ('GIT_AUTHOR_IDENT', 'GIT_COMMITTER_IDENT'):
            identity = git('var', var).decode()
            check_identity(identity.split('<', 1)[1].split('>', 1)[0])
        check_tree(git('write-tree').decode().strip(), scan_secrets=True)
    else:
        seen = set()
        for line in sys.stdin:
            local_ref, oid, remote_ref, remote_oid = line.split()
            if set(oid) == {'0'}:  # ref deletion carries no content
                continue
            if local_ref.startswith('refs/heads/local/'):
                fail('local-only history must never be pushed')
            # Inspect ALL reachable history, including commits deleting private files.
            commits = git('rev-list', oid).decode().splitlines()
            for commit in commits:
                if commit in seen:
                    continue
                seen.add(commit)
                for email in git('show', '-s', '--format=%ae%n%ce', commit).decode().splitlines():
                    check_identity(email)
                check_tree(commit)
            subprocess.run(['gitleaks', 'git', '--log-opts=' + oid, '--redact',
                            '--no-banner', '--ignore-gitleaks-allow'], check=True, cwd=ROOT)


if __name__ == '__main__':
    main()
