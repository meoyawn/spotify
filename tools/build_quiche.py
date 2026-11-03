"""Build pinned quiche with the declared read-only ACK bridge; no Spotify calls."""
import hashlib
import json
import os
from pathlib import Path
import platform
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent.parent


def run(*args, cwd=None):
    return subprocess.run(args, cwd=cwd, check=True, text=True, capture_output=False)


def main():
    if platform.system() != "Darwin" or platform.machine() != "arm64":
        raise SystemExit("This build currently targets macOS arm64")
    cache_binary = shutil.which("kache")
    if cache_binary is None:
        raise SystemExit("Install Kache before building Rust dependencies")
    for name in ("RUSTC_WRAPPER", "CARGO_BUILD_RUSTC_WRAPPER"):
        if name in os.environ:
            override = shutil.which(os.environ[name])
            if override is None or Path(override).resolve() != Path(cache_binary).resolve():
                raise SystemExit(f"{name} overrides the repository's Kache policy")
    cache_version = subprocess.check_output(["kache", "--version"], text=True).strip()
    spec = ROOT / "native/quiche"
    manifest = json.loads((spec / "upstream.json").read_text())
    source = ROOT / ".local/vendor/quiche"
    if not source.exists():
        source.parent.mkdir(parents=True, exist_ok=True)
        run("git", "init", str(source))
        run("git", "-C", str(source), "remote", "add", "origin", manifest["repository"])
        run("git", "-C", str(source), "fetch", "--depth", "1", "origin", manifest["commit"])
        run("git", "-C", str(source), "checkout", "--detach", "FETCH_HEAD")
    commit = subprocess.check_output(["git", "-C", str(source), "rev-parse", "HEAD"], text=True).strip()
    if commit != manifest["commit"]:
        raise SystemExit("Existing quiche checkout differs from the pinned commit")
    header = source / "quiche/include/quiche.h"
    if hashlib.sha256(header.read_bytes()).hexdigest() != manifest["headerSha256"]:
        raise SystemExit("quiche C header differs from the generated bindings")
    for item in manifest.get("additionalHeaders", []):
        if hashlib.sha256((ROOT / item["path"]).read_bytes()).hexdigest() != item["sha256"]:
            raise SystemExit("quiche additional transport header differs from its manifest")
    changed = subprocess.check_output(["git", "-C", str(source), "diff", "--name-only", "HEAD"], text=True)
    patches = manifest.get("patches", [])
    owned_files = {item["path"] for patch in patches for item in patch["files"]}
    if set(changed.splitlines()) - owned_files:
        raise SystemExit("quiche checkout has unrelated modified tracked files")
    for patch in patches:
        patch_path = ROOT / patch["path"]
        if hashlib.sha256(patch_path.read_bytes()).hexdigest() != patch["sha256"]:
            raise SystemExit("quiche transport patch identity changed")
        states = [hashlib.sha256((source / item["path"]).read_bytes()).hexdigest()
            for item in patch["files"]]
        if states == [item["originalSha256"] for item in patch["files"]]:
            run("git", "apply", "--check", str(patch_path), cwd=source)
            run("git", "apply", str(patch_path), cwd=source)
        elif states != [item["patchedSha256"] for item in patch["files"]]:
            raise SystemExit("quiche transport patch files contain unrelated changes")
        for item in patch["files"]:
            if hashlib.sha256((source / item["path"]).read_bytes()).hexdigest() != item["patchedSha256"]:
                raise SystemExit("quiche transport patch result differs from its manifest")
    shutil.copyfile(spec / "Cargo.lock", source / "Cargo.lock")
    cargo_metadata = json.loads(subprocess.check_output([
        "cargo", "metadata", "--locked", "--no-deps", "--format-version", "1"
    ], cwd=source, text=True))
    target = Path(cargo_metadata["target_directory"])
    run("cargo", "build", "--locked", "--release", "-p", "quiche", "--features", "ffi", cwd=source)
    destination = ROOT / ".local/native"
    destination.mkdir(parents=True, exist_ok=True)
    library = destination / "libquiche.dylib"
    with tempfile.NamedTemporaryFile(dir=destination, prefix=".libquiche-", suffix=".dylib", delete=False) as file:
        staged = Path(file.name)
    try:
        shutil.copyfile(target / "release/libquiche.dylib", staged)
        run("install_name_tool", "-id", "@rpath/libquiche.dylib", str(staged))
        run("codesign", "--force", "--sign", "-", str(staged))
        os.replace(staged, library)
    finally:
        staged.unlink(missing_ok=True)
    shutil.copyfile(spec / "LICENSE.quiche", destination / "LICENSE.quiche")
    (destination / "quiche-build.json").write_text(json.dumps({
        **manifest, "librarySha256": hashlib.sha256(library.read_bytes()).hexdigest(),
        "buildCache": {"tool": "kache", "version": cache_version,
            "cargoConfigurationSha256": hashlib.sha256((ROOT / ".cargo/config.toml").read_bytes()).hexdigest(),
            "policySha256": hashlib.sha256((ROOT / ".cargo/kache.toml").read_bytes()).hexdigest()}
    }, indent=2) + "\n")
    print(library)


if __name__ == "__main__":
    main()
