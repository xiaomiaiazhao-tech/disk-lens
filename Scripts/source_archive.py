#!/usr/bin/env python3
"""Archive an explicit source whitelist, excluding builds, logs and personal data."""
from zipfile import ZipFile, ZIP_DEFLATED
from common import ROOT, DIST, config

TOP={"README.md","LICENSE","THIRD_PARTY_NOTICES.md","CHANGELOG.md","CONTRIBUTING.md","SECURITY.md","PRIVACY.md","Makefile","release.json",".gitignore",".gitattributes"}
DIRS={"Source","Web","Resources","Tests","Scripts","docs","licenses","packaging",".github"}

def source_files():
    for path in sorted(ROOT.rglob("*")):
        rel=path.relative_to(ROOT)
        if not path.is_file() or path.is_symlink() or "__pycache__" in rel.parts or path.name==".DS_Store":continue
        if rel.parts[0] in DIRS or (len(rel.parts)==1 and path.name in TOP):yield path,rel

def main():
    DIST.mkdir(exist_ok=True);name="DiskLens-"+config()["version"]+"-source"
    archive=DIST/(name+".zip")
    with ZipFile(archive,"w",ZIP_DEFLATED) as z:
        for path,rel in source_files():z.write(path,name+"/"+rel.as_posix())
    with ZipFile(archive) as z:
        assert z.testzip() is None
        assert all(not any(x in n.split("/")[1:] for x in ["build","dist",".git","history.json",".DS_Store"]) for n in z.namelist())
    print("Source archive:",archive)

if __name__=="__main__":main()
