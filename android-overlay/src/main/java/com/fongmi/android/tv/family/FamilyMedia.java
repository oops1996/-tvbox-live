package com.fongmi.android.tv.family;

import android.content.SharedPreferences;
import android.util.Base64;
import android.util.Xml;

import com.fongmi.android.tv.App;
import com.fongmi.android.tv.bean.Result;
import com.fongmi.android.tv.bean.Vod;

import org.json.JSONArray;
import org.json.JSONObject;
import org.xmlpull.v1.XmlPullParser;

import java.io.IOException;
import java.io.StringReader;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.Collections;
import java.util.HashMap;
import java.util.List;
import java.util.concurrent.TimeUnit;

import okhttp3.Credentials;
import okhttp3.HttpUrl;
import okhttp3.MediaType;
import okhttp3.OkHttpClient;
import okhttp3.Request;
import okhttp3.RequestBody;
import okhttp3.Response;

/** Connection details stay in app-private storage; IDs contain only mode and path. */
public final class FamilyMedia {
    private static final OkHttpClient CLIENT = new OkHttpClient.Builder()
            .connectTimeout(15, TimeUnit.SECONDS).readTimeout(20, TimeUnit.SECONDS)
            .followRedirects(false).followSslRedirects(false).build();
    private static final MediaType JSON = MediaType.get("application/json; charset=utf-8");

    public static final class Entry {
        public final String name, path;
        public final boolean folder;
        public Entry(String name, String path, boolean folder) {
            this.name = name; this.path = path; this.folder = folder;
        }
        @Override public String toString() { return (folder ? "📁 " : "▶ ") + name; }
    }

    public static SharedPreferences prefs() {
        return App.get().getSharedPreferences("family_media_private", 0);
    }

    public static String get(String mode, String key) {
        return prefs().getString(mode + "_" + key, "");
    }

    public static void save(String mode, String endpoint, String user, String password, String root) {
        HttpUrl parsed = HttpUrl.parse(endpoint.trim());
        if (parsed == null || !parsed.username().isEmpty() || !parsed.password().isEmpty()
                || parsed.query() != null || parsed.fragment() != null) {
            throw new IllegalArgumentException("请输入不含账号、密码或查询参数的 HTTP(S) 服务地址");
        }
        String url = parsed.toString();
        if (!url.endsWith("/")) url += "/";
        prefs().edit().putString(mode + "_url", url).putString(mode + "_user", user.trim())
                .putString(mode + "_password", password).putString(mode + "_root", root.trim()).apply();
    }

    public static String root(String mode) {
        if ("webdav".equals(mode)) return HttpUrl.get(get(mode, "url")).encodedPath();
        String path = get(mode, "root");
        return path.isEmpty() ? "/" : path.startsWith("/") ? path : "/" + path;
    }

    private static String request(Request request) throws IOException {
        try (Response response = CLIENT.newCall(request).execute()) {
            if (!response.isSuccessful() || response.body() == null)
                throw new IOException("连接失败，HTTP " + response.code());
            return response.body().string();
        }
    }

    private static JSONObject post(String endpoint, String api, JSONObject body, String token) throws Exception {
        Request.Builder req = new Request.Builder().url(HttpUrl.get(endpoint).resolve(api.replaceFirst("^/", "")))
                .post(RequestBody.create(body.toString(), JSON));
        if (!token.isEmpty()) req.header("Authorization", token);
        JSONObject result = new JSONObject(request(req.build()));
        if (result.optInt("code") != 200) throw new IOException("服务拒绝请求，请核对账号、路径和访问权限");
        return result.getJSONObject("data");
    }

    private static String token() throws Exception {
        if (get("openlist", "user").isEmpty()) return "";
        return post(get("openlist", "url"), "/api/auth/login", new JSONObject()
                .put("username", get("openlist", "user")).put("password", get("openlist", "password")), "")
                .getString("token");
    }

    private static JSONObject fileBody(String path) throws Exception {
        return new JSONObject().put("path", path).put("password", "");
    }

    public static List<Entry> list(String mode, String path) throws Exception {
        List<Entry> entries = "openlist".equals(mode) ? listOpenList(path) : listWebDav(path);
        entries.sort((a, b) -> a.folder != b.folder ? (a.folder ? -1 : 1) : a.name.compareToIgnoreCase(b.name));
        return entries;
    }

    private static List<Entry> listOpenList(String path) throws Exception {
        JSONArray content = post(get("openlist", "url"), "/api/fs/list",
                fileBody(path).put("page", 1).put("per_page", 0).put("refresh", false), token()).optJSONArray("content");
        List<Entry> result = new ArrayList<>();
        if (content == null) return result;
        for (int i = 0; i < content.length(); i++) {
            JSONObject item = content.getJSONObject(i);
            String name = item.getString("name");
            if (name.contains("/") || name.equals(".") || name.equals("..")) continue;
            boolean folder = item.optBoolean("is_dir");
            if (folder || isMedia(name)) result.add(new Entry(name, path.replaceAll("/+$", "") + "/" + name, folder));
        }
        return result;
    }

