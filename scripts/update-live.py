#!/usr/bin/env python3
"""Maintain TVBox TXT with core channels plus local, drama and regional extras."""

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
LABELLED_OPTIONAL_SOURCE = "https://raw.githubusercontent.com/xiongjian83/TvBox/main/live.m3u"
OPTIONAL_SOURCES = (
    "https://raw.githubusercontent.com/iptv-org/iptv/master/streams/cn.m3u",
    "https://iptv-org.github.io/iptv/countries/tw.m3u",
    "https://iptv-org.github.io/iptv/countries/hk.m3u",
    "https://iptv-org.github.io/iptv/countries/mo.m3u",
    LABELLED_OPTIONAL_SOURCE,
)
CCTV = tuple("CCTV" + str(i) for i in range(1, 18))
CORE_SATELLITE = ("江西卫视", "湖南卫视", "浙江卫视", "江苏卫视", "东方卫视", "广东卫视", "北京卫视", "深圳卫视")
SATELLITE = CORE_SATELLITE + ("辽宁卫视", "吉林卫视", "黑龙江卫视", "新疆卫视", "山东卫视", "河南卫视",
                              "四川卫视", "湖北卫视", "安徽卫视", "东南卫视")
JIANGXI = ("江西都市", "江西经济生活", "江西影视", "江西公共农业", "江西少儿", "南昌新闻综合",
           "赣州新闻综合", "赣州公共", "赣州教育", "萍乡新闻综合", "抚州公共")
DRAMA = ("第一剧场", "风云剧场", "怀旧剧场", "都市剧场", "欢笑剧场", "湖南电视剧", "福建电视剧", "淘剧场")
ANIMATION = ("金鹰卡通", "优漫卡通", "卡酷动画", "炫动卡通", "动漫秀场", "爱动漫")
TAIWAN = ("台视", "华视", "TVBS亚洲")
HONG_KONG = ("翡翠台", "凤凰香港", "凤凰中文")
MACAO = ("澳视澳门", "澳门莲花")
GROUPS = (("央视频道", CCTV[:5] + ("CCTV5+",) + CCTV[5:]), ("卫视频道", SATELLITE),
          ("江西本地", JIANGXI), ("电视剧场", DRAMA), ("动漫少儿", ANIMATION),
          ("台湾频道", TAIWAN), ("香港频道", HONG_KONG), ("澳门频道", MACAO))
ORDER = tuple(name for _, names in GROUPS for name in names)
REQUIRED = CCTV + CORE_SATELLITE
CHANNEL_GROUP = {name: title for title, names in GROUPS for name in names}
OPTIONAL_CHANNELS = set(ORDER) - set(REQUIRED) - {"CCTV5+"}

# Exact aliases avoid treating a similarly named shopping/news channel as a
# requested general channel. English names and IDs come from iptv-org metadata.
ALIASES = {
    "上海卫视": "东方卫视", "BTV北京卫视": "北京卫视", "福建卫视": "东南卫视",
    "江西都市频道": "江西都市", "江西经济·生活": "江西经济生活", "江西公共·农业": "江西公共农业",
    "江西公共": "江西公共农业", "江西家庭少儿": "江西少儿", "江西少儿频道": "江西少儿",
    "赣州新闻": "赣州新闻综合", "哈哈炫动": "炫动卡通", "卡酷少儿": "卡酷动画",
    "萍鄉新聞綜合": "萍乡新闻综合", "Pingxiang TV News Channel": "萍乡新闻综合",
    "PingxiangTVNewsChannel.cn": "萍乡新闻综合",
    "臺視": "台视", "台視": "台视", "台视主频": "台视", "華視": "华视",
    "TVBS-ASIA": "TVBS亚洲", "鳳凰香港": "凤凰香港", "凤凰香港台": "凤凰香港",
    "凤凰中文台": "凤凰中文", "鳳凰中文": "凤凰中文", "澳視澳門": "澳视澳门",
    "澳视澳门台": "澳视澳门", "澳門蓮花": "澳门莲花", "澳门莲花台": "澳门莲花",
    "Jiangxi City Channel": "江西都市", "JiangxiCityChannel.cn": "江西都市",
    "Jiangxi Economy & Life Channel": "江西经济生活", "JiangxiEconomyLifeChannel.cn": "江西经济生活",
    "Jiangxi Movie Channel": "江西影视", "JiangxiMovieChannel.cn": "江西影视",
    "Jiangxi Public & Agriculture Channel": "江西公共农业", "JiangxiPublicAgricultureChannel.cn": "江西公共农业",
    "Jiangxi Children's Channel": "江西少儿", "JiangxiChildrensChannel.cn": "江西少儿",
    "Nanchang News & Generalist Channel": "南昌新闻综合", "NanchangNewsGeneralistChannel.cn": "南昌新闻综合",
    "Golden Eagle Cartoon": "金鹰卡通", "You Man Cartoon Channel": "优漫卡通",
    "TTV": "台视", "TTV.tw": "台视", "CTS": "华视", "CTS.tw": "华视",
    "TVBS-Asia": "TVBS亚洲", "TVBSAsia.tw": "TVBS亚洲",
    "Jade": "翡翠台", "Jade.hk": "翡翠台", "Phoenix Chinese Channel": "凤凰中文",
    "PhoenixChineseChannel.hk": "凤凰中文", "TDM Ou Mun": "澳视澳门", "TDMOuMun.mo": "澳视澳门",
    "Lotus TV": "澳门莲花", "LotusTV.mo": "澳门莲花",
}
ALIASES = {re.sub(r"\s+", "", unicodedata.normalize("NFKC", key)).upper(): value
           for key, value in ALIASES.items()}
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
    # Strip only documented quality/availability markers, not arbitrary words.
    while True:
        clean = re.sub(r"(?:\(\d{3,4}[PI]\)|\[(?:GEO-BLOCKED|NOT24/7)\]|超高清|高清|超清|FHD|HD|4K)$", "", value)
        if clean == value:
            break
        value = clean
    value = value.split("@", 1)[0]
    if value in CHANNEL_GROUP:
        return value
    return ALIASES.get(value)


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


