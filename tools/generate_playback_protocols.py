"""Generate ignored playback protobufs from pinned references and native wire overlays.

These inputs remain reference-derived, not extracted original descriptors.
The bounded additions have independent original-instruction wire evidence.
This uses the project's pinned public protoc/Dart plugin and never
invokes dart format, an application, an account store, or a network operation.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

from generate_protocols import plugin_binary


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    project = Path(__file__).resolve().parent.parent
    manifest_path = project / "proto/librespot-playback.json"
    manifest = json.loads(manifest_path.read_text())
    if manifest["classification"] != "reference-derived-with-native-wire-verified-additions":
        raise SystemExit("Invalid playback source provenance classification")
    pin_path = project / manifest["sourcePin"]
    pin = json.loads(pin_path.read_text())
    if manifest["commit"] != pin["commit"]:
        raise SystemExit("Playback protobuf manifest and librespot source pin differ")
    source = project / pin["path"]
    commit = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=source, text=True).strip()
    if commit != manifest["commit"]:
        raise SystemExit("The librespot checkout differs from its pinned playback source")
    if digest(source / manifest["license"]["file"]) != manifest["license"]["sha256"]:
        raise SystemExit("The reference license changed")
    schema_root = source / manifest["schemaRoot"]
    for record in manifest["files"]:
        if digest(schema_root / record["file"]) != record["sha256"]:
            raise SystemExit("Pinned reference schema changed: " + record["file"])
    overlay = manifest["overlay"]
    overlay_root = project / overlay["root"]
    if digest(overlay_root / overlay["license"]["file"]) != overlay["license"]["sha256"]:
        raise SystemExit("The overlay's retained MIT license changed")
    if overlay["license"]["sha256"] != manifest["license"]["sha256"]:
        raise SystemExit("The overlay does not preserve the original MIT license")
    if {record["file"] for record in overlay["files"]} != set(manifest["roots"]):
        raise SystemExit("Playback overlay roots differ from the pinned reference roots")
    for record in overlay["files"]:
        if digest(overlay_root / record["file"]) != record["sha256"]:
            raise SystemExit("Pinned native wire overlay changed: " + record["file"])
    proof = overlay["nativeEvidence"]
    proof_path = project / proof["file"]
    if digest(proof_path) != proof["sha256"]:
        raise SystemExit("The native AP wire proof digest changed")
    evidence = json.loads(proof_path.read_text())
    if evidence["classification"] != "original-instruction-wire-evidence-not-exact-descriptors":
        raise SystemExit("The native AP proof classification changed")
    if evidence["sourceExecutableSha256"] != proof["sourceExecutableSha256"]:
        raise SystemExit("The native AP proof's source executable identity differs")
    if evidence["referenceSources"] != manifest["files"]:
        raise SystemExit("The native AP proof refers to different upstream reference schemas")
    if evidence["oracle"] != proof["oracle"]:
        raise SystemExit("The native AP proof refers to a different oracle")
    toolchain = json.loads((project / "tools/protobuf-toolchain.json").read_text())
    protoc = shutil.which("protoc")
    if protoc is None:
        raise SystemExit("Install Google protoc " + toolchain["protocVersion"])
    version = subprocess.check_output([protoc, "--version"], text=True).strip()
    if version != "libprotoc " + toolchain["protocVersion"]:
        raise SystemExit("Expected pinned protoc; found " + version)
    standard_include = Path(protoc).resolve().parent.parent / "include"
    for record in manifest["standardImports"]:
        if digest(standard_include / record["file"]) != record["sha256"]:
            raise SystemExit("Pinned protoc standard schema changed: " + record["file"])
    plugin = plugin_binary(project, toolchain)
    output = project / "lib/playback/generated"
    with tempfile.TemporaryDirectory(prefix="spotify-reference-protocols-") as directory:
        staged = Path(directory)
        descriptor = staged / "reference.pbdesc"
        subprocess.run([protoc, "-I" + str(overlay_root), "-I" + str(standard_include),
            "--include_imports", "--descriptor_set_out=" + str(descriptor), *manifest["roots"]],
            cwd=project, check=True)
        subprocess.run([protoc, "--descriptor_set_in=" + str(descriptor),
            "--plugin=protoc-gen-dart=" + str(plugin), "--dart_out=" + str(staged),
            *manifest["roots"]], cwd=project, check=True)
        provenance = {"classification": manifest["classification"],
            "sourceManifest": str(manifest_path.relative_to(project)),
            "sourceManifestSha256": digest(manifest_path), "repository": pin["repository"],
            "commit": commit, "license": manifest["license"], "generator": toolchain,
            "referenceFiles": manifest["files"], "overlay": overlay,
            "descriptorSha256": digest(descriptor), "roots": manifest["roots"]}
        (staged / "provenance.json").write_text(json.dumps(provenance, indent=2) + "\n")
        generated = {p.relative_to(staged): p for p in staged.rglob("*") if p.is_file()}
        existing = {p.relative_to(output): p for p in output.rglob("*") if p.is_file()}
        changed = sorted(str(p) for p in generated if p not in existing or digest(generated[p]) != digest(existing[p]))
        obsolete = sorted(str(p) for p in existing if p not in generated)
        if args.check:
            if changed or obsolete:
                raise SystemExit("Generated reference playback protocols are stale: " + ", ".join((changed + obsolete)[:20]))
            print(f"Verified {len(generated)} ignored playback reference outputs")
            return
        output.mkdir(parents=True, exist_ok=True)
        for relative, original in generated.items():
            target = output / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            temporary = target.with_suffix(target.suffix + ".codegen-tmp")
            shutil.copyfile(original, temporary)
            os.replace(temporary, target)
        for relative in obsolete:
            path = output / relative
            header = path.read_text()[:500] if path.suffix == ".dart" else ""
            if path.suffix == ".dart" and any(marker in header for marker in (
                "Generated code. Do not modify.", "This is a generated file - do not edit.")):
                path.unlink()
            else:
                raise SystemExit("Refusing to remove an unrecognized generated file: " + str(path))
    print(f"Generated {len(generated)} ignored playback reference outputs")


if __name__ == "__main__":
    main()
