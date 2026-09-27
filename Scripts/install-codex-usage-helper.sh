#!/bin/bash
# Explicitly installs/enables the user LaunchAgent; never run implicitly from app launch.
set -euo pipefail
umask 077
app_path=''
codex_path=''
python_path=''
while [[ $# -gt 0 ]]; do
  case "$1" in
    --app|--codex|--python)
      [[ $# -ge 2 ]] || { echo 'install-codex-usage-helper: missing-argument' >&2; exit 2; }
      case "$1" in
        --app) app_path="$2" ;;
        --codex) codex_path="$2" ;;
        --python) python_path="$2" ;;
      esac
      shift 2 ;;
    --help)
      echo 'Usage: install-codex-usage-helper.sh --app /absolute/MoriSpace.app --codex /absolute/codex [--python /absolute/python3]'
      exit 0 ;;
    *) echo 'install-codex-usage-helper: unknown-argument' >&2; exit 2 ;;
  esac
done
[[ -n "$app_path" && -n "$codex_path" ]] || { echo 'install-codex-usage-helper: missing-argument' >&2; exit 2; }
if [[ -z "$python_path" ]]; then python_path="$(command -v python3 || true)"; fi
[[ "$python_path" = /* && -x "$python_path" ]] || { echo 'install-codex-usage-helper: python-unavailable' >&2; exit 1; }
script_directory="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
"$python_path" -I - "$app_path" "$codex_path" "$python_path" "$script_directory/codex-usage-helper.py" <<'PY'
import os
from pathlib import Path
import plistlib
import re
import subprocess
import sys
import tempfile

LABEL = 'dev.kylon.MoriSpace.usage-helper'
MARKER = 'mori-usage-helper-v1'

class InstallError(Exception): pass

def require(test, category):
    if not test: raise InstallError(category)

def managed_directory(path, create=False):
    require(path.resolve() == path, 'unsafe-path')
    if create: path.mkdir(mode=0o700, parents=True, exist_ok=True)
    require(path.is_dir() and path.stat().st_uid == os.getuid(), 'unsafe-directory')

def atomic(path, data, mode=0o600):
    require(not path.is_symlink(), 'unsafe-path')
    fd, temporary = tempfile.mkstemp(prefix='.mori-usage-', dir=path.parent)
    try:
        os.fchmod(fd, mode)
        with os.fdopen(fd, 'wb') as handle:
            handle.write(data); handle.flush(); os.fsync(handle.fileno())
        os.replace(temporary, path)
    finally:
        try: os.unlink(temporary)
        except FileNotFoundError: pass

def command(arguments):
    return subprocess.run(arguments, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=15)

try:
    require(sys.platform == 'darwin' and os.getuid() != 0, 'requires-mac-user-session')
    require(sys.version_info >= (3, 9), 'python-version')
    app, codex, python, source = map(Path, sys.argv[1:])
    require(app.is_absolute() and app.suffix == '.app' and app.is_dir(), 'invalid-app')
    require(codex.is_absolute() and codex.is_file() and os.access(codex, os.X_OK), 'invalid-codex')
    require(python.is_absolute() and python.is_file() and os.access(python, os.X_OK), 'invalid-python')
    require(source.is_file(), 'missing-helper-source')
    require(command(['/usr/bin/codesign', '--verify', '--deep', '--strict', str(app)]).returncode == 0, 'invalid-signature')
    info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
    group = info.get('MoriCalendarAppGroup')
    require(isinstance(group, str) and re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9.-]{1,200}', group), 'invalid-app-group')
    signature = subprocess.run(['/usr/bin/codesign', '-d', '--entitlements', ':-', str(app)],
                               stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=15)
    require(signature.returncode == 0, 'invalid-entitlements')
    entitlements = plistlib.loads(signature.stdout)
    require(group in entitlements.get('com.apple.security.application-groups', []), 'unsigned-app-group')
    home = Path.home().resolve()
    launch_agents = home / 'Library/LaunchAgents'
    managed_directory(launch_agents, create=True)
    support = home / 'Library/Application Support/MoriSpaceUsage'
    managed_directory(support, create=True)
    marker = support / '.installed-by-mori-usage'
    if any(support.iterdir()):
        require(marker.is_file() and not marker.is_symlink() and marker.read_text() == MARKER, 'unowned-helper-directory')
    # macOS protects signed apps' Group Containers from an unsigned interpreter.
    # Keep this helper's sanitized cache in its own user-owned support directory;
    # the signed app/widget fetch it through the loopback-only read-only endpoint.
    output = support / 'usage-widget-v1.json'
    require(not output.is_symlink() and (not output.exists() or output.is_file()), 'unsafe-output')
    helper = support / 'codex-usage-helper.py'
    agent = launch_agents / (LABEL + '.plist')
    if agent.exists():
        require(not agent.is_symlink(), 'unsafe-agent')
        previous = plistlib.loads(agent.read_bytes())
        require(previous.get('Label') == LABEL and str(helper) in previous.get('ProgramArguments', []), 'unowned-agent')
    log = support / 'error.log'
    require(not log.is_symlink(), 'unsafe-log')
    require(not log.exists() or (log.is_file() and log.stat().st_uid == os.getuid()), 'unsafe-log')
    payload = {
        'Label': LABEL,
        'ProgramArguments': [str(python), '-I', str(helper), '--serve', '--port', '48763', '--codex', str(codex), '--output', str(output)],
        'WorkingDirectory': str(support),
        'EnvironmentVariables': {'PATH': str(codex.parent) + ':/usr/bin:/bin:/usr/sbin:/sbin'},
        'RunAtLoad': True, 'KeepAlive': True, 'ThrottleInterval': 30,
        'ProcessType': 'Background', 'LowPriorityIO': True,
        'StandardOutPath': '/dev/null', 'StandardErrorPath': str(log),
    }
    # Validate all inputs before changing the managed installation. Other app-group
    # files (calendar data, widgets, settings) and Codex login state are untouched.
    atomic(marker, MARKER.encode())
    with log.open('ab'):
        os.chmod(log, 0o600)
    atomic(helper, source.read_bytes(), mode=0o700)
    atomic(agent, plistlib.dumps(payload))
    domain = 'gui/' + str(os.getuid())
    service = domain + '/' + LABEL
    command(['/bin/launchctl', 'bootout', service])
    require(command(['/bin/launchctl', 'print', service]).returncode != 0, 'previous-job-still-running')
    require(command(['/bin/launchctl', 'bootstrap', domain, str(agent)]).returncode == 0, 'launch-agent-load-failed')
    require(command(['/bin/launchctl', 'print', service]).returncode == 0, 'launch-agent-not-loaded')
    print('Codex usage helper installed. Local-only service refreshes every 5 minutes while this Mac is logged in.')
except InstallError as error:
    print('install-codex-usage-helper: ' + str(error), file=sys.stderr)
    sys.exit(1)
except Exception:
    print('install-codex-usage-helper: local-failure', file=sys.stderr)
    sys.exit(1)
PY
