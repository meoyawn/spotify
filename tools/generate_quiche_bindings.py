"""Generate the pinned quiche C bindings without invoking the Dart formatter."""
import hashlib
import json
from pathlib import Path
import subprocess

root = Path(__file__).resolve().parent.parent
specification = json.loads((root / "native/quiche/upstream.json").read_text())
header = root / ".local/vendor/quiche/quiche/include/quiche.h"
if hashlib.sha256(header.read_bytes()).hexdigest() != specification["headerSha256"]:
    raise SystemExit("quiche header differs from the pinned ABI")
for item in specification.get("additionalHeaders", []):
    if hashlib.sha256((root / item["path"]).read_bytes()).hexdigest() != item["sha256"]:
        raise SystemExit("quiche additional transport header differs from its pinned ABI")
subprocess.run(["dart", "run", "ffigen", "--config", "quiche.yaml", "--no-format"],
    cwd=root / "tools/transport_probe", check=True)
output = root / "lib/transport/quiche/bindings.dart"
output.write_text("\n".join(line.rstrip() for line in output.read_text().splitlines()) + "\n")
