#!/bin/bash
# Explicit opt-in. Secrets are read from a private file, never command arguments.
set -euo pipefail
umask 077
config_file=''
python_path=''
while [[ $# -gt 0 ]]; do
  case "$1" in
    --config-file|--python)
      [[ $# -ge 2 ]] || { echo 'configure-codex-usage-relay: missing-argument' >&2; exit 2; }
      case "$1" in
        --config-file) config_file="$2" ;;
        --python) python_path="$2" ;;
      esac
      shift 2 ;;
    --help)
      echo 'Usage: configure-codex-usage-relay.sh --config-file /absolute/private-config.json [--python /absolute/python3]'
      echo 'The input must be a user-owned regular file with mode 0600; the helper must already be installed.'
      exit 0 ;;
    *) echo 'configure-codex-usage-relay: unknown-argument' >&2; exit 2 ;;
  esac
done
[[ "$config_file" = /* ]] || { echo 'configure-codex-usage-relay: invalid-config-path' >&2; exit 2; }
if [[ -z "$python_path" ]]; then python_path="$(command -v python3 || true)"; fi
[[ "$python_path" = /* && -x "$python_path" ]] || { echo 'configure-codex-usage-relay: python-unavailable' >&2; exit 1; }
"$python_path" -I - "$config_file" <<'PY'
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import stat
import subprocess
import sys
import tempfile

LABEL = 'dev.kylon.MoriSpace.usage-helper'
MARKER = 'mori-usage-helper-v1'

class ConfigureError(Exception): pass

def require(test, category):
    if not test: raise ConfigureError(category)

def owned_file(path, maximum, private=False):
    require(path.is_absolute() and path.resolve() == path, 'unsafe-path')
    metadata = path.lstat()
    require(stat.S_ISREG(metadata.st_mode) and metadata.st_uid == os.getuid()
            and metadata.st_size <= maximum and not metadata.st_mode & 0o022, 'unsafe-file')
    if private:
        require(stat.S_IMODE(metadata.st_mode) == 0o600, 'unsafe-file')
    return path

def command(arguments):
    return subprocess.run(arguments, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=15)

try:
    require(sys.platform == 'darwin' and os.getuid() != 0, 'requires-mac-user-session')
    require(sys.version_info >= (3, 9), 'python-version')
    support = Path.home().resolve() / 'Library/Application Support/MoriSpaceUsage'
    require(support.resolve() == support and support.is_dir(), 'helper-not-installed')
    metadata = support.stat()
    require(metadata.st_uid == os.getuid() and not metadata.st_mode & 0o022, 'unsafe-directory')
    marker = owned_file(support / '.installed-by-mori-usage', 128, private=True)
    require(marker.read_text() == MARKER, 'unowned-helper-directory')
    helper = owned_file(support / 'codex-usage-helper.py', 1024 * 1024)
    agent = owned_file(Path.home().resolve() / 'Library/LaunchAgents' / (LABEL + '.plist'), 65_536, private=True)
    previous = plistlib.loads(agent.read_bytes())
    arguments = previous.get('ProgramArguments', [])
    require(previous.get('Label') == LABEL and isinstance(arguments, list)
            and str(helper) in arguments and '--serve' in arguments, 'unowned-agent')
    service = 'gui/' + str(os.getuid()) + '/' + LABEL
    require(command(['/bin/launchctl', 'print', service]).returncode == 0, 'helper-not-running')
    # Only our validated, installed helper is imported. It has no import-time
    # network effects and does not read Codex login state or App Group files.
    spec = importlib.util.spec_from_file_location('mori_usage_relay_config', helper)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    require(hasattr(module, 'read_relay_config'), 'helper-update-required')
    value = module.read_relay_config(Path(sys.argv[1]), required=True)
    target = support / module.RELAY_CONFIG_NAME
    if target.exists() or target.is_symlink():
        owned_file(target, module.RELAY_CONFIG_MAX_BYTES, private=True)
    data = (json.dumps(value, separators=(',', ':'), allow_nan=False) + '\n').encode()
    descriptor, temporary = tempfile.mkstemp(prefix='.mori-usage-relay-', dir=support)
    try:
        os.fchmod(descriptor, 0o600)
        with os.fdopen(descriptor, 'wb') as handle:
            handle.write(data)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, target)
    finally:
        try: os.unlink(temporary)
        except FileNotFoundError: pass
    require(command(['/bin/launchctl', 'kickstart', '-k', service]).returncode == 0, 'helper-restart-failed')
    require(command(['/bin/launchctl', 'print', service]).returncode == 0, 'helper-not-running')
    print('Codex usage relay configuration saved. The helper was restarted; upload success is verified separately.')
except ConfigureError as error:
    print('configure-codex-usage-relay: ' + str(error), file=sys.stderr)
    sys.exit(1)
except Exception:
    # Parsing, HTTP, filesystem and module errors must never print file contents,
    # server addresses, token values, raw response bodies, or tracebacks.
    print('configure-codex-usage-relay: configuration-failed', file=sys.stderr)
    sys.exit(1)
PY
