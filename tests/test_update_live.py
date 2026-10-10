"""Regression checks for real playlist corruption and update failure cases."""

import contextlib
import importlib.util
import io
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
from urllib.error import URLError


spec = importlib.util.spec_from_file_location("update_live", Path(__file__).resolve().parents[1] / "scripts/update-live.py")
updater = importlib.util.module_from_spec(spec)
spec.loader.exec_module(updater)


def playlist(names, host="streams.example.org"):
    return "#EXTM3U\n" + "".join(
        '#EXTINF:-1 tvg-name="' + name + '",' + name + "\nhttps://" + host + "/" + str(index) + ".m3u8\n"
        for index, name in enumerate(names))


def complete_playlists():
    return [("cctv", playlist(["CCTV" + str(i) for i in range(1, 18)])),
            ("satellite", playlist(["江西卫视", "湖南卫视", "浙江卫视", "江苏卫视", "东方卫视", "广东卫视", "北京卫视", "深圳卫视"], "satellite.example.org"))]


class UpdateTests(unittest.TestCase):
    def setUp(self):
        # Keep generated test files for inspection; no bulk cleanup of directories.
        self.output = Path(tempfile.mkdtemp(prefix="family-tv-test-")) / "live.txt"
        self.original = b"existing known playlist\r\n"
        self.output.write_bytes(self.original)

    def test_complete_categories_and_backups_round_trip(self):
        sources = complete_playlists()
        sources[0] = ("cctv", sources[0][1] + '#EXTINF:-1,CCTV-1高清\nhttps://backup.example.org/one.m3u8\n'
                      + '#EXTINF:-1,CCTV5+ 体育赛事\nhttps://backup.example.org/fiveplus.m3u8\n')
        result = updater.update(self.output, sources)
        text = self.output.read_text()
        self.assertTrue(result["written"])
        self.assertEqual(result["channel_count"], 26)
        self.assertEqual(result["backups"], {"CCTV1": 1})
        self.assertEqual(text.splitlines()[0], "央视频道,#genre#")
        self.assertIn("卫视频道,#genre#", text)
        self.assertEqual([line.split(",")[0] for line in text.splitlines() if line.startswith("CCTV1,")], ["CCTV1", "CCTV1"])
        self.assertIn("CCTV5+,https://backup.example.org/fiveplus.m3u8", text)
        self.assertLess(text.index("CCTV5+,"), text.index("CCTV6,"))
        self.assertEqual(len(updater.validate_output(text)["CCTV1"]), 2)

    def test_bom_crlf_attributes_with_commas_and_metadata_fallback(self):
        text = '\ufeff#EXTM3U\r\n#EXTINF:-1 tvg-logo="https://example.org/a,b.png" tvg-name="CCTV2 财经",别名\r\n#comment\r\nhttps://example.org/two.m3u8\r\n'
        self.assertEqual(updater.parse_m3u(text, "test"), [("CCTV2", "https://example.org/two.m3u8")])

    def test_numeric_sort_and_no_uhd_mislabel(self):
        for name in ("CCTV4K 超高清", "CCTV8K", "CCTV123", "CCTV18", "CCTV6+"):
            self.assertIsNone(updater.channel_name(name), name)
        self.assertEqual(updater.channel_name("ＣＣＴＶ－１０ 科教 HD"), "CCTV10")
        self.assertEqual(updater.channel_name("CCTV5PLUS 体育赛事"), "CCTV5+")
        self.assertEqual(updater.channel_name("CCTV16 奥林匹克 4K"), "CCTV16")

    def test_dedup_preserves_query_order_and_separate_channels(self):
        text = playlist(["CCTV1", "CCTV2"])
        text += '#EXTINF:-1,CCTV1高清\nHTTPS://STREAMS.EXAMPLE.ORG:443/0.m3u8\n'
        text += '#EXTINF:-1,CCTV1\nhttps://streams.example.org/0.m3u8?b=2&a=1\n'
        text += '#EXTINF:-1,CCTV1\nhttps://streams.example.org/0.m3u8?a=1&b=2\n'
        text += '#EXTINF:-1,CCTV2\nhttps://streams.example.org/0.m3u8\n'
        channels, skipped = updater.collect([("test", text)])
        self.assertEqual(skipped, 1)
        self.assertEqual(len(channels["CCTV1"]), 3)
        self.assertEqual(len(channels["CCTV2"]), 2)
        self.assertTrue(channels["CCTV1"][1].endswith("?b=2&a=1"))

    def test_known_bad_sources_invalid_addresses_and_injected_syntax(self):
        urls = ["http://74.91.26.218:82/live/one.m3u8", "http://107.150.60.122/live/two.m3u8",
                "http://127.0.0.1/a", "http://192.168.1.1/a", "file:///tmp/a", "rtsp://example.org/a",
                "http://localhost/a", "http://example.org:70000/a", "http://user:pass@example.org/a",
                "http://example.org/a#http://example.org/b", "http://example.org/a|User-Agent=x",
                "http://example.org/a$label", "http://example.org/a b", "http://example.org/a\x00"]
        for url in urls:
            self.assertIsNone(updater.valid_url(url), url)
        self.assertIsNotNone(updater.valid_url("https://example.org/a?token=A%2FB&x=2"))
        self.assertIsNotNone(updater.valid_url("https://[2606:4700:4700::1111]/a"))

    def test_supplement_mislabeled_uhd_and_sports_plus_are_excluded(self):
        text = playlist(["CCTV4", "CCTV5"])
        text += '#EXTINF:-1,CCTV4\nhttp://example.org/gslb/live.m3u8?id=cctv4k\n'
        text += '#EXTINF:-1,CCTV5\nhttp://example.org/live/cctv5p.m3u8\n'
        text += '#EXTINF:-1,CCTV5\nhttp://example.org/live/cctv5plus.m3u8\n'
        text += '#EXTINF:-1,CCTV5+\nhttp://example.org/live/cctv5p.m3u8\n'
        channels, skipped = updater.collect([("mislabeled", text)])
        self.assertEqual(skipped, 3)
        self.assertEqual(len(channels["CCTV4"]), 1)
        self.assertEqual(len(channels["CCTV5"]), 1)
        self.assertEqual(len(channels["CCTV5+"]), 1)

    def test_missing_cctv8_never_replaces_existing_file(self):
        sources = complete_playlists()
        sources[0] = ("cctv", playlist(["CCTV" + str(i) for i in range(1, 18) if i != 8]))
        with self.assertRaisesRegex(updater.UpdateError, "CCTV8"):
            updater.update(self.output, sources)
        self.assertEqual(self.output.read_bytes(), self.original)

    def test_supplement_fills_missing_channel_and_adds_backup(self):
        sources = complete_playlists()
        sources[0] = ("cctv", playlist(["CCTV" + str(i) for i in range(1, 18) if i != 8]))
        sources.append(("supplement", playlist(["CCTV-8 电视剧", "CCTV1"], "supplement.example.org")))
        result = updater.update(self.output, sources)
        self.assertTrue(result["written"])
        self.assertEqual(result["channel_count"], 25)
        self.assertIn("CCTV8,https://supplement.example.org/0.m3u8", self.output.read_text())
        self.assertEqual(result["backups"], {"CCTV1": 1})

    def test_failed_supplement_download_retains_existing_file(self):
        with patch.object(updater, "fetch", side_effect=[item[1] for item in complete_playlists()] + [updater.UpdateError("supplement failed")]):
            with contextlib.redirect_stderr(io.StringIO()):
                self.assertEqual(updater.main(["--output", str(self.output)]), 1)
        self.assertEqual(self.output.read_bytes(), self.original)

    def test_missing_satellite_never_replaces_existing_file(self):
        sources = complete_playlists()
        sources[1] = ("satellite", playlist(["湖南卫视"]))
        with self.assertRaisesRegex(updater.UpdateError, "江西卫视"):
            updater.update(self.output, sources)
        self.assertEqual(self.output.read_bytes(), self.original)

    def test_empty_html_and_truncated_playlists_fail_safely(self):
        bad_inputs = ["", "<html>upstream error</html>", "#EXTM3U\n",
                      "#EXTM3U\n#EXTINF:-1,CCTV1\n", "#EXTM3U\nhttps://example.org/a\n",
                      "#EXTM3U\n#EXTINF:-1,CCTV1\n#EXTINF:-1,CCTV2\nhttps://example.org/a\n",
                      "#EXTM3U\n#EXTINF:-1 CCTV1\nhttps://example.org/a\n"]
        for text in bad_inputs:
            with self.subTest(text=text):
                with self.assertRaises(updater.UpdateError):
                    updater.update(self.output, [("bad", text)])
                self.assertEqual(self.output.read_bytes(), self.original)

    def test_header_dependent_entry_is_not_silently_converted(self):
        text = '#EXTM3U\n#EXTINF:-1,CCTV1\n#EXTVLCOPT:http-user-agent=special\nhttps://example.org/a\n'
        with self.assertRaises(updater.UpdateError):
            updater.parse_m3u(text, "headers")
        with self.assertRaises(updater.UpdateError):
            updater.parse_m3u('#EXTM3U\n#EXTVLCOPT:http-user-agent=special\n' + text.split("\n", 1)[1], "global headers")

    def test_dry_run_leaves_file_untouched(self):
        result = updater.update(self.output, complete_playlists(), dry_run=True)
        self.assertTrue(result["changed"])
        self.assertFalse(result["written"])
        self.assertEqual(self.output.read_bytes(), self.original)

    def test_unchanged_content_does_not_rewrite_file(self):
        updater.update(self.output, complete_playlists())
        before = self.output.stat()
        with patch.object(updater, "atomic_write") as write:
            result = updater.update(self.output, complete_playlists())
        write.assert_not_called()
        self.assertFalse(result["changed"])
        self.assertEqual(self.output.stat().st_mtime_ns, before.st_mtime_ns)

    def test_atomic_replace_failure_leaves_old_bytes(self):
        with patch.object(updater.os, "replace", side_effect=OSError("simulated disk error")):
            with self.assertRaises(OSError):
                updater.update(self.output, complete_playlists())
        self.assertEqual(self.output.read_bytes(), self.original)

    def test_failed_second_download_does_not_write_first_category(self):
        with patch.object(updater, "fetch", side_effect=[complete_playlists()[0][1], updater.UpdateError("download failed")]):
            with contextlib.redirect_stderr(io.StringIO()):
                self.assertEqual(updater.main(["--output", str(self.output)]), 1)
        self.assertEqual(self.output.read_bytes(), self.original)

    def test_transient_fetch_failure_retries(self):
        response = io.BytesIO(b"#EXTM3U\n")
        response.status = 200
        with patch.object(updater, "urlopen", side_effect=[URLError("timeout"), response]) as request:
            with patch.object(updater.time, "sleep"):
                self.assertEqual(updater.fetch("https://example.org/list.m3u"), "#EXTM3U\n")
        self.assertEqual(request.call_count, 2)

    def test_failed_probe_of_every_line_leaves_original(self):
        with patch.object(updater, "probe", return_value=False):
            with self.assertRaises(updater.UpdateError):
                updater.update(self.output, complete_playlists(), check_streams=True)
        self.assertEqual(self.output.read_bytes(), self.original)

    def test_reachable_backup_replaces_failed_primary(self):
        sources = complete_playlists()
        sources[0] = ("cctv", sources[0][1] + '#EXTINF:-1,CCTV1\nhttps://backup.example.org/one.m3u8\n')
        with patch.object(updater, "probe", side_effect=lambda url, timeout: url != "https://streams.example.org/0.m3u8"):
            result = updater.update(self.output, sources, check_streams=True)
        self.assertTrue(result["probe_enabled"])
        self.assertIn("CCTV1,https://backup.example.org/one.m3u8", self.output.read_text())
        self.assertNotIn("CCTV1,https://streams.example.org/0.m3u8", self.output.read_text())

    def test_probe_rejects_http_200_html_but_accepts_hls_and_ts(self):
        for data, expected in [(b"<html>error</html>", False), (b"#EXTM3U\n", False),
                               (b"#EXTM3U\n#EXTINF:6,\nsegment.ts", True),
                               (b"G" + b"\0" * 187 + b"G" + b"\0" * 187, True), (b"", False)]:
            response = io.BytesIO(data)
            response.status = 200
            with patch.object(updater, "urlopen", return_value=response):
                self.assertEqual(updater.probe("https://example.org/a"), expected)

    def test_probe_rejects_recorded_programme_endlist_beyond_first_chunk(self):
        data = b"#EXTM3U\n" + b"#EXTINF:6,\nsegment.ts\n" * 400 + b"#EXT-X-ENDLIST\n"
        self.assertGreater(len(data), 4096)
        response = io.BytesIO(data)
        response.status = 200
        with patch.object(updater, "urlopen", return_value=response):
            self.assertFalse(updater.probe("https://example.org/vod.m3u8"))

    def test_probe_rejects_redirect_to_known_bad_network(self):
        response = io.BytesIO(b"#EXTM3U\n#EXTINF:6,\nsegment.ts\n")
        response.status = 200
        response.geturl = lambda: "http://74.91.26.218/live/cctv1.m3u8"
        with patch.object(updater, "urlopen", return_value=response):
            self.assertFalse(updater.probe("https://example.org/redirect.m3u8"))

    def test_invalid_or_duplicate_output_is_rejected(self):
        channels, _ = updater.collect(complete_playlists())
        text = updater.render(channels)
        with self.assertRaises(updater.UpdateError):
            updater.validate_output(text + "CCTV1,https://streams.example.org/0.m3u8\n")
        with self.assertRaises(updater.UpdateError):
            updater.validate_output(text.replace("央视频道,#genre#\n", ""))


if __name__ == "__main__":
    unittest.main()
