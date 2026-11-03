"""Build pinned minimal standard FFmpeg plus the in-process decoder C ABI."""
import hashlib
import json
import os
from pathlib import Path
import platform
import shutil
import subprocess
import tarfile
import urllib.request

ROOT = Path(__file__).resolve().parent.parent


def run(*args, cwd=None):
    subprocess.run(args, cwd=cwd, check=True)


def main():
    if platform.system() != 'Darwin' or platform.machine() != 'arm64':
        raise SystemExit('This decoder build targets macOS arm64')
    spec = ROOT / 'native/ffmpeg'
    manifest = json.loads((spec / 'upstream.json').read_text())
    vendor = ROOT / '.local/vendor'
    vendor.mkdir(parents=True, exist_ok=True)
    archive = vendor / ('ffmpeg-' + manifest['version'] + '.tar.xz')
    if not archive.exists():
        archive.write_bytes(urllib.request.urlopen(manifest['archive'], timeout=60).read())
    if hashlib.sha256(archive.read_bytes()).hexdigest() != manifest['archiveSha256']:
        raise SystemExit('Pinned FFmpeg archive identity changed')
    source = vendor / ('ffmpeg-' + manifest['version'])
    if not (source / 'configure').exists():
        with tarfile.open(archive) as package:
            package.extractall(vendor, filter='data')
    build = ROOT / '.local/ffmpeg-build'
    build.mkdir(parents=True, exist_ok=True)
    configuration = [str(source / 'configure'), '--disable-everything', '--disable-programs',
        '--disable-doc', '--disable-debug', '--disable-network', '--disable-autodetect',
        '--disable-avdevice', '--disable-avfilter', '--disable-swscale',
        '--disable-audiotoolbox', '--disable-videotoolbox', '--disable-shared', '--enable-static',
        '--enable-pic', '--enable-small', '--enable-avformat', '--enable-avcodec', '--enable-avutil',
        '--enable-swresample', '--enable-protocol=file', '--enable-demuxer=ogg,mp3,mov,aac,flac,wav',
        '--enable-decoder=vorbis,aac,mp3float,flac,pcm_s16le',
        '--enable-parser=vorbis,aac,mpegaudio,flac', '--arch=aarch64', '--target-os=darwin',
        '--cc=/usr/bin/clang', '--extra-cflags=-mmacosx-version-min=13.0',
        '--extra-ldflags=-mmacosx-version-min=13.0']
    config_file = build / 'spotify-configuration.json'
    if not config_file.exists() or json.loads(config_file.read_text()) != configuration:
        run(*configuration, cwd=build)
        config_file.write_text(json.dumps(configuration, indent=2) + '\n')
    libraries = ['libavformat/libavformat.a', 'libavcodec/libavcodec.a',
        'libswresample/libswresample.a', 'libavutil/libavutil.a']
    run('make', '-j' + str(min(os.cpu_count() or 4, 10)), *libraries, cwd=build)
    destination = ROOT / '.local/native'
    destination.mkdir(parents=True, exist_ok=True)
    # Cache the public link inputs, without the vendor source or Make build tree.
    sdk = destination / 'ffmpeg-static'
    if sdk.exists():
        shutil.rmtree(sdk)
    run('make', 'install-libs', 'install-headers', 'prefix=' + str(sdk), cwd=build)
    library = destination / 'libspotify_ffmpeg.dylib'
    run('xcrun', 'clang', '-dynamiclib', '-O2', '-fvisibility=hidden', '-arch', 'arm64',
        '-mmacosx-version-min=13.0', '-I' + str(build), '-I' + str(source), str(spec / 'decoder.c'),
        *[str(build / name) for name in libraries], '-lm',
        '-Wl,-install_name,@rpath/libspotify_ffmpeg.dylib',
        '-Wl,-exported_symbol,_spotify_ffmpeg_decode_file', '-Wl,-exported_symbol,_spotify_ffmpeg_version',
        '-Wl,-exported_symbol,_spotify_ffmpeg_decode_file_cancellable',
        '-Wl,-exported_symbol,_spotify_ffmpeg_cancellation_create',
        '-Wl,-exported_symbol,_spotify_ffmpeg_cancellation_request',
        '-Wl,-exported_symbol,_spotify_ffmpeg_cancellation_destroy',
        '-o', str(library))
    run('/usr/bin/codesign', '--force', '--sign', '-', '--timestamp=none', str(library))
    (destination / 'LICENSE.ffmpeg').write_bytes((source / 'COPYING.LGPLv2.1').read_bytes())
    (destination / 'ffmpeg-build.json').write_text(json.dumps({**manifest,
        'configuration': configuration, 'librarySha256': hashlib.sha256(library.read_bytes()).hexdigest(),
        'decoderSourceSha256': hashlib.sha256((spec / 'decoder.c').read_bytes()).hexdigest()}, indent=2) + '\n')
    print(library, flush=True)


if __name__ == '__main__':
    main()
