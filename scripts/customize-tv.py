#!/usr/bin/env python3
"""Apply checked patches to the pinned upstream; never download user configuration."""
import argparse
import hashlib
import shutil
from pathlib import Path
import xml.etree.ElementTree as ET

CONFIG_URL = "https://cdn.jsdelivr.net/gh/oops1996/-tvbox-live@main/config.json"
ICON_SHA256 = "5d21cbc308cfcfdbc160997be291e0c80b5af6545470cf56f3d0b2c84d1db714"
ANDROID = "{http://schemas.android.com/apk/res/android}"


def replace(path, old, new, count=1):
    text = path.read_text(encoding="utf-8")
    if text.count(old) != count:
        raise RuntimeError(f"Patch target changed: {path}, expected {count} matches")
    path.write_text(text.replace(old, new), encoding="utf-8")


def customize(src, repo):
    # Retain the existing Media3/resource compatibility fixes.
    exec((repo / "scripts/upstream-compat.py").read_text(), {"__name__": "compat", "SRC": src})
    # The custom fork keeps decoder/render APIs but its octet MIME constant is private.
    replace(src / "app/src/main/java/com/fongmi/android/tv/player/exo/ExoUtil.java",
            "MimeTypes.APPLICATION_OCTET", '"application/octet-stream"')
    gradle = src / "app/build.gradle"
    replace(gradle, '        versionCode 1', '        versionCode 3')
    replace(gradle, 'versionName "1.0.0 家庭电视"', 'versionName "1.0.2 家庭电视"')
    replace(gradle, '    buildTypes {', '''    signingConfigs {
        family {
            if (System.getenv("FAMILY_TV_KEYSTORE_PATH")) {
                storeFile file(System.getenv("FAMILY_TV_KEYSTORE_PATH"))
                storePassword System.getenv("FAMILY_TV_KEYSTORE_PASSWORD")
                keyAlias System.getenv("FAMILY_TV_KEY_ALIAS")
                keyPassword System.getenv("FAMILY_TV_KEY_PASSWORD")
            }
        }
    }
    buildTypes {''')
    replace(gradle, '        release {', '        release {\n            signingConfig System.getenv("FAMILY_TV_KEYSTORE_PATH") ? signingConfigs.family : signingConfigs.debug')

    # Prefer AndroidX's stock HTTP transport for playback. The upstream custom OkHttp
    # stack adds DNS/proxy/auth interceptors which can turn otherwise valid IPTV HLS
    # requests into generic IO failures on some Android TV firmwares.
    media_factory = src / "app/src/main/java/com/fongmi/android/tv/player/exo/MediaSourceFactory.java"
    replace(media_factory, 'import androidx.media3.datasource.DefaultDataSource;',
            'import androidx.media3.datasource.DefaultDataSource;\nimport androidx.media3.datasource.DefaultHttpDataSource;')
    replace(media_factory, 'import androidx.media3.datasource.okhttp.OkHttpDataSource;\n', '')
    replace(media_factory, 'import com.github.catvod.net.OkHttp;\n', '')
    replace(media_factory,
            'if (httpDataSourceFactory == null) httpDataSourceFactory = new OkHttpDataSource.Factory(OkHttp.player());',
            'if (httpDataSourceFactory == null) httpDataSourceFactory = new DefaultHttpDataSource.Factory()'
            '.setUserAgent(ExoUtil.getUa()).setAllowCrossProtocolRedirects(true)'
            '.setConnectTimeoutMs(15000).setReadTimeoutMs(30000);')

    icon = repo / "assets/android/family-tv-icon.png"
    if hashlib.sha256(icon.read_bytes()).hexdigest() != ICON_SHA256:
        raise RuntimeError("Final user icon checksum does not match")
    for path in (src / "app/src").glob("*/res/values*/strings.xml"):
        import re
        text = path.read_text(encoding="utf-8")
        text = re.sub(r'(<string name="app_name">).*?(</string>)', r'\g<1>家庭电视\2', text)
        path.write_text(text, encoding="utf-8")
    drawable = src / "app/src/main/res/drawable-nodpi"
    drawable.mkdir(parents=True, exist_ok=True)
    shutil.copy2(icon, drawable / "family_tv_icon.png")
    # Use a separate resource name so density/adaptive upstream icons cannot win.
    manifest = src / "app/src/main/AndroidManifest.xml"
    replace(manifest, 'android:icon="@mipmap/ic_launcher"', 'android:icon="@drawable/family_tv_icon"')
    replace(manifest, 'android:roundIcon="@mipmap/ic_launcher_round"', 'android:roundIcon="@drawable/family_tv_icon"')
    replace(manifest, 'android:usesCleartextTraffic="true"', 'android:usesCleartextTraffic="true"\n        android:networkSecurityConfig="@xml/network_security_config"')
    network_xml = src / "app/src/main/res/xml/network_security_config.xml"
    network_xml.parent.mkdir(parents=True, exist_ok=True)
    network_xml.write_text('''<?xml version="1.0" encoding="utf-8"?>
<network-security-config>
    <base-config cleartextTrafficPermitted="true">
        <trust-anchors>
            <certificates src="system" />
            <certificates src="user" />
        </trust-anchors>
    </base-config>
</network-security-config>''')
    manifest = src / "app/src/leanback/AndroidManifest.xml"
    replace(manifest, 'android:banner="@mipmap/ic_banner"', 'android:banner="@drawable/family_tv_banner"')
    replace(manifest, 'android:theme="@style/Theme.Splash"', 'android:theme="@style/Theme.App"\n            android:clearTaskOnLaunch="true"\n            android:launchMode="singleTop"')
    replace(manifest, '        <activity\n            android:name=".ui.activity.CastActivity"', '''        <activity android:name=".ui.activity.FamilySourcesActivity" android:exported="false" android:screenOrientation="sensorLandscape" />
        <activity android:name=".ui.activity.FamilyMediaActivity" android:exported="false" android:screenOrientation="sensorLandscape" />

        <activity
            android:name=".ui.activity.CastActivity"''')
    res = src / "app/src/leanback/res"
    (res / "drawable").mkdir(exist_ok=True)
    (res / "drawable/family_tv_banner.xml").write_text('''<layer-list xmlns:android="http://schemas.android.com/apk/res/android">
    <item android:width="320dp" android:height="180dp"><shape><solid android:color="#06142F" /></shape></item>
    <item android:width="180dp" android:height="180dp" android:gravity="center" android:drawable="@drawable/family_tv_icon" />
</layer-list>''')
    (res / "values/family_tv.xml").write_text('''<resources>
    <string name="family_media">我的媒体</string>
    <string name="family_exit_title">退出家庭电视？</string>
    <string name="family_exit_message">确认退出应用并停止后台播放吗？</string>
    <string name="family_exit_yes">退出</string>
    <string name="family_exit_no">取消</string>
</resources>''')
    styles = res / "values/styles.xml"
    replace(styles, '    <style name="Theme.Splash" parent="Theme.SplashScreen">\n        <item name="postSplashScreenTheme">@style/Theme.App</item>\n        <item name="windowSplashScreenAnimatedIcon">@drawable/ic_launcher_foreground</item>\n    </style>\n\n', '')
    # Android 12+ still controls its own short system launch screen.
    replace(styles, '<style name="Theme.App" parent="Theme.Base" />', '''<style name="Theme.App" parent="Theme.Base">
        <item name="android:windowBackground">#06142F</item>
    </style>''')
    home = src / "app/src/leanback/java/com/fongmi/android/tv/ui/activity/HomeActivity.java"
    replace(home, 'import androidx.core.splashscreen.SplashScreen;', 'import androidx.appcompat.app.AlertDialog;\nimport com.google.android.material.dialog.MaterialAlertDialogBuilder;')
    replace(home, 'import androidx.leanback.widget.ListRow;', 'import androidx.leanback.widget.ListRow;\nimport androidx.leanback.widget.ListRowPresenter;')
    replace(home, '    private Clock mClock;', '    private Clock mClock;\n    private AlertDialog exitDialog;')
    replace(home, '        checkAction(intent);\n    }\n\n    @Override\n    protected void onCreate', '        setIntent(intent);\n        if (Intent.ACTION_MAIN.equals(intent.getAction())) resetHome();\n        else checkAction(intent);\n    }\n\n    @Override\n    protected void onCreate')
    replace(home, '        SplashScreen.installSplashScreen(this);\n        super.onCreate(savedInstanceState);', '        com.fongmi.android.tv.Setting.putBootLive(false);\n        super.onCreate(null); // Never restore the last page on launch.')
    replace(home, '        mBinding.progressLayout.showProgress();', '        mBinding.progressLayout.showContent();')
    replace(home, '        Updater.create().start(this);', '        com.fongmi.android.tv.Setting.putUpdate(false);')
    replace(home, '        initConfig();', '        setFunc();\n        resetHome();\n        initConfig();')
    replace(home, '        VodConfig.get().init().load(getCallback());', f'        if (Config.vod().isEmpty() || FamilySourcesActivity.isDisabled(Config.vod())) Config.find("{CONFIG_URL}", "家庭电视", 0).update();\n        VodConfig.get().init().load(getCallback());')
    replace(home, '        LiveConfig.get().init().load();', '        if (Config.live().isEmpty()) Config.create(1, "https://cdn.jsdelivr.net/gh/oops1996/-tvbox-live@main/live.txt", "家庭直播").update();\n        LiveConfig.get().init().load();')
    replace(home, '        App.post(() -> mBinding.title.setFocusable(true), 500);', '        mBinding.title.setFocusable(true);')
    replace(home, '        items.add(Func.create(R.string.home_vod));', '        items.add(Func.create(R.string.home_vod));\n        items.add(Func.create(R.string.family_media));')
    replace(home, '            case R.string.home_live:', '            case R.string.family_media:\n                startActivity(new Intent(this, FamilyMediaActivity.class));\n                break;\n            case R.string.home_live:')
    func = src / "app/src/leanback/java/com/fongmi/android/tv/bean/Func.java"
    replace(func, '            case R.string.home_vod:', '            case R.string.family_media:\n            case R.string.home_vod:')
    replace(home, '        ImgUtil.logo(mBinding.logo);', '        mBinding.logo.setImageResource(R.drawable.family_tv_icon);')
    replace(home, '            if (PlaybackService.isRunning()) moveTaskToBack(true);\n            else super.onBackInvoked();', '            confirmExit();')
    replace(home, '    @Override\n    protected void onDestroy() {', '''    private void resetHome() {
        if (exitDialog != null) exitDialog.dismiss();
        mBinding.toolbar.setVisibility(View.VISIBLE);
        mBinding.recycler.setSelectedPosition(0);
        // First function is always 影视. Select its first item after layout.
        mBinding.recycler.post(() -> {
            RecyclerView.ViewHolder holder = mBinding.recycler.findViewHolderForAdapterPosition(0);
            if (holder instanceof ItemBridgeAdapter.ViewHolder) {
                androidx.leanback.widget.Presenter.ViewHolder row = ((ItemBridgeAdapter.ViewHolder) holder).getViewHolder();
                if (row instanceof ListRowPresenter.ViewHolder) {
                    HorizontalGridView grid = ((ListRowPresenter.ViewHolder) row).getGridView();
                    grid.setSelectedPosition(0);
                    grid.requestFocus();
                    return;
                }
            }
            mBinding.recycler.requestFocus();
        });
    }

    private void confirmExit() {
        if (exitDialog != null && exitDialog.isShowing()) return;
        exitDialog = new MaterialAlertDialogBuilder(this)
                .setTitle(R.string.family_exit_title)
                .setMessage(R.string.family_exit_message)
                .setNegativeButton(R.string.family_exit_no, (dialog, which) -> dialog.dismiss())
                .setPositiveButton(R.string.family_exit_yes, (dialog, which) -> {
                    PlaybackService.stop();
                    finishAndRemoveTask();
                }).create();
        exitDialog.setOnShowListener(dialog -> exitDialog.getButton(AlertDialog.BUTTON_NEGATIVE).requestFocus());
        exitDialog.show();
    }

    @Override
    protected void onDestroy() {''')
    replace(home, '        CacheManager.get().release();', '        if (exitDialog != null) exitDialog.dismiss();\n        CacheManager.get().release();')
    # A fresh boot task, not CLEAR_TOP which could keep an old player.
    boot = src / "app/src/leanback/java/com/fongmi/android/tv/receiver/BootReceiver.java"
    replace(boot, '        registerCallback();', '''        if (intent == null || (!Intent.ACTION_BOOT_COMPLETED.equals(intent.getAction())
                && !"android.intent.action.QUICKBOOT_POWERON".equals(intent.getAction()))) return;
        com.fongmi.android.tv.Setting.putBootLive(false);
        try {
            Intent launch = new Intent(context, com.fongmi.android.tv.ui.activity.HomeActivity.class);
            launch.setAction(Intent.ACTION_MAIN);
            launch.addCategory(Intent.CATEGORY_LAUNCHER);
            launch.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK | Intent.FLAG_ACTIVITY_CLEAR_TASK);
            context.startActivity(launch);
        } catch (RuntimeException error) {
            android.util.Log.w("FamilyTV", "TV system refused boot launch");
        }''')
    live = src / "app/src/main/java/com/fongmi/android/tv/api/config/LiveConfig.java"
    replace(live, '        LiveActivity.start(App.get());', '        // 家庭电视 never auto-opens live TV.')
    settings = src / "app/src/leanback/java/com/fongmi/android/tv/ui/activity/SettingActivity.java"
    replace(settings, '        mBinding.vodHistory.setOnClickListener(this::onVodHistory);', '        mBinding.vodHistory.setOnClickListener(v -> startActivity(new Intent(this, FamilySourcesActivity.class)));\n        mBinding.familyMedia.setOnClickListener(v -> startActivity(new Intent(this, FamilyMediaActivity.class)));')
    replace(settings, '        Updater.create().force().start(this);', '        Notify.show("家庭电视定制版：请从自己的构建记录手动安装更新");')
    layout = res / "layout/activity_setting.xml"
    anchor = '        android:padding="24dp">'
    replace(layout, anchor, anchor + '\n\n' + """        <com.google.android.material.button.MaterialButton
            android:id="@+id/familyMedia"
            android:layout_width="match_parent"
            android:layout_height="wrap_content"
            android:focusable="true"
            android:text="OpenList / WebDAV · 我的媒体" />
        <com.google.android.material.button.MaterialButton
            android:id="@+id/familySources"
            android:layout_width="match_parent"
            android:layout_height="wrap_content"
            android:focusable="true"
            android:text="接口管理（本机保存）" />""")
    replace(settings, '        mBinding.vod.setOnClickListener(this::onVod);', '        mBinding.vod.setOnClickListener(this::onVod);\n        mBinding.familySources.setOnClickListener(v -> startActivity(new Intent(this, FamilySourcesActivity.class)));')
    # Shared PairingDialog references a binding supplied only in the mobile flavor.
    pairing = res / "layout/dialog_free_box_pairing.xml"
    if pairing.exists(): raise RuntimeError("Unexpected existing TV pairing layout")
    text = (src / "app/src/mobile/res/layout/dialog_free_box_pairing.xml").read_text()
    text = text.replace('@style/ToolbarTextAppearance', '@android:style/TextAppearance.Material.Body1')
    pairing.write_text(text)
    # Private media playback uses local connection data, never credentials in history IDs.
    model = src / "app/src/main/java/com/fongmi/android/tv/model/SiteViewModel.java"
    replace(model, '    public void detailContent(String key, String id) {\n        execute(result, () -> {', '''    public void detailContent(String key, String id) {
        execute(result, () -> {
            if ("family_media".equals(key)) {
                Result detail = com.fongmi.android.tv.family.FamilyMedia.detail(id);
                Source.get().parse(detail.getVod().setFlags());
                return detail;
            }''')
    replace(model, '            Source.get().stop();\n            Site site', '            Source.get().stop();\n            if ("family_media".equals(key)) return com.fongmi.android.tv.family.FamilyMedia.player(id);\n            Site site')
    # Prevent release logcat from printing playback Authorization headers/tokens.
    startup = src / "app/src/main/java/com/fongmi/android/tv/Startup.java"
    replace(startup, '.tag("TV").build()));', '.tag("TV").build()) {\n            @Override public boolean isLoggable(int priority, String tag) { return BuildConfig.DEBUG; }\n        });')
    for path in (repo / "android-overlay").rglob("*"):
        if path.is_file():
            dest = src / "app" / path.relative_to(repo / "android-overlay")
            dest.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(path, dest)
    # Fail before Gradle if a patched XML file is malformed.
    for path in [manifest, src / "app/src/main/AndroidManifest.xml", styles, layout, pairing, res / "drawable/family_tv_banner.xml", res / "values/family_tv.xml", network_xml]:
        ET.parse(path)
    print("Family TV customization applied; original icon checksum verified.")


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("source", type=Path)
    parser.add_argument("--repo", type=Path, default=Path(__file__).resolve().parents[1])
    args = parser.parse_args()
    customize(args.source.resolve(), args.repo.resolve())
