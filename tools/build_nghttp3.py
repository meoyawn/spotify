"""Build pinned nghttp3 with declared generic startup extensions; no app launch.

Only the standard C library is built. No tests, examples, Spotify process,
session, application protocol or account requests are involved.
"""
import hashlib
import json
import os
from pathlib import Path
import platform
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent.parent
SPEC = ROOT / "native/nghttp3"
SOURCE = ROOT / ".local/vendor/nghttp3"
BUILD = ROOT / ".local/native-build/nghttp3"


def run(*arguments, cwd=None):
    subprocess.run(arguments, cwd=cwd, check=True)


def git(*arguments, cwd):
    return subprocess.check_output(["git", *arguments], cwd=cwd)


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def verify_tree(path, identity):
    if git("rev-parse", "HEAD", cwd=path).decode().strip() != identity["commit"]:
        raise SystemExit("Existing standard-library checkout has another commit: " + str(path))
    patches = identity.get("patches", [])
    owned = {item["path"] for patch in patches for item in patch["files"]}
    changed = set(git("diff", "--name-only", "HEAD", cwd=path).decode().splitlines())
    if changed - owned:
        raise SystemExit("Standard-library checkout has modified tracked files: " + str(path))
    archive = git("archive", "--format=tar", "HEAD", cwd=path)
    if hashlib.sha256(archive).hexdigest() != identity["sourceArchiveSha256"]:
        raise SystemExit("Standard-library source archive identity changed: " + str(path))
    if digest(path / identity["licensePath"]) != identity["licenseSha256"]:
        raise SystemExit("Standard-library license identity changed: " + str(path))
    for patch in patches:
        patch_path = ROOT / patch["path"]
        if digest(patch_path) != patch["sha256"]:
            raise SystemExit("Standard-library patch identity changed")
        states = [digest(path / item["path"]) for item in patch["files"]]
        if states == [item["originalSha256"] for item in patch["files"]]:
            run("git", "apply", "--check", str(patch_path), cwd=path)
            run("git", "apply", str(patch_path), cwd=path)
        elif states != [item["patchedSha256"] for item in patch["files"]]:
            raise SystemExit("Standard-library patch files contain unrelated changes")
        if [digest(path / item["path"]) for item in patch["files"]] != [
                item["patchedSha256"] for item in patch["files"]]:
            raise SystemExit("Standard-library patch result differs from its manifest")


def main():
    if platform.system() != "Darwin" or platform.machine() != "arm64":
        raise SystemExit("This build currently targets macOS arm64")
    manifest = json.loads((SPEC / "upstream.json").read_text())
    if not SOURCE.exists():
        SOURCE.parent.mkdir(parents=True, exist_ok=True)
        run("git", "init", str(SOURCE))
        run("git", "-C", str(SOURCE), "remote", "add", "origin", manifest["repository"])
        run("git", "-C", str(SOURCE), "fetch", "--depth", "1", "origin", manifest["commit"])
        run("git", "-C", str(SOURCE), "checkout", "--detach", "FETCH_HEAD")
    verify_tree(SOURCE, manifest)
    for item in manifest["submodules"]:
        path = SOURCE / item["path"]
        if not (path / ".git").exists():
            run("git", "-C", str(SOURCE), "submodule", "update", "--init", "--depth", "1", "--", item["path"])
        verify_tree(path, item)
    if digest(SOURCE / manifest["headerPath"]) != manifest["headerSha256"]:
        raise SystemExit("nghttp3 C header differs from the pinned ABI")
    for item in manifest.get("additionalHeaders", []):
        if digest(ROOT / item["path"]) != item["sha256"]:
            raise SystemExit("Additional nghttp3 API header identity changed")
    options = ["-DENABLE_LIB_ONLY=ON", "-DENABLE_STATIC_LIB=OFF",
        "-DENABLE_SHARED_LIB=ON", "-DBUILD_TESTING=OFF", "-DCMAKE_BUILD_TYPE=Release",
        "-DCMAKE_OSX_ARCHITECTURES=arm64",
        "-DCMAKE_OSX_DEPLOYMENT_TARGET=" + manifest["deploymentTarget"]]
    run("cmake", "-S", str(SOURCE), "-B", str(BUILD), *options)
    run("cmake", "--build", str(BUILD), "--target", "nghttp3", "--parallel", str(min(os.cpu_count() or 1, 8)))
    destination = ROOT / ".local/native"
    destination.mkdir(parents=True, exist_ok=True)
    library = destination / "libnghttp3.dylib"
    with tempfile.NamedTemporaryFile(dir=destination, prefix=".libnghttp3-", suffix=".dylib", delete=False) as file:
        staged = Path(file.name)
    try:
        shutil.copyfile(BUILD / "lib/libnghttp3.dylib", staged)
        run("install_name_tool", "-id", "@rpath/libnghttp3.dylib", str(staged))
        run("codesign", "--force", "--sign", "-", str(staged))
        os.replace(staged, library)
    finally:
        staged.unlink(missing_ok=True)
    for origin, name in [(SOURCE / manifest["licensePath"], "LICENSE.nghttp3"),
            (SOURCE / "lib/sfparse/COPYING", "LICENSE.nghttp3-sfparse")]:
        shutil.copyfile(origin, destination / name)
        shutil.copyfile(origin, SPEC / name)
    version_header = BUILD / "lib/includes/nghttp3/version.h"
    (destination / "nghttp3-build.json").write_text(json.dumps({
        **manifest, "librarySha256": digest(library), "cmakeOptions": options,
        "generatedVersionHeaderSha256": digest(version_header),
        "compiler": subprocess.check_output(["xcrun", "clang", "--version"], text=True).splitlines()[0],
        "cmakeVersion": subprocess.check_output(["cmake", "--version"], text=True).splitlines()[0]
    }, indent=2) + "\n")
    print(library)


if __name__ == "__main__":
    main()
