"""Link the cached FFmpeg static SDK plus standard AudioQueue ABI.

This builds a separate library, leaving the existing full-file decoder intact.
Uses the repository's locked uv project and adds no Python dependencies/network.
"""
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import subprocess

ROOT = Path(__file__).resolve().parent.parent


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def run(*arguments, cwd=None):
    subprocess.run(arguments, cwd=cwd, check=True)


def main():
    if platform.system() != "Darwin" or platform.machine() != "arm64":
        raise SystemExit("This standard streaming primitive targets macOS arm64")
    spec = ROOT / "native/ffmpeg"
    manifest = json.loads((spec / "upstream.json").read_text())
    destination = ROOT / ".local/native"
    sdk = destination / "ffmpeg-static"
    provenance_path = destination / "ffmpeg-build.json"
    libraries = ["libavformat.a", "libavcodec.a", "libswresample.a", "libavutil.a"]
    if not sdk.exists() or not provenance_path.exists():
        raise SystemExit("First build the pinned standard archives: uv run --project tools/oracles --locked python tools/build_ffmpeg.py")
    ffmpeg_provenance = json.loads(provenance_path.read_text())
    if any(ffmpeg_provenance.get(key) != value for key, value in manifest.items()):
        raise SystemExit("Cached FFmpeg SDK differs from the pinned manifest")
    configuration = ffmpeg_provenance["configuration"]
    if "--disable-network" not in configuration or "--disable-shared" not in configuration:
        raise SystemExit("Existing FFmpeg configuration must disable network and use static archives")
    library = destination / "libspotify_streaming.dylib"
    temporary = destination / "libspotify_streaming.build.dylib"
    header = spec / "streaming.h"
    symbols = re.findall(r"SPOTIFY_STREAM_API\s+[^;]*?\b(spotify_stream\w+)\s*\(", header.read_text())
    if not symbols or len(symbols) != len(set(symbols)):
        raise SystemExit("Could not read a unique exported C ABI from streaming.h")
    run("xcrun", "clang", "-std=c11", "-dynamiclib", "-O2", "-Wall", "-Wextra",
        "-fvisibility=hidden", "-arch", "arm64", "-mmacosx-version-min=13.0",
        "-I" + str(sdk / "include"), str(spec / "streaming.c"),
        *[str(sdk / "lib" / name) for name in libraries], "-framework", "AudioToolbox",
        "-framework", "CoreFoundation", "-lpthread", "-lm",
        "-Wl,-install_name,@rpath/libspotify_streaming.dylib",
        *["-Wl,-exported_symbol,_" + name for name in symbols], "-o", str(temporary))
    run("/usr/bin/codesign", "--force", "--sign", "-", "--timestamp=none", str(temporary))
    os.replace(temporary, library)
    provenance = {**manifest, "configuration": configuration,
        "scope": "Standard FFmpeg custom/file I/O, decode/resample and AudioQueue PCM output primitives; no network/player/session code",
        "librarySha256": digest(library), "exportedSymbols": symbols,
        "streamingSourceSha256": digest(spec / "streaming.c"),
        "streamingHeaderSha256": digest(header), "builderSha256": digest(Path(__file__)),
        "staticArchives": [{"path": name, "sha256": digest(sdk / "lib" / name)} for name in libraries]}
    (destination / "streaming-build.json").write_text(json.dumps(provenance, indent=2) + "\n")
    print(library, flush=True)


if __name__ == "__main__":
    main()
