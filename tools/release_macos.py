"""Build/install the release, stopping the installed app before replacement."""
import argparse
import fcntl
import os
from pathlib import Path
import plistlib
import signal
import shutil
import subprocess
import tempfile
import time

import run_flutter

ROOT = Path(__file__).resolve().parent.parent
APP = 'spotify_flutter.app'
BUNDLE_ID = 'dev.meoyawn.spotifyFlutter'
RELEASE = ROOT / 'build/macos/Build/Products/Release' / APP
REGISTER = Path('/System/Library/Frameworks/CoreServices.framework/Frameworks/'
    'LaunchServices.framework/Support/lsregister')


def run(*command):
    subprocess.run([str(arg) for arg in command], cwd=ROOT, check=True)


def bundle_info(bundle):
    with (bundle / 'Contents/Info.plist').open('rb') as source:
        info = plistlib.load(source)
    if info.get('CFBundleIdentifier') != BUNDLE_ID:
        raise RuntimeError(f'Refusing a bundle with a different identity: {bundle}')
    return info


def verify(bundle):
    info = bundle_info(bundle)
    required = ['MacOS/' + info['CFBundleExecutable'],
        'Frameworks/App.framework/App', 'Frameworks/FlutterMacOS.framework/FlutterMacOS',
        'Frameworks/libquiche.dylib', 'Frameworks/libnghttp3.dylib', 'Frameworks/libspotify_ffmpeg.dylib',
        'Frameworks/libspotify_streaming.dylib', 'Resources/AppIcon.icns']
    for relative in required:
        if not (bundle / 'Contents' / relative).is_file():
            raise RuntimeError(f'Incomplete release bundle: missing {relative}')
    run('/usr/bin/codesign', '--verify', '--deep', '--strict', bundle)


def release_pids(bundle):
    executable = bundle / 'Contents/MacOS' / bundle_info(bundle)['CFBundleExecutable']
    return [pid for pid, command in run_flutter.processes('pid=,comm=')
        if Path(command) == executable]


def require_stopped(bundle):
    pids = release_pids(bundle)
    if pids:
        raise RuntimeError(f'Release still running as PID(s) {pids}; no bundle was replaced.')


def launcher(*arguments):
    run('uv', 'run', '--project', 'tools/oracles', '--locked', 'python',
        'tools/run_flutter.py', *arguments)


def stop_release(bundle, pids):
    print(f'Stopping release PID(s): {pids}', flush=True)
    for pid in pids:
        # Recheck executable identity immediately before signalling. Never
        # terminate the debug app or an unrelated reused PID.
        if pid not in release_pids(bundle):
            continue
        try:
            os.kill(pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
    deadline = time.monotonic() + 15
    while release_pids(bundle):
        if time.monotonic() >= deadline:
            require_stopped(bundle)
        time.sleep(0.1)
    print('Release app process exited.', flush=True)


def install(applications):
    verify(RELEASE)
    applications = applications.expanduser().resolve()
    applications.mkdir(parents=True, exist_ok=True)
    destination = applications / APP
    if destination.is_symlink():
        raise RuntimeError(f'Refusing to replace a symlink: {destination}')
    temporary = Path(tempfile.mkdtemp(prefix='.spotify-flutter-install-', dir=applications))
    staged, previous = temporary / APP, temporary / 'previous.app'
    succeeded = False
    try:
        run('/usr/bin/ditto', RELEASE, staged)
        verify(staged)
        launcher('--status')
        # Serialize stop/swap with the same lock used by every app launch.
        with (ROOT / '.local/run/launch.lock').open('a') as launch_lock:
            fcntl.flock(launch_lock, fcntl.LOCK_EX)
            if len(run_flutter.app_pids()) > 1 or len(run_flutter.flutter_pids()) > 1:
                raise RuntimeError('Multiple app/supervisor processes exist; refusing to reinstall.')
            if destination.exists():
                pids = release_pids(destination)
                if pids:
                    stop_release(destination, pids)
                require_stopped(destination)
                destination.rename(previous)
            try:
                staged.rename(destination)
                verify(destination)
            except BaseException:
                if destination.exists():
                    destination.rename(staged)
                if previous.exists():
                    previous.rename(destination)
                raise
        succeeded = True
        result = subprocess.run([str(REGISTER), '-f', str(destination)])
        if result.returncode:
            print('Installed successfully; Launch Services registration could not be refreshed.')
        print(f'Installed release: {destination}', flush=True)
    finally:
        if succeeded or not previous.exists():
            shutil.rmtree(temporary)
        else:
            print(f'Previous installation retained at {previous}', flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=['build', 'install'])
    parser.add_argument('--applications-dir', type=Path, default=Path('/Applications'))
    args = parser.parse_args()
    lock_path = ROOT / '.local/run/macos-release.lock'
    lock_path.parent.mkdir(parents=True, exist_ok=True)
    with lock_path.open('a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        if args.action == 'build':
            run('flutter', 'build', 'macos', '--release')
            verify(RELEASE)
            print(f'Built release: {RELEASE}', flush=True)
        else:
            install(args.applications_dir)


if __name__ == '__main__':
    main()
