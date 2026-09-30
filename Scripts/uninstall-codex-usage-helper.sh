#!/bin/bash
set -euo pipefail
umask 077
if [[ "${1:-}" == '--help' ]]; then
  echo 'Usage: uninstall-codex-usage-helper.sh [--python /absolute/python3]'
  exit 0
fi
python_path=''
if [[ $# -eq 2 && "$1" == '--python' ]]; then
  python_path="$2"
elif [[ $# -eq 0 ]]; then
  python_path="$(command -v python3 || true)"
else
  echo 'uninstall-codex-usage-helper: invalid-argument' >&2; exit 2
fi
[[ "$python_path" = /* && -x "$python_path" ]] || { echo 'uninstall-codex-usage-helper: python-unavailable' >&2; exit 1; }
"$python_path" -I - <<'PY'
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import time

LABEL = 'dev.kylon.MoriSpace.usage-helper'
MARKER = 'mori-usage-helper-v1'

class UninstallError(Exception): pass

def require(test, category):
    if not test: raise UninstallError(category)

def command(arguments):
    return subprocess.run(arguments, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=15)

try:
    require(sys.platform == 'darwin' and os.getuid() != 0, 'requires-mac-user-session')
    home = Path.home().resolve()
    support = home / 'Library/Application Support/MoriSpaceUsage'
    agent = home / 'Library/LaunchAgents' / (LABEL + '.plist')
    helper = support / 'codex-usage-helper.py'
    require(support.resolve() == support and agent.resolve() == agent, 'unsafe-path')
    if support.exists():
        marker = support / '.installed-by-mori-usage'
        require(support.is_dir() and support.stat().st_uid == os.getuid(), 'unsafe-directory')
        require(marker.is_file() and not marker.is_symlink() and marker.read_text() == MARKER, 'unowned-helper-directory')
    if agent.exists():
        require(agent.is_file() and agent.stat().st_uid == os.getuid(), 'unsafe-agent')
        previous = plistlib.loads(agent.read_bytes())
        require(previous.get('Label') == LABEL and str(helper) in previous.get('ProgramArguments', []), 'unowned-agent')
    service = 'gui/' + str(os.getuid()) + '/' + LABEL
    command(['/bin/launchctl', 'bootout', service])
    # launchctl may briefly keep the job visible while its process exits.
    for _ in range(20):
        if command(['/bin/launchctl', 'print', service]).returncode != 0: break
        time.sleep(0.1)
    else: raise UninstallError('job-still-running')
    if agent.exists(): agent.unlink()
    if support.exists(): shutil.rmtree(support)
    # Remove this helper's local quota cache and optional private relay config
    # together with its owned support folder. No other service config is touched.
    # Do not open/remove the App Group or touch Codex credentials/settings/calendars.
    print('Codex usage helper removed. Codex login and Mori Space data were preserved.')
except UninstallError as error:
    print('uninstall-codex-usage-helper: ' + str(error), file=sys.stderr)
    sys.exit(1)
except Exception:
    print('uninstall-codex-usage-helper: local-failure', file=sys.stderr)
    sys.exit(1)
PY
