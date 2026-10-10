#!/usr/bin/env python3
"""Merge IPTV-CN categories and a maintained supplement into safe TVBox TXT."""

import argparse
from concurrent.futures import ThreadPoolExecutor
import ipaddress
import json
import os
from pathlib import Path
import re
import sys
import tempfile
import time
import unicodedata
from urllib.parse import quote, urlsplit, urlunsplit
from urllib.request import Request, urlopen


ROOT = Path(__file__).resolve().parents[1]
SOURCES = (
    "https://iptv-cn.github.io/IPTV/categories/cctv.m3u",
    "https://iptv-cn.github.io/IPTV/categories/" + quote("卫视") + ".m3u",
    "https://guovin.github.io/iptv-api/result.m3u",
)
CCTV = tuple("CCTV" + str(i) for i in range(1, 18))
SATELLITE = ("江西卫视", "湖南卫视", "浙江卫视", "江苏卫视", "东方卫视", "广东卫视", "北京卫视", "深圳卫视")
ORDER = CCTV[:5] + ("CCTV5+",) + CCTV[5:] + SATELLITE
REQUIRED = CCTV + SATELLITE
BLOCKED = tuple(ipaddress.ip_network(net) for net in ("74.91.0.0/16", "107.150.0.0/16"))
MAX_BYTES = 4 * 1024 * 1024
USER_AGENT = "Mozilla/5.0 FamilyTV-PlaylistUpdater/1.0"


class UpdateError(Exception):
    pass


def channel_name(value):
    value = re.sub(r"\s+", "", unicodedata.normalize("NFKC", value)).upper()
    # CCTV4K / CCTV8K are standalone UHD channels, not CCTV4 / CCTV8.
    if re.match(r"^CCTV[-_]?[48]K", value):
        return None
    match = re.match(r"^CCTV[-_]?(\d{1,2})(\+|PLUS)?(?!\d)", value)
    if match:
        number = int(match.group(1))
        if not 1 <= number <= 17 or (match.group(2) and number != 5):
            return None
        return "CCTV" + str(number) + ("+" if match.group(2) else "")
    for name in SATELLITE:
        if value == name or value in (name + suffix for suffix in ("高清", "超清", "HD", "FHD", "4K")):
            return name
    return {"上海卫视": "东方卫视", "BTV北京卫视": "北京卫视"}.get(value)


def valid_url(value):
    """Return a conservative dedup key, preserving signed query strings verbatim."""
    if not value or any(ord(c) < 33 or ord(c) == 127 for c in value):
        return None
    # These characters are control syntax in TVBox TXT, not URL data.
    if any(c in value for c in "#|$"):
        return None
    try:
        parts = urlsplit(value)
        if parts.scheme.lower() not in ("http", "https") or not parts.hostname:
            return None
        if parts.username is not None or parts.password is not None:
            return None
        port = parts.port
        host = parts.hostname.lower()
        if host == "localhost" or host.endswith((".localhost", ".local")):
            return None
        try:
            address = ipaddress.ip_address(host)
        except ValueError:
            address = None
        if address is not None and (not address.is_global or any(address in net for net in BLOCKED)):
            return None
        host = "[" + host + "]" if ":" in host else host
        scheme = parts.scheme.lower()
        if port is not None and port != {"http": 80, "https": 443}[scheme]:
            host += ":" + str(port)
        return urlunsplit((scheme, host, parts.path or "/", parts.query, ""))
    except ValueError:
        return None


def extinf(line):
    # The first comma outside quotes separates metadata from the display name.
    quoted = None
    for index, char in enumerate(line):
        if char in "\"'":
            if quoted == char:
                quoted = None
            elif quoted is None:
                quoted = char
        if char == "," and quoted is None:
            metadata, display = line[:index], line[index + 1:]
            attributes = {m.group(1).lower(): m.group(3) for m in re.finditer(r"([\w-]+)\s*=\s*([\"'])(.*?)\2", metadata)}
            return display, attributes
    raise UpdateError("EXTINF is missing its display-name separator")


