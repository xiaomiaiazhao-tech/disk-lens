#!/usr/bin/env python3
"""Run fixture-only native tests, plus UI regressions when Node is installed."""
import platform
import shutil
import tempfile
from common import ROOT, BUILD, config, run, sdk

def main():
    BUILD.mkdir(exist_ok=True)
    arch="arm64" if platform.machine()=="arm64" else "x86_64"
    binary=BUILD/"CoreTests"
    sources=[ROOT/"Source"/x for x in ["Engine.swift","Actions.swift","Applications.swift"]]
    sources += [ROOT/"Tests/CoreTests.swift",ROOT/"Tests/main.swift"]
    run(["xcrun","swiftc","-O","-swift-version","5","-sdk",sdk(),"-target",arch+"-apple-macos"+config()["minimum_macos"],*sources,"-o",binary])
    # Existing tests create and trash/restore only their own fixtures below cwd.
    # Production history and real user data are never used as mutation targets.
    with tempfile.TemporaryDirectory(prefix="test-work-",dir=BUILD) as work:
        run([binary],cwd=work)
    if shutil.which("node"):
        run(["node","--check",ROOT/"Web/app.js"])
        run(["node",ROOT/"Tests/ui-regression.cjs"])
    else:print("SKIP: UI regressions require Node.js; Node is not needed to run the app.")

if __name__=="__main__":main()
