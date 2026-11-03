"""Bundle the prebuilt standard dependency into the single Flutter app."""
import os
from pathlib import Path
import shutil
import subprocess

root = Path(__file__).resolve().parent.parent
target = Path(os.environ["TARGET_BUILD_DIR"])
frameworks = target / os.environ["FRAMEWORKS_FOLDER_PATH"]
frameworks.mkdir(parents=True, exist_ok=True)
for name in ("quiche", "nghttp3"):
    library = root / f".local/native/lib{name}.dylib"
    if not library.exists():
        raise SystemExit(f"Build {name} first: uv run --project tools/oracles --locked python tools/build_{name}.py")
    embedded = frameworks / library.name
    shutil.copyfile(library, embedded)
    if os.environ.get("CODE_SIGNING_ALLOWED") != "NO":
        identity = os.environ.get("EXPANDED_CODE_SIGN_IDENTITY") or "-"
        subprocess.run(["/usr/bin/codesign", "--force", "--sign", identity,
            "--timestamp=none", str(embedded)], check=True)
    licenses = target / os.environ["UNLOCALIZED_RESOURCES_FOLDER_PATH"] / f"Licenses/{name}"
    licenses.mkdir(parents=True, exist_ok=True)
    for source in (root / f"native/{name}").glob("LICENSE.*"):
        shutil.copyfile(source, licenses / source.name)