def parse_m3u(text, label):
    lines = [line.strip() for line in text.lstrip("\ufeff").splitlines() if line.strip()]
    if not lines or lines[0].split(maxsplit=1)[0] != "#EXTM3U":
        raise UpdateError(label + ": not an extended M3U playlist")
    records = []
    pending = None
    needs_headers = False
    for line in lines[1:]:
        if line.startswith("#EXTINF:"):
            if pending is not None:
                raise UpdateError(label + ": EXTINF entry has no URL")
            pending = extinf(line)
            needs_headers = False
        elif line.startswith(("#EXTVLCOPT:", "#EXTHTTP:", "#KODIPROP:")):
            # Do not silently convert a header/DRM-dependent stream into a broken bare URL.
            if pending is None:
                raise UpdateError(label + ": unsupported global stream request settings")
            needs_headers = True
        elif line.startswith("#"):
            continue
        else:
            if pending is None:
                raise UpdateError(label + ": stream URL without EXTINF")
            display, attributes = pending
            name = next((name for value in (display, attributes.get("tvg-name", ""), attributes.get("tvg-id", ""))
                         if (name := channel_name(value))), None)
            if name is not None and not needs_headers:
                records.append((name, line))
            pending = None
    if pending is not None:
        raise UpdateError(label + ": truncated final entry")
    if not records:
        raise UpdateError(label + ": no selected channels")
    return records


def fetch(url, timeout=20, attempts=3):
    for attempt in range(attempts):
        try:
            request = Request(url, headers={"User-Agent": USER_AGENT})
            with urlopen(request, timeout=timeout) as response:
                if response.status != 200:
                    raise UpdateError("upstream did not return HTTP 200")
                data = response.read(MAX_BYTES + 1)
            if len(data) > MAX_BYTES:
                raise UpdateError("upstream playlist exceeds size limit")
            return data.decode("utf-8-sig")
        except (OSError, UnicodeError, UpdateError, ValueError) as exc:
            if attempt == attempts - 1:
                raise UpdateError(url + ": " + str(exc)) from exc
            time.sleep(attempt + 1)


def channel_url_agrees(name, url):
    # The supplement has mislabeled CCTV4K and CCTV5+ entries. Reject explicit
    # conflicts rather than guessing the programme identity from a valid URL.
    value = url.lower()
    marker = r"(?:^|[/=?&_-])cctv[-_]?"
    if name == "CCTV4" and re.search(marker + r"4k(?:hd|[/._?&=-]|$)", value):
        return False
    if name == "CCTV8" and re.search(marker + r"8k(?:hd|[/._?&=-]|$)", value):
        return False
    if name == "CCTV5" and re.search(marker + r"5(?:p|plus)(?:hd|[/._?&=-]|$)", value):
        return False
    return True


def collect(playlists):
    channels = {}
    seen = set()
    skipped = 0
    for label, text in playlists:
        for name, url in parse_m3u(text, label):
            key = valid_url(url)
            if key is None or not channel_url_agrees(name, url) or (name, key) in seen:
                skipped += 1
                continue
            seen.add((name, key))
            channels.setdefault(name, []).append(url)
    return channels, skipped


def check_coverage(channels):
    missing = [name for name in REQUIRED if not channels.get(name)]
    if missing:
        raise UpdateError("missing required channels: " + ", ".join(missing) + "; existing live.txt retained")


def probe(url, timeout=8):
    """A bounded GET: HLS manifest or MPEG-TS bytes, never just a HEAD/HTTP 200."""
    try:
        with urlopen(Request(url, headers={"User-Agent": USER_AGENT}), timeout=timeout) as response:
            if response.status not in (200, 206):
                return False
            if valid_url(getattr(response, "geturl", lambda: url)()) is None:
                return False
            data = response.read(4096)
            if data.lstrip(b"\xef\xbb\xbf \r\n").startswith(b"#EXTM3U"):
                # ENDLIST may be at the end of a long recorded-programme playlist.
                limit = 512 * 1024
                data += response.read(limit + 1 - len(data))
                if len(data) > limit:
                    return False
        manifest = data.decode("utf-8-sig", errors="replace").strip()
        if manifest.startswith("#EXTM3U"):
            if "#EXT-X-ENDLIST" in manifest or "#EXT-X-PLAYLIST-TYPE:VOD" in manifest:
                return False
            # A header alone or an HTTP 200 error page is not a usable HLS response.
            has_stream_tag = "#EXTINF:" in manifest or "#EXT-X-STREAM-INF:" in manifest
            has_uri = any(line.strip() and not line.strip().startswith("#") for line in manifest.splitlines()[1:])
            return has_stream_tag and has_uri
        return len(data) >= 376 and data[0] == 0x47 and data[188] == 0x47
    except (OSError, ValueError):
        return False


