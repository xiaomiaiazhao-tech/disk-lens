#!/usr/bin/env python3
"""Verify checksums and the app inside a read-only-mounted DMG; never launch it."""
import hashlib
from pathlib import Path
import plistlib
import subprocess
import tempfile
from common import BUILD, DIST, config, dmg_path, run, capture

def main():
    cfg=config();image=dmg_path()
    expected=(DIST/"SHA256SUMS").read_text().split()[0]
    if hashlib.sha256(image.read_bytes()).hexdigest()!=expected:raise SystemExit("DMG checksum mismatch")
    run(["hdiutil","verify",image]);BUILD.mkdir(exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="dmg-check-",dir=BUILD) as temp:
        mount=Path(temp)/"volume";mount.mkdir()
        mounted=False
        try:
            subprocess.run(["hdiutil","attach","-readonly","-nobrowse","-mountpoint",str(mount),str(image)],check=True,stdout=subprocess.PIPE)
            mounted=True
            app=mount/(cfg["name"]+".app")
            run(["codesign","--verify","--deep","--strict",app])
            info=plistlib.loads((app/"Contents/Info.plist").read_bytes())
            assert info["CFBundleShortVersionString"]==cfg["version"]
            assert set(capture(["xcrun","lipo","-archs",app/"Contents/MacOS"/cfg["executable"]]).split())=={"arm64","x86_64"}
            assert (mount/"Applications").is_symlink() and (mount/"Applications").readlink()==Path("/Applications")
            assert (app/"Contents/Resources/LICENSE").is_file()
            assert (app/"Contents/Resources/licenses/Phosphor-MIT.txt").is_file()
            assert capture([app/"Contents/MacOS"/cfg["executable"],"--version"])==cfg["version"]
        finally:
            if mounted:run(["hdiutil","detach",mount])
    print("PASS: DMG checksum, read-only mount, app signature, universal slices, version, Applications shortcut and licenses.")
    print("This is integrity validation, not Apple notarization or Intel hardware testing.")

if __name__=="__main__":main()
