#!/usr/bin/env python3
"""Build arm64 + x86_64 locally, assemble the app, apply an ad-hoc signature."""
import argparse
import platform
import plistlib
import shutil
from common import ROOT, BUILD, DIST, config, run, sdk, app_path

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--arch", choices=["universal", "host"], default="universal")
    options=parser.parse_args()
    cfg=config();BUILD.mkdir(exist_ok=True);DIST.mkdir(exist_ok=True)
    host="arm64" if platform.machine()=="arm64" else "x86_64"
    arches=["arm64", "x86_64"] if options.arch=="universal" else [host]
    sources=sorted((ROOT/"Source").glob("*.swift"));binaries=[];sdk_path=sdk()
    for arch in arches:
        binary=BUILD/("DiskLens-"+arch)
        run(["xcrun","swiftc","-O","-swift-version","5","-sdk",sdk_path,
             "-target",arch+"-apple-macos"+cfg["minimum_macos"],*sources,"-o",binary])
        binaries.append(binary)
    app=app_path()
    if app.exists():shutil.rmtree(app)
    macos=app/"Contents/MacOS";resources=app/"Contents/Resources"
    macos.mkdir(parents=True);resources.mkdir(parents=True)
    executable=macos/cfg["executable"]
    if len(binaries)>1:run(["xcrun","lipo","-create",*binaries,"-output",executable])
    else:shutil.copy2(binaries[0],executable)
    web=ROOT/"Web"
    html=(web/"shell.html").read_text().replace("__CSS__",(web/"style.css").read_text()).replace("__ICONS__",(web/"icons.json").read_text()).replace("__JS__",(web/"app.js").read_text()).replace("__APP_VERSION__",cfg["version"])
    (resources/"index.html").write_text(html)
    shutil.copy2(ROOT/"Resources/AppIcon.icns",resources/"AppIcon.icns")
    shutil.copy2(ROOT/"LICENSE",resources/"LICENSE")
    shutil.copytree(ROOT/"licenses",resources/"licenses")
    info={"CFBundleName":cfg["name"],"CFBundleDisplayName":cfg["name"],
          "CFBundleIdentifier":cfg["bundle_id"],"CFBundleVersion":str(cfg["build"]),
          "CFBundleShortVersionString":cfg["version"],"CFBundlePackageType":"APPL",
          "CFBundleExecutable":cfg["executable"],"CFBundleIconFile":"AppIcon",
          "LSMinimumSystemVersion":cfg["minimum_macos"],"NSHighResolutionCapable":True,
          "NSDownloadsFolderUsageDescription":"读取下载文件的大小，清理由你审核后确认。",
          "NSDesktopFolderUsageDescription":"读取你选择的桌面目录。",
          "NSDocumentsFolderUsageDescription":"读取文稿文件的占用。",
          "NSRemovableVolumesUsageDescription":"读取你选择的外接磁盘目录。"}
    (app/"Contents/Info.plist").write_bytes(plistlib.dumps(info))
    run(["codesign","--force","--sign","-",app])
    run(["codesign","--verify","--deep","--strict",app])
    run(["xcrun","lipo","-info",executable])
    print("Built:",app,"\nSigning: ad-hoc; notarization: none.")

if __name__=="__main__":main()