def reachable_channels(channels, timeout):
    urls = list(dict.fromkeys(url for lines in channels.values() for url in lines))
    with ThreadPoolExecutor(max_workers=8) as pool:
        results = dict(zip(urls, pool.map(lambda url: probe(url, timeout), urls)))
    return {name: [url for url in urls if results[url]] for name, urls in channels.items()}


def render(channels):
    lines = []
    for title, names in (("央视频道", ORDER[:-len(SATELLITE)]), ("卫视频道", SATELLITE)):
        lines.append(title + ",#genre#")
        for name in names:
            # Repeated same-name rows are merged into backup URLs by Android LiveParser.
            # Unlike URL1#URL2, these rows also remain readable by the existing macOS app.
            lines.extend(name + "," + url for url in channels.get(name, []))
    return "\n".join(lines) + "\n"


def validate_output(text):
    channels = {}
    group = None
    seen = set()
    for line in text.splitlines():
        name, separator, url = line.partition(",")
        if not separator or not name:
            raise UpdateError("invalid TXT row")
        if url == "#genre#":
            if name not in ("央视频道", "卫视频道"):
                raise UpdateError("invalid TXT group")
            group = name
            continue
        key = valid_url(url)
        expected_group = "卫视频道" if name in SATELLITE else "央视频道"
        if (name not in ORDER or key is None or not channel_url_agrees(name, url)
                or group != expected_group or (name, key) in seen):
            raise UpdateError("invalid, duplicate or ungrouped TXT stream")
        seen.add((name, key))
        channels.setdefault(name, []).append(url)
    check_coverage(channels)
    return channels


def atomic_write(path, text):
    """Replace only after the candidate is complete, validated and fsynced."""
    path.parent.mkdir(parents=True, exist_ok=True)
    # Keep a failed temporary file for inspection; never delete the existing playlist.
    with tempfile.NamedTemporaryFile(mode="w", encoding="utf-8", newline="\n",
                                     dir=path.parent, prefix="." + path.name + ".", delete=False) as handle:
        handle.write(text)
        handle.flush()
        os.fsync(handle.fileno())
        temp_path = Path(handle.name)
    temp_path.chmod(path.stat().st_mode & 0o777 if path.exists() else 0o644)
    os.replace(temp_path, path)


def update(output, playlists, check_streams=False, probe_timeout=8, dry_run=False):
    channels, skipped = collect(playlists)
    check_coverage(channels)
    if check_streams:
        channels = reachable_channels(channels, probe_timeout)
        counts = {name: len(urls) for name, urls in channels.items()}
        print("Stream probe results: " + json.dumps(counts, ensure_ascii=False), file=sys.stderr)
        check_coverage(channels)
    text = render(channels)
    validate_output(text)
    changed = not output.exists() or output.read_bytes() != text.encode("utf-8")
    if changed and not dry_run:
        atomic_write(output, text)
    return {"changed": changed, "written": changed and not dry_run, "probe_enabled": check_streams,
            "channel_count": len(channels), "line_count": sum(map(len, channels.values())),
            "skipped_invalid_or_duplicate": skipped,
            "backups": {name: len(urls) - 1 for name, urls in channels.items() if len(urls) > 1}}


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=ROOT / "live.txt")
    parser.add_argument("--input", type=Path, action="append", help="local M3U fixture; repeat for both categories")
    parser.add_argument("--probe", action="store_true", help="keep only streams responding with HLS/TS bytes")
    parser.add_argument("--probe-timeout", type=float, default=8)
    parser.add_argument("--dry-run", action="store_true", help="validate without replacing live.txt")
    args = parser.parse_args(argv)
    if args.probe_timeout <= 0:
        parser.error("probe timeout must be positive")
    try:
        # All downloads must succeed before any change is made.
        playlists = ([(str(path), path.read_text(encoding="utf-8-sig")) for path in args.input]
                     if args.input else [(url, fetch(url)) for url in SOURCES])
        result = update(args.output, playlists, args.probe, args.probe_timeout, args.dry_run)
        print(json.dumps(result, ensure_ascii=False, indent=2))
        return 0
    except (OSError, UnicodeError, UpdateError, ValueError) as exc:
        print("Update failed; existing live.txt retained: " + str(exc), file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