    private static HttpUrl webDavUrl(String path) throws IOException {
        HttpUrl root = HttpUrl.get(get("webdav", "url"));
        HttpUrl target = root.resolve(path);
        if (target == null || !root.scheme().equals(target.scheme()) || !root.host().equals(target.host())
                || root.port() != target.port() || !target.encodedPath().startsWith(root.encodedPath())
                || target.query() != null || target.fragment() != null) throw new IOException("目录地址超出已配置的 WebDAV 范围");
        return target;
    }

    private static String webDavAuth() {
        return Credentials.basic(get("webdav", "user"), get("webdav", "password"), StandardCharsets.UTF_8);
    }

    private static List<Entry> listWebDav(String path) throws Exception {
        HttpUrl current = webDavUrl(path.endsWith("/") ? path : path + "/");
        String body = "<d:propfind xmlns:d=\"DAV:\"><d:prop><d:displayname/><d:resourcetype/></d:prop></d:propfind>";
        String xml = request(new Request.Builder().url(current).header("Authorization", webDavAuth())
                .header("Depth", "1").method("PROPFIND", RequestBody.create(body, MediaType.get("application/xml"))).build());
        XmlPullParser parser = Xml.newPullParser();
        parser.setFeature(XmlPullParser.FEATURE_PROCESS_NAMESPACES, true);
        parser.setInput(new StringReader(xml));
        List<Entry> result = new ArrayList<>();
        String href = null, name = null;
        boolean folder = false;
        for (int event = parser.getEventType(); event != XmlPullParser.END_DOCUMENT; event = parser.next()) {
            if (event == XmlPullParser.START_TAG && "response".equals(parser.getName())) {
                href = name = null; folder = false;
            } else if (event == XmlPullParser.START_TAG && "href".equals(parser.getName())) href = parser.nextText();
            else if (event == XmlPullParser.START_TAG && "displayname".equals(parser.getName())) name = parser.nextText();
            else if (event == XmlPullParser.START_TAG && "collection".equals(parser.getName())) folder = true;
            else if (event == XmlPullParser.END_TAG && "response".equals(parser.getName()) && href != null) {
                HttpUrl child = current.resolve(href);
                if (child == null) continue;
                try { child = webDavUrl(child.toString()); } catch (IOException ignored) { continue; }
                if (child.encodedPath().replaceAll("/+$", "").equals(current.encodedPath().replaceAll("/+$", ""))) continue;
                if (name == null || name.isEmpty()) {
                    List<String> segments = child.pathSegments();
                    int last = segments.size() - 1;
                    while (last > 0 && segments.get(last).isEmpty()) last--;
                    name = segments.get(last);
                }
                if (folder || isMedia(name)) result.add(new Entry(name, child.encodedPath(), folder));
            }
        }
        return result;
    }

    private static boolean isMedia(String name) {
        return name.toLowerCase(java.util.Locale.ROOT).matches(".*\\.(mp4|mkv|m4v|mov|avi|ts|m2ts|webm|flv|wmv|mp3|flac|wav|m4a|aac|ogg)$");
    }

    public static String id(String mode, Entry entry) throws Exception {
        String json = new JSONObject().put("mode", mode).put("path", entry.path).put("name", entry.name).toString();
        return Base64.encodeToString(json.getBytes(StandardCharsets.UTF_8), Base64.URL_SAFE | Base64.NO_WRAP | Base64.NO_PADDING);
    }

    private static JSONObject decode(String id) throws Exception {
        return new JSONObject(new String(Base64.decode(id, Base64.URL_SAFE), StandardCharsets.UTF_8));
    }

    public static Result detail(String id) throws Exception {
        JSONObject entry = decode(id);
        Vod vod = new Vod();
        vod.setId(id); vod.setName(entry.getString("name"));
        vod.setPlayFrom("我的媒体"); vod.setPlayUrl("播放$" + id);
        return Result.vod(vod);
    }

    public static Result player(String id) throws Exception {
        JSONObject entry = decode(id);
        String mode = entry.getString("mode"), path = entry.getString("path"), url;
        HashMap<String, String> headers = new HashMap<>();
        if ("openlist".equals(mode)) {
            url = post(get(mode, "url"), "/api/fs/get", fileBody(path), token()).getString("raw_url");
            if (HttpUrl.parse(url) == null) throw new IOException("服务没有提供 HTTP(S) 播放地址");
        } else if ("webdav".equals(mode)) {
            url = webDavUrl(path).toString(); headers.put("Authorization", webDavAuth());
        } else throw new IOException("未知媒体连接类型");
        Result result = new Result(); result.setUrl(url); result.setParse(0); result.setKey("family_media");
        result.setHeader(headers); result.setFlag("我的媒体");
        return result;
    }
}
