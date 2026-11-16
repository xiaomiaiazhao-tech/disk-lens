"""Standard-library-only local build helpers. No publishing or credentials."""
from pathlib import Path
import json
import subprocess
import shlex

ROOT = Path(__file__).resolve().parents[1]
BUILD = ROOT / "build"
DIST = ROOT / "dist"

def config():
    return json.loads((ROOT / "release.json").read_text())

def run(args, **kwargs):
    print("+ " + shlex.join([str(x) for x in args]), flush=True)
    return subprocess.run([str(x) for x in args], check=True, **kwargs)

def capture(args):
    return subprocess.check_output([str(x) for x in args], text=True).strip()

def sdk():
    return capture(["xcrun", "--sdk", "macosx", "--show-sdk-path"])

def app_path():
    return DIST / (config()["name"] + ".app")

def dmg_path():
    return DIST / ("DiskLens-" + config()["version"] + "-universal.dmg")
