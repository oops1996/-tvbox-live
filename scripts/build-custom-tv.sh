#!/usr/bin/env bash
set -euo pipefail

UPSTREAM="https://github.com/OttoHX/kknifer7_TV-K.git"
SRC="tv-src"
CONFIG_URL="https://cdn.jsdelivr.net/gh/oops1996/-tvbox-live@main/config.json"

rm -rf "$SRC"
git clone --depth 1 "$UPSTREAM" "$SRC"
cd "$SRC"

# GitHub Actions 上使用 Gradle 官方分发源，避免区域镜像不可用
sed -i 's#https\\://mirrors.cloud.tencent.com/gradle/#https\\://services.gradle.org/distributions/#' gradle/wrapper/gradle-wrapper.properties || true

python3 - <<'PY'
from pathlib import Path

CONFIG_URL = "https://cdn.jsdelivr.net/gh/oops1996/-tvbox-live@main/config.json"

# 1) 应用名 / 包名 / 版本
p = Path("app/src/main/res/values/strings.xml")
s = p.read_text(encoding="utf-8")
s = s.replace('<string name="app_name">TV-K</string>', '<string name="app_name">家庭电视</string>')
p.write_text(s, encoding="utf-8")

p = Path("app/build.gradle")
s = p.read_text(encoding="utf-8")
s = s.replace('applicationId "io.kknifer7.android.tv"', 'applicationId "com.oops.tv"')
s = s.replace('versionName "1.0.0 (Based on FongMi TV 4.9.9)"', 'versionName "1.0.0 家庭电视"')
p.write_text(s, encoding="utf-8")

# 2) 首次启动时自动写入用户自己的总配置；关闭上游应用自动更新
p = Path("app/src/leanback/java/com/fongmi/android/tv/ui/activity/HomeActivity.java")
s = p.read_text(encoding="utf-8")
s = s.replace('        Updater.create().start(this);', '        // 家庭电视：禁用上游 APK 自动更新，避免覆盖定制版')
old = '''    private void initConfig() {
        VodConfig.get().init().load(getCallback());
        LiveConfig.get().init().load();
        WallConfig.get().init();
    }'''
new = f'''    private void initConfig() {{
        // 家庭电视：首次启动自动加载自己的配置；用户后续手工切换配置时不会强制覆盖
        if (Config.vod().isEmpty()) Config.create(0, "{CONFIG_URL}", "家庭电视").update();
        VodConfig.get().init().load(getCallback());
        LiveConfig.get().init().load();
        WallConfig.get().init();
    }}'''
if old not in s:
    raise SystemExit("HomeActivity initConfig patch target not found")
s = s.replace(old, new)
p.write_text(s, encoding="utf-8")

# 3) 开机自启：电视启动后进入家庭电视首页，不直接进入直播
p = Path("app/src/leanback/java/com/fongmi/android/tv/receiver/BootReceiver.java")
s = p.read_text(encoding="utf-8")
old = '''    @Override
    public void onReceive(Context context, Intent intent) {
        registerCallback();
    }'''
new = '''    @Override
    public void onReceive(Context context, Intent intent) {
        registerCallback();
        try {
            Intent launch = context.getPackageManager().getLaunchIntentForPackage(context.getPackageName());
            if (launch != null) {
                launch.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK | Intent.FLAG_ACTIVITY_CLEAR_TOP);
                context.startActivity(launch);
            }
        } catch (Throwable ignored) {
        }
    }'''
if old not in s:
    raise SystemExit("BootReceiver patch target not found")
s = s.replace(old, new)
p.write_text(s, encoding="utf-8")
PY

chmod +x gradlew

# 构建两个电视端架构版本。用户电视如果是 64 位优先 arm64；不确定时可再试 armv7。
./gradlew --no-daemon \
  :app:assembleLeanbackArm64_v8aRelease \
  :app:assembleLeanbackArmeabi_v7aRelease

mkdir -p ../apk-out
find app/build/outputs/apk -type f -name "*.apk" -exec cp {} ../apk-out/ \;

echo "APK outputs:"
ls -lh ../apk-out
