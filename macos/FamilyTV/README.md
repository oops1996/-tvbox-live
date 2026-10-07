# 家庭电视 macOS V2

面向 Apple Silicon Mac（arm64），最低 macOS 13。

## 播放与原有功能

直播、OpenList / WebDAV、搜索、收藏、历史和设置均保留。播放层由 AVPlayer 更换为官方 VLCKit 3.7.3 / libVLC，完整框架随应用打包，无需安装 VLC 或 Homebrew。默认软件解码，网络缓冲 1500 毫秒；设置可调整，下次重试生效。播放器提供暂停、停止、重试、音量、全屏和点播进度控制，30 秒没有显示出视频帧时提示重试。

直播和普通媒体播放都使用同一内核。WebDAV Basic 认证转换为仅在内存中的 URL 认证；历史不保存该认证 URL，历史重播仅对当前 WebDAV 同源、同目录的地址使用网盘认证。现有密码存储继续使用本机偏好设置，仓库不存储用户密码。

## 可更换的影视源

在“影视 → 管理 / 导入源”粘贴完整地址。可重新导入更新，也可编辑链接后导入另一份配置并切换站点；没有固定默认影视源。

支持标准 JSON / XML 采集接口及 TVBox 配置中的 type=0 / type=1 HTTP 接口；支持分类、分页、当前源搜索、影片详情、线路和选集。电影、电视剧、综艺、动漫、短剧等分组由接口实际返回的分类名称归类。兼容 JSON5 注释和常见 JPEG 后附 base64 的配置封装；订阅 urls 列表以可选择导入的分支显示。

TVBox 的 type=3 csp_ Android/JAR 插件、JS/Python 爬虫、加密脚本以及需网页解析的播放地址暂不支持。导入器会列出兼容情况，不把“读到配置”报告为“可播放”。饭太硬等链接是否可用取决于它实际返回的接口类型。应用不会自动执行第三方插件。

## 构建与验证

```bash
bash scripts/build-macos.sh
```

脚本固定下载官方 VLCKit 3.7.3 二进制包并验证 SHA-256，检查 arm64 切片与动态库路径，按从内到外的顺序临时签名，再生成保留权限/符号链接的 app ZIP 和含“应用程序”快捷方式的 DMG。

GitHub Actions 的 macos-14 arm64 runner 完成编译、签名检查、合成 H.264 MP4/HLS 视频帧解码和受损 TS 恢复、需要 Basic 认证的 WebDAV 与 HLS 子分片、JSON/XML 分类/分页/搜索/选集、DMG 和 ZIP 检查后，上传“家庭电视-macOS-arm64”产物。

测试视频为自动生成的单色渐变 H.264，没有第三方影视内容；测试认证随机生成，不使用用户密码。CI 使用内存视频回调验证解码帧，不依赖虚拟机的 GPU；GUI 画面和原生视频视图仍需真实 Mac 核验。可另运行 Tests/PlaybackSmoke.swift 检查 GUI。真实江西移动/NewTV 的播放仍需对应网络下实测；换内核无法恢复缺失 SPS/PPS、已损坏或被上游阻断的流。

目前使用 ad-hoc 签名，没有 Developer ID 和公证，首次打开可能需要在 macOS“隐私与安全性”中允许打开。第三方授权与源代码位置见 THIRD_PARTY_NOTICES.md 和 LICENSE-VLCKit.txt。
