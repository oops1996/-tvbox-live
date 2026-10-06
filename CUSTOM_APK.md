# 家庭电视 APK

这是“家庭电视”定制 APK 的构建仓库。

## 第一版目标

- Android TV / Android 11 兼容
- 遥控器 D-pad 操作
- 应用名：家庭电视
- 包名：`com.oops.tv`
- 开机自启，但进入首页，不自动打开直播
- 保留影视、直播、搜索、收藏、历史、设置
- 默认总配置：
  `https://cdn.jsdelivr.net/gh/oops1996/-tvbox-live@main/config.json`
- 默认直播由总配置中的 `live.txt` 加载
- 不把网盘 Cookie、Token、密码写入 APK 或公开仓库
- 禁用上游 APK 自动更新，避免覆盖定制版

## 构建方式

GitHub Actions 会自动拉取公开上游源码，在构建时应用本仓库的定制补丁，然后生成：
- Leanback arm64-v8a APK
- Leanback armeabi-v7a APK

电视型号：75JD1000，Android 11。由于当前系统信息页没有显示 CPU ABI，第一轮同时生成 64 位和 32 位 ARM 包。

## 开源说明

定制构建基于公开的 TV-K / FongMi TV 衍生项目。上游项目采用 AGPL-3.0；本仓库保留构建脚本和改动方式，便于复现对应定制版本。仅用于播放用户有权访问的媒体内容。
