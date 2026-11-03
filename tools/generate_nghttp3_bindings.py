"""Generate pinned nghttp3 C bindings without invoking the Dart formatter."""
import hashlib
import json
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parent.parent
specification = json.loads((ROOT / "native/nghttp3/upstream.json").read_text())
header = ROOT / ".local/vendor/nghttp3" / specification["headerPath"]
if hashlib.sha256(header.read_bytes()).hexdigest() != specification["headerSha256"]:
    raise SystemExit("nghttp3 header differs from the pinned ABI")
for item in specification.get("additionalHeaders", []):
    if hashlib.sha256((ROOT / item["path"]).read_bytes()).hexdigest() != item["sha256"]:
        raise SystemExit("Additional nghttp3 API header differs from its pinned ABI")
if not (ROOT / ".local/native-build/nghttp3/lib/includes/nghttp3/version.h").is_file():
    raise SystemExit("Run tools/build_nghttp3.py through uv before generating bindings")
subprocess.run(["dart", "run", "ffigen", "--config", "nghttp3.yaml", "--no-format"],
    cwd=ROOT / "tools/transport_probe", check=True)
output = ROOT / "lib/transport/nghttp3/bindings.dart"
output.write_text("\n".join(line.rstrip() for line in output.read_text().splitlines()) + "\n")
