#!/usr/bin/env python3
"""Create a local DMG. Does not upload, publish, install or notarize anything."""
import argparse
import hashlib
import plistlib
import shutil
import sys
import tempfile
from common import ROOT, BUILD, DIST, config, run, app_path, dmg_path, capture

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--skip-build",action="store_true")
    opts=parser.parse_args();cfg=config()
    if not opts.skip_build:run([sys.executable,ROOT/"Scripts/build.py"])
    app=app_path();info=plistlib.loads((app/"Contents/Info.plist").read_bytes())
    if info["CFBundleShortVersionString"]!=cfg["version"]:raise SystemExit("App version does not match release.json")
    arches=capture(["xcrun","lipo","-archs",app/"Contents/MacOS"/cfg["executable"]]).split()
    if set(arches)!={"arm64","x86_64"}:raise SystemExit("Universal DMG requires an arm64 + x86_64 build")
    run(["codesign","--verify","--deep","--strict",app])
    BUILD.mkdir(exist_ok=True);DIST.mkdir(exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="dmg-stage-",dir=BUILD) as work:
        stage=__import__("pathlib").Path(work)
        shutil.copytree(app,stage/app.name)
        (stage/"Applications").symlink_to("/Applications",target_is_directory=True)
        shutil.copy2(ROOT/"LICENSE",stage/"LICENSE.txt")
        (stage/"请先阅读.txt").write_text((ROOT/"docs/INSTALL.txt").read_text())
        run(["hdiutil","create","-volname",cfg["name"]+" "+cfg["version"],"-srcfolder",stage,"-format","UDZO","-ov",dmg_path()])
    run(["hdiutil","verify",dmg_path()])
    sha=hashlib.sha256(dmg_path().read_bytes()).hexdigest()
    (DIST/"SHA256SUMS").write_text(sha+"  "+dmg_path().name+"\n")
    print("DMG:",dmg_path(),"\nSHA-256:",sha,"\nAd-hoc signed app; NOT notarized.")

if __name__=="__main__":main()
