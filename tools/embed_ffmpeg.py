"""Embed the standard finite and streaming FFmpeg libraries in the Flutter app."""
import os
from pathlib import Path
import shutil
import subprocess

root = Path(__file__).resolve().parent.parent
sources = [root / '.local/native/libspotify_ffmpeg.dylib',
    root / '.local/native/libspotify_streaming.dylib']
for source in sources:
    if not source.exists():
        raise SystemExit('Build the standard audio primitives first: uv run --project tools/oracles --locked python tools/build_ffmpeg.py; then uv run --project tools/oracles --locked python tools/build_streaming_audio.py')
target = Path(os.environ['TARGET_BUILD_DIR'])
frameworks = target / os.environ['FRAMEWORKS_FOLDER_PATH']
frameworks.mkdir(parents=True, exist_ok=True)
for source in sources:
    embedded = frameworks / source.name
    copied = not embedded.exists() or source.read_bytes() != embedded.read_bytes()
    if copied:
        shutil.copyfile(source, embedded)
    if copied and os.environ.get('CODE_SIGNING_ALLOWED') != 'NO':
        identity = os.environ.get('EXPANDED_CODE_SIGN_IDENTITY') or '-'
        subprocess.run(['/usr/bin/codesign', '--force', '--sign', identity,
            '--timestamp=none', str(embedded)], check=True)
licenses = target / os.environ['UNLOCALIZED_RESOURCES_FOLDER_PATH'] / 'Licenses/ffmpeg'
licenses.mkdir(parents=True, exist_ok=True)
for source in (root / '.local/native/LICENSE.ffmpeg', root / '.local/native/ffmpeg-build.json',
        root / '.local/native/streaming-build.json', root / 'native/ffmpeg/upstream.json'):
    shutil.copyfile(source, licenses / source.name)
