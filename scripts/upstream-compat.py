from pathlib import Path

CONFIG_URL = "https://cdn.jsdelivr.net/gh/oops1996/-tvbox-live@main/config.json"

# 1) 应用名 / 包名 / 版本
p = (SRC / "app/src/main/res/values/strings.xml")
s = p.read_text(encoding="utf-8")
s = s.replace('<string name="app_name">TV-K</string>', '<string name="app_name">家庭电视</string>')
p.write_text(s, encoding="utf-8")

# 补齐播放器样式所需 attrs，避免上游 AAR 在新版 Android Gradle Plugin 下资源链接失败
p = (SRC / "app/src/main/res/values/attrs.xml")
s = p.read_text(encoding="utf-8")
extra = """
    <attr name="resize_mode" format="enum">
        <enum name="fit" value="0" />
        <enum name="fixed_width" value="1" />
        <enum name="fixed_height" value="2" />
        <enum name="fill" value="3" />
        <enum name="zoom" value="4" />
    </attr>
    <attr name="use_artwork" format="boolean" />
    <attr name="use_controller" format="boolean" />
    <attr name="keep_content_on_player_reset" format="boolean" />
    <attr name="surface_type" format="enum">
        <enum name="none" value="0" />
        <enum name="surface_view" value="1" />
        <enum name="texture_view" value="2" />
        <enum name="spherical_gl_surface_view" value="3" />
        <enum name="video_decoder_gl_surface_view" value="4" />
    </attr>
    <attr name="scrubber_color" format="color" />
    <attr name="played_color" format="color" />
    <attr name="buffered_color" format="color" />
    <attr name="unplayed_color" format="color" />
    <attr name="shutter_background_color" format="color" />
"""
if 'name="resize_mode"' not in s:
    s = s.replace("</resources>", extra + "\n</resources>")
p.write_text(s, encoding="utf-8")

p = (SRC / "app/build.gradle")
s = p.read_text(encoding="utf-8")
s = s.replace('applicationId "io.kknifer7.android.tv"', 'applicationId "com.oops.tv"')
s = s.replace('versionName "1.0.0 (Based on FongMi TV 4.9.9)"', 'versionName "1.0.0 家庭电视"')

# 上游源码使用 AndroidX Media3，但镜像 build.gradle 未声明对应依赖，补齐播放器模块。
media3 = """
    implementation 'androidx.media3:media3-common:' + media3Version
    implementation 'androidx.media3:media3-database:' + media3Version
    implementation 'androidx.media3:media3-datasource:' + media3Version
    implementation 'androidx.media3:media3-datasource-okhttp:' + media3Version
    implementation 'androidx.media3:media3-exoplayer:' + media3Version
    implementation 'androidx.media3:media3-exoplayer-dash:' + media3Version
    implementation 'androidx.media3:media3-exoplayer-hls:' + media3Version
    implementation 'androidx.media3:media3-exoplayer-rtsp:' + media3Version
    implementation 'androidx.media3:media3-exoplayer-smoothstreaming:' + media3Version
    implementation 'androidx.media3:media3-extractor:' + media3Version
    implementation 'androidx.media3:media3-ui:' + media3Version
"""
if "androidx.media3:media3-exoplayer:" not in s:
    s = s.replace("dependencies {", "dependencies {" + media3)
p.write_text(s, encoding="utf-8")

# Use the matching custom Media3 modules. Standard Media3 lacks the upstream's
# subtitle position, render switching, adblock and decoder selection APIs.
p = SRC / "build.gradle"
s = p.read_text(encoding="utf-8")
s = s.replace("media3Version = '1.8.0'", "media3Version = '1.10.1'")
p.write_text(s, encoding="utf-8")
p = SRC / "settings.gradle"
s = p.read_text(encoding="utf-8")
s = s.replace("        mavenCentral()", """        maven {
            url = uri("$rootDir/family-media3-maven")
            metadataSources {
                mavenPom()
                artifact()
                ignoreGradleMetadataRedirection()
            }
            content { includeGroup "androidx.media3" }
        }
        mavenCentral()""")
p.write_text(s, encoding="utf-8")
