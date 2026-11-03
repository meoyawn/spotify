"""Launch or reuse exactly one desktop instance of this app."""
import argparse
import fcntl
import json
import os
from pathlib import Path
import plistlib
import stat
import subprocess
import time

ROOT = Path(__file__).resolve().parent.parent
RUN = ROOT / '.local/run'


def processes(columns):
    result = subprocess.run(['ps', '-axo', columns], check=True, capture_output=True, text=True)
    rows = []
    for line in result.stdout.splitlines():
        parts = line.strip().split(None, 1)
        if len(parts) == 2:
            rows.append((int(parts[0]), parts[1]))
    return rows


def app_pids():
    return [pid for pid, command in processes('pid=,comm=')
        if Path(command).name == 'spotify_flutter']


def flutter_pids():
    found = []
    for pid, command in processes('pid=,command='):
        if 'flutter_tools.snapshot run ' not in command:
            continue
        cwd = subprocess.run(['lsof', '-a', '-p', str(pid), '-d', 'cwd', '-Fn'],
            capture_output=True, text=True)
        if f'n{ROOT}' in cwd.stdout.splitlines():
            found.append(pid)
    return found


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--status', action='store_true', help='Inspect without launching anything')
    parser.add_argument('--release', action='store_true', help='Launch the installed release instead of Flutter debug')
    parser.add_argument('--release-bundle', type=Path,
        help='Installed release bundle to launch with --release (defaults to /Applications/spotify_flutter.app)')
    args = parser.parse_args()
    if args.release_bundle is not None and not args.release:
        parser.error('--release-bundle requires --release')
    RUN.mkdir(parents=True, exist_ok=True)
    lock = os.open(RUN / 'launch.lock', os.O_CREAT | os.O_RDWR, 0o600)
    try:
        fcntl.flock(lock, fcntl.LOCK_EX)
        apps, supervisors = app_pids(), flutter_pids()
        if len(apps) > 1 or len(supervisors) > 1:
            print(json.dumps({'error': 'Multiple existing instances; stop extras before continuing',
                'app_pids': apps, 'flutter_pids': supervisors}))
            return 2
        if args.status or apps or supervisors:
            print(json.dumps({'reused': not args.status and bool(apps or supervisors),
                'app_pids': apps, 'flutter_pids': supervisors}))
            return 0
        if args.release:
            bundle = (args.release_bundle or Path('/Applications/spotify_flutter.app')).expanduser().resolve()
            with (bundle / 'Contents/Info.plist').open('rb') as source:
                info = plistlib.load(source)
            if info.get('CFBundleIdentifier') != 'dev.meoyawn.spotifyFlutter':
                raise SystemExit('Refusing a release bundle with a different application identity')
            executable = bundle / 'Contents/MacOS' / info['CFBundleExecutable']
            if not executable.is_file():
                raise SystemExit('Install the release first: moonx release-reinstall')
            child = subprocess.Popen([str(executable)], cwd=ROOT,
                stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                start_new_session=True)
            print(json.dumps({'pid': child.pid, 'mode': 'release', 'bundle': str(executable.parents[2])}))
            return 0
        fifo = RUN / 'flutter-input'
        if not fifo.exists():
            os.mkfifo(fifo, 0o600)
        if not stat.S_ISFIFO(fifo.lstat().st_mode):
            raise RuntimeError('Flutter input path must be a FIFO')
        input_fd = os.open(fifo, os.O_RDWR)
        log_path = RUN / f'flutter-{time.time_ns()}.log'
        log_fd = os.open(log_path, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
        try:
            child = subprocess.Popen(['/opt/homebrew/share/flutter/bin/flutter', 'run',
                '-d', 'macos', '--debug', '--no-pub', '--print-dtd'],
                cwd=ROOT, stdin=input_fd, stdout=log_fd, stderr=subprocess.STDOUT,
                start_new_session=True)
        finally:
            os.close(input_fd)
            os.close(log_fd)
        value = {'pid': child.pid, 'cwd': str(ROOT), 'log': str(log_path), 'input': str(fifo)}
        pending = RUN / 'supervisor.json.tmp'
        fd = os.open(pending, os.O_CREAT | os.O_TRUNC | os.O_WRONLY, 0o600)
        with os.fdopen(fd, 'w') as output:
            json.dump(value, output)
        os.replace(pending, RUN / 'supervisor.json')
        print(json.dumps(value))
        return 0
    finally:
        os.close(lock)


if __name__ == '__main__':
    raise SystemExit(main())
