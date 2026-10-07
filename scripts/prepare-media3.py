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
        if item.get("custom_pom"):
            # This UI companion is specific to the FongMi fork, so Google has
            # no published POM. Its common/OkHttp/Gson dependencies are explicit.
            dependencies = "".join(
                "<dependency><groupId>" + group + "</groupId><artifactId>" + name
                + "</artifactId><version>" + value + "</version></dependency>"
                for group, name, value in [
                    ("androidx.media3", "media3-common", version),
                    ("com.squareup.okhttp3", "okhttp", "4.12.0"),
                    ("com.google.code.gson", "gson", "2.13.2"),
                ])
            pom = ("<project><modelVersion>4.0.0</modelVersion>"
                   "<groupId>androidx.media3</groupId><artifactId>" + module
                   + "</artifactId><version>" + version
                   + "</version><packaging>aar</packaging><dependencies>"
                   + dependencies + "</dependencies></project>").encode()
        else:
            pom = download(pom_url, item["pom_sha256"])
        (directory / (filename + ".aar")).write_bytes(aar)
        (directory / (filename + ".pom")).write_bytes(pom)
        print("Verified custom dependency: " + module + " " + version)


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("src", type=Path)
    prepare(parser.parse_args().src)
