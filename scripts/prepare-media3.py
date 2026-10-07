#!/usr/bin/env python3
"""Prepare checksum-locked custom Media3 AARs with their Maven dependencies."""
import argparse
import hashlib
import io
import json
from pathlib import Path
import urllib.request
import zipfile


def download(url, expected):
    with urllib.request.urlopen(url, timeout=90) as response:
        data = response.read()
    if hashlib.sha256(data).hexdigest() != expected:
        raise RuntimeError("Media3 dependency checksum mismatch: " + url)
    return data


def prepare(src):
    lock = json.loads(Path(__file__).with_name("media3-lock.json").read_text())
    version = lock["version"]
    raw = "https://raw.githubusercontent.com/" + lock["repository"] + "/" + lock["commit"] + "/app/libs/"
    for item in lock["modules"]:
        module = item["module"]
        directory = src / "family-media3-maven/androidx/media3" / module / version
        directory.mkdir(parents=True, exist_ok=True)
        filename = module + "-" + version
        aar = download(raw + module + ".aar", item["aar_sha256"])
        with zipfile.ZipFile(io.BytesIO(aar)) as archive:
            if not archive.testzip() is None:
                raise RuntimeError("Corrupt Media3 archive: " + module)
        pom_url = "https://dl.google.com/dl/android/maven2/androidx/media3/" + module + "/" + version + "/" + filename + ".pom"
        pom = download(pom_url, item["pom_sha256"])
        (directory / (filename + ".aar")).write_bytes(aar)
        (directory / (filename + ".pom")).write_bytes(pom)
        print("Verified custom dependency: " + module + " " + version)


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("src", type=Path)
    prepare(parser.parse_args().src)
