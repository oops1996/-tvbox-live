#!/usr/bin/env python3
"""Exercise actual patched Java config methods on the JVM and check TV resources.

The Java slice runs production initConfig/initLive/initWall/needSync methods with
in-memory Config/JSON doubles. A synchronous VOD response deliberately exercises
the startup race. It does not test Android rendering, networking or playback.
No user URL, account or third-party interface is fetched or saved.
"""
import argparse
from pathlib import Path
import re
import subprocess
import tempfile
import xml.etree.ElementTree as ET

A = "{http://schemas.android.com/apk/res/android}"


def method(source, signature):
    if source.count(signature) != 1:
        raise AssertionError(f"Expected one production method: {signature}")
    start = source.index(signature)
    opening = source.index("{", start)
    depth = 1
    pos = opening + 1
    # Ignore string/char literals and comments when balancing Java braces.
    token = re.compile(r'"(?:\\.|[^"\\])*"|\'(?:\\.|[^\'\\])*\'|//[^\n]*|/\*[\s\S]*?\*/|[{}]')
    for match in token.finditer(source, pos):
        if match.group() == "{":
            depth += 1
        elif match.group() == "}":
            depth -= 1
        if depth == 0:
            return source[start:match.end()]
    raise AssertionError(f"Unbalanced method: {signature}")


def java_regression(src):
    package = src / "app/src/main/java/com/fongmi/android/tv"
    methods = {}
    for kind in ("WallConfig", "LiveConfig", "VodConfig"):
        text = (package / f"api/config/{kind}.java").read_text()
        signatures = [f"public {kind} init()", f"public {kind} config(Config config)", "public Config getConfig()"]
        if kind == "VodConfig":
            signatures += ["private void initWall(Config config, JsonObject object)", "private void initLive(Config config, JsonObject object)"]
        else:
            signatures += ["public boolean needSync(String url)"]
        methods[kind] = "\n".join(method(text, signature) for signature in signatures)
    home = (src / "app/src/leanback/java/com/fongmi/android/tv/ui/activity/HomeActivity.java").read_text()
    java = r'''
import java.util.*;
public class ConfigRegression {
    static class TextUtils {
        static boolean isEmpty(String s) { return s == null || s.isEmpty(); }
        static boolean equals(String a, String b) { return Objects.equals(a, b); }
    }
    static class Config {
        static Config[] stored = new Config[3];
        String url, name; int type;
        Config(int t, String u, String n) { type=t; url=u; name=n; }
        String getUrl() { return url; } String getName() { return name; }
        boolean isEmpty() { return TextUtils.isEmpty(url); }
        Config save() { return this; }
        Config update() { stored[type]=this; return this; }
        static Config value(int type) { return stored[type] == null ? new Config(type,null,"") : stored[type]; }
        static Config vod() { return value(0); } static Config live() { return value(1); } static Config wall() { return value(2); }
        static Config find(String u,String n,int t) { return new Config(t,u,n); }
        static Config find(Config c,int t) { return new Config(t,c.url,c.name); }
        static Config create(int t,String u,String n) { return new Config(t,u,n); }
    }
    static class JsonObject extends HashMap<String,String> {}
    static class Json {
        static boolean isEmpty(JsonObject o,String key) { return TextUtils.isEmpty(o.get(key)); }
        static String safeString(JsonObject o,String key) { return o.getOrDefault(key,""); }
    }
    static class FamilySourcesActivity { static boolean isDisabled(Config c) { return false; } }
    static class WallConfig {
        static WallConfig instance; Config config; boolean sync;
        static WallConfig get() { return instance; }
        /*WALL_METHODS*/
    }
    static class LiveConfig {
        static LiveConfig instance; Config config; boolean sync; int parses;
        static LiveConfig get() { return instance; }
        void parse(JsonObject o) { parses++; }
        void load() { check(config != null,"live load preceded initialization"); }
        /*LIVE_METHODS*/
    }
    static class VodConfig {
        static VodConfig instance; Config config; String wall; JsonObject response;
        static VodConfig get() { return instance; }
        static String getUrl() { return get().getConfig().getUrl(); }
        String getWall() { return wall; }
        void load(Object callback) {
            check(LiveConfig.get().config != null,"VOD dispatched before live initialization");
            check(WallConfig.get().config != null,"VOD dispatched before wallpaper initialization");
            initLive(config,response); initWall(config,response);
        }
        /*VOD_METHODS*/
    }
    static class Home {
        Object getCallback() { return new Object(); }
        void setRefreshing(boolean b) {}
        /*HOME_METHOD*/
    }
    static void reset() {
        Config.stored = new Config[3];
        WallConfig.instance = new WallConfig(); LiveConfig.instance = new LiveConfig(); VodConfig.instance = new VodConfig();
        VodConfig.get().response = new JsonObject();
    }
    static void check(boolean ok,String msg) { if(!ok) throw new AssertionError(msg); }
    static void parse(String wallpaper, boolean lives) {
        JsonObject json = new JsonObject();
        if(wallpaper != null) json.put("wallpaper",wallpaper);
        if(lives) json.put("lives","test-local-live-data");
        Config source = new Config(0,"https://example.invalid/source.json","local fixture");
        VodConfig.get().config(source);
        VodConfig.get().initLive(source,json); VodConfig.get().initWall(source,json);
    }
    public static void main(String[] args) {
        // A source manager opened without HomeActivity must also be safe.
        reset(); parse("https://example.invalid/wall.jpg",false);
        check("https://example.invalid/wall.jpg".equals(WallConfig.get().config.getUrl()),"cold wallpaper did not synchronize");
        System.out.println("PASS cold source load with wallpaper");
        reset(); parse(null,true);
        check(LiveConfig.get().parses == 1,"cold live section did not synchronize");
        System.out.println("PASS cold source load with live section");
        // Previously stored independent settings must retain synchronization rules.
        reset(); new Config(2,"https://example.invalid/user-wall.jpg","stored").update();
        new Config(1,"https://example.invalid/user-live.txt","stored").update();
        parse("https://example.invalid/other.jpg",true);
        check(WallConfig.get().config == null,"independent saved wallpaper was overwritten");
        check(LiveConfig.get().parses == 0,"independent saved live configuration was overwritten");
        System.out.println("PASS independent saved wallpaper and live settings");
        reset(); parse(null,false); parse("",false);
        check(WallConfig.get().config == null,"empty wallpaper changed stored state");
        parse("https://example.invalid/a.jpg",false); parse("https://example.invalid/b.jpg",false);
        check("https://example.invalid/b.jpg".equals(WallConfig.get().config.getUrl()),"source switch failed to update synchronized wallpaper");
        System.out.println("PASS no wallpaper, empty wallpaper and source switching");
        // Execute actual HomeActivity.initConfig with the fastest possible response.
        reset(); VodConfig.get().response.put("wallpaper","https://example.invalid/home.jpg");
        VodConfig.get().response.put("lives","test-local-live-data"); new Home().initConfig();
        check("https://example.invalid/home.jpg".equals(WallConfig.get().config.getUrl()),"cold home config did not parse");
        System.out.println("PASS cold HomeActivity with immediate configuration response");
    }
}
'''
    for kind, tag in (("WallConfig", "WALL"), ("LiveConfig", "LIVE"), ("VodConfig", "VOD")):
        java = java.replace(f"/*{tag}_METHODS*/", methods[kind])
    java = java.replace("/*HOME_METHOD*/", method(home, "private void initConfig()"))
    # Keep temporary evidence rather than deleting generated sources.
    work = Path(tempfile.mkdtemp(prefix="family-tv-regression-"))
    source = work / "ConfigRegression.java"
    source.write_text(java)
    subprocess.run(["javac", "-encoding", "UTF-8", str(source)], check=True)
    subprocess.run(["java", "-cp", str(work), "ConfigRegression"], check=True)