def entry_channel(entry):
    display, attributes = entry
    return next((name for value in (display, attributes.get("tvg-name", ""), attributes.get("tvg-id", ""))
                 if (name := channel_name(value))), None)


def parse_m3u(text, label, allow_unselected=False):
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
            name = entry_channel(pending)
            if name is not None and not needs_headers:
                records.append((name, line))
            pending = None
    if pending is not None:
        raise UpdateError(label + ": truncated final entry")
    if not records and not allow_unselected:
        raise UpdateError(label + ": no selected channels")
    return records


def optional_playlist(text, label, strip_display_labels=False):
    """Supplement new groups only, retaining the original core source priority."""
    lines = [line.strip() for line in text.lstrip("\ufeff").splitlines() if line.strip()]
    if not lines or lines[0].split(maxsplit=1)[0] != "#EXTM3U":
        raise UpdateError(label + ": not an extended M3U playlist")
    # Some large catalogues have empty entries for unrelated channels. Ignore
    # those entries before parsing, but strictly validate every selected entry
    # and preserve global/header settings so they cannot become broken bare URLs.
    filtered = [lines[0]]
    selected = False
    first_entry = True
    for line in lines[1:]:
        if line.startswith("#EXTINF:"):
            first_entry = False
            selected = entry_channel(extinf(line)) in OPTIONAL_CHANNELS
        if selected or first_entry:
            if strip_display_labels and not line.startswith("#"):
                # This source appends a TVBox display label, not request headers.
                # Remove only its documented literal pattern; all other control
                # syntax remains rejected by valid_url().
                line = re.sub(r"\$LR•IPV[46]『线路\d+』$", "", line)
            filtered.append(line)
    records = parse_m3u("\n".join(filtered), label, allow_unselected=True)
    if not records:
        return None
    return "#EXTM3U\n" + "".join("#EXTINF:-1," + name + "\n" + url + "\n" for name, url in records)


def remote_playlists():
    # Fail closed for the three original core upstreams. Extra regional sources
    # may be unavailable without preventing a valid core update.
    playlists = [(url, fetch(url)) for url in SOURCES]
    for label, text in playlists:
        parse_m3u(text, label)
    failures = []
    for url in OPTIONAL_SOURCES:
        try:
            selected = optional_playlist(fetch(url, timeout=15, attempts=2), url,
                                         strip_display_labels=url == LABELLED_OPTIONAL_SOURCE)
            if selected is not None:
                playlists.append((url, selected))
        except (OSError, UnicodeError, UpdateError, ValueError) as exc:
            failures.append(url)
            print("Optional upstream skipped: " + url + ": " + str(exc), file=sys.stderr)
    return playlists, failures


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
    reachable = {name: [url for url in lines if results[url]] for name, lines in channels.items()}
    return {name: lines for name, lines in reachable.items() if lines}


def render(channels):
    lines = []
    for title, names in GROUPS:
        if not any(channels.get(name) for name in names):
            continue
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
            if name not in {title for title, _ in GROUPS}:
                raise UpdateError("invalid TXT group")
            group = name
            continue
        key = valid_url(url)
        expected_group = CHANNEL_GROUP.get(name)
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
            "backups": {name: len(urls) - 1 for name, urls in channels.items() if len(urls) > 1},
            "missing_optional_channels": [name for name in ORDER if name in OPTIONAL_CHANNELS and not channels.get(name)],
            "groups": {title: sum(bool(channels.get(name)) for name in names) for title, names in GROUPS
                       if any(channels.get(name) for name in names)}}


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
        if args.input:
            playlists = [(str(path), path.read_text(encoding="utf-8-sig")) for path in args.input]
            failures = []
        else:
            playlists, failures = remote_playlists()
        result = update(args.output, playlists, args.probe, args.probe_timeout, args.dry_run)
        result["optional_upstream_failures"] = failures
        print(json.dumps(result, ensure_ascii=False, indent=2))
        return 0
    except (OSError, UnicodeError, UpdateError, ValueError) as exc:
        print("Update failed; existing live.txt retained: " + str(exc), file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
