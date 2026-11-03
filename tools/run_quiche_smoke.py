"""Run the bundled Flutter HTTP/3 check against a temporary local peer."""
import base64
import json
from pathlib import Path
import subprocess

root = Path(__file__).resolve().parent.parent
peer = subprocess.Popen(["uv", "run", "--project", "tools/oracles", "--locked",
    "--no-sync", "python", "test/support/http3_loopback_server.py"],
    cwd=root, stdout=subprocess.PIPE, text=True)
try:
    settings = json.loads(peer.stdout.readline())
    path = root / ".local/http3-flutter.json"
    path.write_text(json.dumps({"QUICHE_PEER_PORT": settings["port"],
        "QUICHE_PEER_CERTIFICATE": base64.b64encode(Path(settings["certificate"]).read_bytes()).decode()}))
    path.chmod(0o600)
    subprocess.run(["flutter", "run", "--no-pub", "-d", "macos", "-t",
        "tools/quiche_smoke_app.dart", "--dart-define-from-file=" + str(path),
        "--print-dtd"], cwd=root, check=True)
finally:
    peer.terminate()
    try:
        peer.wait(timeout=5)
    except subprocess.TimeoutExpired:
        peer.kill()
        peer.wait()
