"""Generate ignored Dart models from portable recovered schema inputs.

No installed Spotify, account, original process or network is needed. Google's
protoc and the locked Dart plugin supply the standard protobuf implementation.
This tool does not invoke the dart format command.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
from urllib.parse import unquote, urljoin, urlparse


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def plugin_binary(project, toolchain):
    configuration = project / ".dart_tool/package_config.json"
    if not configuration.exists():
        raise SystemExit("Run flutter pub get before generating Dart protocols")
    packages = json.loads(configuration.read_text())["packages"]
    package = next(p for p in packages if p["name"] == "protoc_plugin")
    uri = urljoin(configuration.as_uri(), package["rootUri"])
    root = Path(unquote(urlparse(uri).path))
    version = re.search(r"^version:\s*([^\s#]+)", (root / "pubspec.yaml").read_text(), re.M)
    if version is None or version[1] != toolchain["protocPluginVersion"]:
        raise SystemExit("The resolved protoc_plugin differs from the pinned toolchain")
    cache_key = hashlib.sha256((digest(project / "pubspec.lock") +
        json.dumps(toolchain, sort_keys=True)).encode()).hexdigest()[:16]
    binary = project / ".local" / ("protoc-gen-dart-" + cache_key)
    if not binary.exists():
        binary.parent.mkdir(parents=True, exist_ok=True)
        entry = project / ".local/protocol-codegen/protoc_plugin_entry.dart"
        entry.parent.mkdir(parents=True, exist_ok=True)
        # Copy the official CLI entry under this project so Dart resolves the
        # pinned project packages without probing a cached upstream workspace.
        shutil.copyfile(root / "bin/protoc_plugin.dart", entry)
        subprocess.run(["dart", "compile", "exe", "--packages=" + str(configuration),
            str(entry), "-o", str(binary)], cwd=project, check=True)
    alias = project / ".local/protoc-gen-dart"
    if not alias.is_symlink() or alias.readlink() != Path(binary.name):
        alias.unlink(missing_ok=True)
        alias.symlink_to(binary.name)
    return binary


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true", help="Compare regenerated Dart with the working tree")
    args = parser.parse_args()
    project = Path(__file__).resolve().parent.parent
    manifest = json.loads((project / "proto/manifest.json").read_text())
    descriptor_path = project / manifest["descriptorSet"]["path"]
    if digest(descriptor_path) != manifest["descriptorSet"]["sha256"]:
        raise SystemExit("Recovered descriptor set digest changed")
    for record in manifest["files"]:
        if digest(project / record["sourcePath"]) != record["sourceSha256"]:
            raise SystemExit("Recovered schema source changed; validate/re-export it first: " + record["file"])
    selected = {record["file"] for record in manifest["files"]}
    descriptor_paths = [descriptor_path]
    reconstructed_inputs = []
    reconstruction_path = project / "proto/reconstructed/login5/manifest.json"
    if reconstruction_path.exists():
        reconstruction = json.loads(reconstruction_path.read_text())
        if reconstruction["classification"] != "reconstructed-not-extracted":
            raise SystemExit("Login5 reconstruction input has an invalid provenance classification")
        if reconstruction["sourceExecutableSha256"] != manifest["sourceExecutableSha256"]:
            raise SystemExit("Exact and reconstructed inputs refer to different executables")
        artifact = reconstruction["descriptorSet"]
        recovered_path = project / artifact["path"]
        if digest(recovered_path) != artifact["sha256"]:
            raise SystemExit("Reconstructed descriptor set digest changed")
        inventory = reconstruction["nativeInventory"]
        if digest(project / inventory["path"]) != inventory["sha256"]:
            raise SystemExit("Login5 native metadata changed; validate the reconstruction first")
        for record in reconstruction["sourceFiles"]:
            if digest(project / record["path"]) != record["sha256"]:
                raise SystemExit("Reconstructed schema changed; validate it first: " + record["path"])
        overlap = selected.intersection(reconstruction["roots"])
        if overlap:
            raise SystemExit("Reconstructed roots overlap exact schema names: " + ", ".join(sorted(overlap)))
        descriptor_paths.append(recovered_path)
        selected.update(reconstruction["roots"])
        reconstructed_inputs.append({"manifest": str(reconstruction_path.relative_to(project)),
            "manifestSha256": digest(reconstruction_path), "descriptorSet": artifact,
            "classification": reconstruction["classification"], "roots": reconstruction["roots"]})
    selected = sorted(selected)
    toolchain = json.loads((project / "tools/protobuf-toolchain.json").read_text())
    protoc = shutil.which("protoc")
    if protoc is None:
        raise SystemExit("Install Google protoc " + toolchain["protocVersion"])
    version = subprocess.check_output([protoc, "--version"], text=True).strip()
    if version != "libprotoc " + toolchain["protocVersion"]:
        raise SystemExit("Expected libprotoc " + toolchain["protocVersion"] + "; found " + version)
    plugin = plugin_binary(project, toolchain)
    output = project / "lib/protocol/generated"
    with tempfile.TemporaryDirectory(prefix="spotify-protocol-codegen-") as directory:
        staged = Path(directory)
        descriptor_inputs = os.pathsep.join(str(path) for path in descriptor_paths)
        subprocess.run([protoc, f"--descriptor_set_in={descriptor_inputs}",
            f"--plugin=protoc-gen-dart={plugin}", f"--dart_out={staged}", *selected],
            cwd=project, check=True)
        subprocess.run(["go", "run", ".", "-repo", str(project), "-dart-presence",
            "-presence-out", str(staged / "native_proto3_presence.dart")],
            cwd=project / "tools/proto-export", check=True)
        generated = {p.relative_to(staged): p for p in staged.rglob("*.dart")}
        existing = {p.relative_to(output): p for p in output.rglob("*.dart")}
        changed = sorted(str(path) for path in generated
            if path not in existing or digest(generated[path]) != digest(existing[path]))
        obsolete = sorted(str(path) for path in existing if path not in generated)
        if args.check:
            if changed or obsolete:
                raise SystemExit("Generated Dart is stale: " + ", ".join((changed + obsolete)[:20]))
            print(f"Verified {len(generated)} generated Dart files (including exact presence metadata) against recovered schema inputs")
            return
        output.mkdir(parents=True, exist_ok=True)
        for relative, source in generated.items():
            target = output / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            temporary = target.with_suffix(target.suffix + ".codegen-tmp")
            shutil.copyfile(source, temporary)
            os.replace(temporary, target)
        for relative in obsolete:
            target = output / relative
            if "Generated code. Do not modify." not in target.read_text()[:500]:
                raise SystemExit("Refusing to remove a handwritten Dart file: " + str(target))
            target.unlink()
    provenance = {"sourceExecutableSha256": manifest["sourceExecutableSha256"],
        "descriptorSetSha256": manifest["descriptorSet"]["sha256"],
        "generator": toolchain, "descriptorFiles": selected,
        "reconstructedInputs": reconstructed_inputs}
    (output / "provenance.json").write_text(json.dumps(provenance, indent=2) + "\n")
    print(f"Generated {len(generated)} Dart files (including exact presence metadata) from {len(selected)} recovered schemas")


if __name__ == "__main__":
    main()
