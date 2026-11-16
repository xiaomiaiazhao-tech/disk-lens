#!/usr/bin/env python3
"""Generate a Homebrew Cask with the DMG's real SHA-256. Does not publish it."""
import argparse
import hashlib
from pathlib import Path
import re
from common import ROOT, DIST, config, dmg_path

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repository",default=config()["repository"],help="GitHub OWNER/REPOSITORY")
    parser.add_argument("--output",type=Path,default=DIST/"homebrew-tap/Casks/disk-lens.rb")
    parser.add_argument("--url",help="Optional file:// URL for a local developer-only check")
    args=parser.parse_args();cfg=config()
    if not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+",args.repository):raise SystemExit("Expected OWNER/REPOSITORY")
    if args.url and not args.url.startswith("file://"):raise SystemExit("Only file:// local overrides are supported; normal releases use GitHub HTTPS")
    template=(ROOT/"packaging/homebrew/disk-lens.rb.in").read_text()
    url=args.url or f"https://github.com/{args.repository}/releases/download/v{cfg['version']}/{dmg_path().name}"
    replacements={"@VERSION@":cfg["version"],"@SHA256@":hashlib.sha256(dmg_path().read_bytes()).hexdigest(),"@URL@":url,"@REPOSITORY@":args.repository,"@MIN_MACOS@":cfg["minimum_macos"]}
    for key,value in replacements.items():template=template.replace(key,value)
    args.output.parent.mkdir(parents=True,exist_ok=True);args.output.write_text(template)
    print("Prepared:",args.output)
    if "YOUR_GITHUB" in args.repository:print("DRAFT: replace YOUR_GITHUB before publishing. The public install URL is not live.")

if __name__=="__main__":main()