def contrast(fg, bg):
    def luminance(color):
        rgb = [int(color[i:i+2], 16)/255 for i in (1, 3, 5)]
        rgb = [c/12.92 if c <= .04045 else ((c+.055)/1.055)**2.4 for c in rgb]
        return sum(c*w for c, w in zip(rgb, (.2126, .7152, .0722)))
    a, b = sorted((luminance(fg), luminance(bg)))
    return (b+.05)/(a+.05)


def settings_regression(src):
    res = src / "app/src/leanback/res"
    layout = ET.parse(res / "layout/activity_setting.xml").getroot()
    values = ET.parse(res / "values/family_ui.xml").getroot()
    styles = {s.attrib['name']: {i.attrib['name']: i.text for i in s} for s in values.findall('style')}
    rows = {v.attrib.get(A+'id', '').split('/')[-1]: v for v in layout.iter()}
    expected = {"familyStartup": "开机自动启动 · 权限与桌面设置", "familyMedia": "OpenList / WebDAV · 我的媒体", "familySources": "接口管理（本机保存）"}
    settings = (src / "app/src/leanback/java/com/fongmi/android/tv/ui/activity/SettingActivity.java").read_text()
    for name, label in expected.items():
        row = rows[name]
        assert row.attrib[A+'text'] == label
        style = styles[row.attrib['style'].split('/')[-1]]
        assert style['android:focusable'] == 'true'
        assert style['android:focusableInTouchMode'] == 'true'
        assert f"mBinding.{name}.setOnClickListener" in settings
        selector = ET.parse(res / (style['android:background'].split('@')[1] + '.xml')).getroot()
        ratios = [contrast(style['android:textColor'], item.find('shape/solid').attrib[A+'color']) for item in selector]
        assert min(ratios) >= 4.5, (name, ratios)
        focused = next(item for item in selector if item.attrib.get(A+'state_focused') == 'true')
        assert focused.find('shape/stroke') is not None
        print(f"PASS {label}: minimum contrast {min(ratios):.2f}:1 with visible focus")
    for before, after in zip((*expected, 'vod'), (*expected, 'vod')[1:]):
        assert rows[before].attrib[A+'nextFocusDown'] == '@id/'+after
    base = (src / 'app/src/leanback/java/com/fongmi/android/tv/ui/base/BaseActivity.java').read_text()
    assert 'return false;' in method(base, 'protected boolean customWall()')
    print('PASS settings focus order and wallpaper rendering disabled')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('source', type=Path, help='Fresh customized upstream checkout')
    parser.add_argument('--only', choices=['config', 'settings'])
    args = parser.parse_args()
    if args.only != 'settings': java_regression(args.source)
    if args.only != 'config': settings_regression(args.source)
