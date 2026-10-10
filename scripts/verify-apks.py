#!/usr/bin/env python3
"""Reject missing/unsigned APKs, incorrect ABI or application identity."""
import hashlib
import json
import os
import re
from pathlib import Path
import subprocess
import sys
import zipfile
from PIL import Image
from io import BytesIO

out = Path(sys.argv[1])
sdk = Path(os.environ["ANDROID_HOME"])
tools = sdk / "build-tools/36.0.0"
results = []
for variant, abi in [("arm64_v8a", "arm64-v8a"), ("armeabi_v7a", "armeabi-v7a")]:
    apk = out / f"leanback-{variant}-release.apk"
    if not apk.is_file() or not apk.stat().st_size:
        raise SystemExit(f"Missing APK for {abi}")
    info = subprocess.check_output([str(tools / "aapt"), "dump", "badging", str(apk)], text=True)
    if "package: name='com.oops.tv'" not in info or "application-label:'家庭电视'" not in info:
        raise SystemExit(f"Incorrect application identity: {apk.name}")
    version = re.search(r"versionCode='([^']+)' versionName='([^']+)'", info)
    if not version or version.groups() != ("4", "1.1.0 家庭电视"):
        raise SystemExit(f"Unexpected APK version: {apk.name}")
    if f"native-code: '{abi}'" not in info:
        raise SystemExit(f"Incorrect native ABI: {apk.name}")
    subprocess.run([str(tools / "apksigner"), "verify", "--verbose", str(apk)], check=True)
    with zipfile.ZipFile(apk) as archive:
        libs = {name.split("/")[1] for name in archive.namelist() if name.startswith("lib/") and name.endswith(".so")}
        if libs != {abi}: raise SystemExit(f"Mixed or missing native libraries: {apk.name}: {libs}")
        icons = list(set(re.findall(r"application-icon-\d+:'([^']+)'", info) + re.findall(r"icon='([^']+)'", info)))
        icons = [name for name in icons if name in archive.namelist()]
        if not icons: icons = [name for name in archive.namelist() if name.endswith("family_tv_icon.png")]
        if not icons: raise SystemExit("Final user icon missing from APK")
        expected = Path(__file__).resolve().parents[1] / "assets/android/family-tv-icon.png"
        with Image.open(expected) as original:
            pixels = original.convert("RGBA")
            same = False
            for name in icons:
                with Image.open(BytesIO(archive.read(name))) as packaged:
                    same |= packaged.size == pixels.size and packaged.convert("RGBA").tobytes() == pixels.tobytes()
            if not same: raise SystemExit("APK icon pixels differ from the user supplied final image")
    results.append({"file": apk.name, "abi": abi, "bytes": apk.stat().st_size, "sha256": hashlib.sha256(apk.read_bytes()).hexdigest(), "signed": True, "version_code": 4, "version_name": "1.1.0 家庭电视"})
(out / "build-verification.json").write_text(json.dumps(results, ensure_ascii=False, indent=2) + "\n")
print(json.dumps(results, ensure_ascii=False, indent=2))
