# 家庭电视 macOS

面向 Apple Silicon Mac（M1/M2/M3/M4）的原生 macOS 客户端。

## V1 功能
- 直播
- OpenList / WebDAV
- 搜索
- 收藏
- 历史
- 设置
- AVPlayer 原生播放
- 默认读取本仓库直播源
- OpenList 地址、用户名、密码仅保存在本机

## 默认配置
直播：
https://cdn.jsdelivr.net/gh/oops1996/-tvbox-live@main/live.txt

WebDAV 初始地址：
http://192.168.1.14:5244/dav/

> WebDAV 地址可在应用设置中修改，不把密码写进公开仓库。

## 构建
GitHub Actions 会生成 Apple Silicon arm64 的 .app 与 .dmg。
当前使用 ad-hoc 签名，没有 Apple Developer ID，因此首次打开时 macOS 可能要求在“隐私与安全性”中允许打开。
