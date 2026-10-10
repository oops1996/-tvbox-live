# 自动维护直播源

直播订阅地址保持不变：

`https://cdn.jsdelivr.net/gh/oops1996/-tvbox-live@main/live.txt`

转换脚本仅使用 Python 标准库，默认读取以下两个 IPTV-CN 分类订阅，再合并一个经仓库所有者确认的补充上游：

- https://iptv-cn.github.io/IPTV/categories/cctv.m3u
- https://iptv-cn.github.io/IPTV/categories/卫视.m3u
- https://guovin.github.io/iptv-api/result.m3u （[Guovin/iptv-api](https://github.com/Guovin/iptv-api) 当前官方 Pages 输出）

## 更新规则

- 固定顺序保留 CCTV1–17、江西/湖南/浙江/江苏/东方/广东/北京/深圳卫视；CCTV5+ 有上游线路时一并保留。
- 合并同一频道的名称变体、去重 URL，保留多个不同线路。查询参数不重排、不解码，避免破坏签名 URL。
- 保留 TVBox 的 `分组名,#genre#` / `频道名,URL` 格式。同名频道的不同线路分多行写入：当前 APK 固定版本的 `LiveParser.txt()` 通过 `Group.find()` 合并同名频道并追加 URL。这种写法也能被现有 macOS 客户端读取；macOS 会显示为多个同名条目。
- 排除已知超时网段 `74.91.0.0/16`、`107.150.0.0/16`，不会把上一版文件的线路重新混入新列表。
- 校验 M3U 头、EXTINF 与 URL 配对、HTTP/HTTPS 地址、端口、编码和输出分组；不接受私网 IP、账号密码、TVBox 控制字符，也不静默移除直播请求必需的 header/DRM 设置。带这类设置的条目跳过，并由频道完整性检查兜底。
- 三个订阅均成功，且所有 25 个必需频道均有合格线路，才会生成并原子替换 `live.txt`。缺台、空文件、HTML 错误页、下载失败、格式错误、写入失败时返回非零状态，保留现有文件。
- Actions 还启用 `--probe`，对每条候选线路执行有超时和大小限制的 GET，检查 HLS 播放列表或 MPEG-TS 数据。只保留通过检查的线路；如果任何必需频道都没有通过检查的线路，整个更新失败，不发布残缺列表。
- 相同内容不重复写入或提交。更新只提交 `live.txt`，不会触发 APK/macOS 的构建。

## 定时与手动运行

工作流 `.github/workflows/update-live.yml` 每天北京时间 **09:23、21:23** 运行，也可在 GitHub → Actions → **Update live TV playlist** → **Run workflow** 手动运行。转换脚本、测试或工作流有改动推送到 `main` 时也运行一次。拉取请求仅运行测试。

更新工作具有 `contents: write` 权限，以仓库自带 `GITHUB_TOKEN` 提交文件，不需要新建个人令牌，也不修改账号权限。仓库或组织策略如果禁止写入，推送会失败并保留远端文件。并发运行排队；如果其他提交抢先更新 `main`，普通推送被拒绝，下一次运行重新抓取，不强制覆盖其他提交。

GitHub 定时任务可能延迟；公开仓库连续 60 天没有活动时，GitHub 会停用定时工作流，可在 Actions 中重新启用。依据：[GitHub schedule 说明](https://docs.github.com/en/actions/reference/workflows-and-actions/events-that-trigger-workflows#schedule)。jsDelivr 有缓存，GitHub 更新成功后电视端可能需要等待缓存更新并刷新订阅。

## 本地验证

```sh
python3 -m unittest discover -s tests -p 'test_update_live.py' -v
python3 scripts/update-live.py --dry-run
python3 scripts/update-live.py --probe --dry-run
python3 scripts/update-live.py --probe
```

离线验证可重复传入 `--input 分类.m3u`，并通过 `--output 候选.txt` 指定独立输出。默认更新模式做结构检查；`--probe` 启用网络检查。网络检查只证明执行机器收到了含媒体条目的播放列表/TS 字节，不验证 HLS 子列表、视频分片、节目身份、长期稳定性或电视所在网络的可播放性，不能把它表述为真机播放验证。

## 已核实的上游限制（2026-10-10）

IPTV-CN README 明确说明 2020 奥运会结束后停止人工维护：[上游说明](https://github.com/IPTV-CN/IPTV#停止维护)。目前两个分类订阅均返回 HTTP 200，但 CCTV 分类缺少 **CCTV8**；线路中仍包含运营商地址。这不是仍在积极维护的跨运营商稳定播放保证。

经仓库所有者确认，加入 **Guovin/iptv-api 的官方 Pages 结果订阅** 补齐缺台并增加备用线路；不使用该项目已停止更新的旧 `raw/.../output/...` 地址。其主仓库最近提交为 2026-10-09，当前结果文件内标记的生成时间为 2026-09-28 12:31:23，不能把代码维护时间当作线路刷新时间。补充源仍需通过每次下载、完整性与网络检查，不能仅凭项目活跃度认定每条线路都可用。

仅使用 IPTV-CN 两个分类的离线验证会报告 `missing required channels: CCTV8` 并保留原文件。三源合并提供完整的频道候选列表；启用网络检查后若缺少可响应的频道，则整个更新仍会失败。没有伪造缺失地址或发布残缺列表。

本次本机连通检查的三源合并结果为 26 个频道（含 CCTV5+）、153 条去重后候选线路，其中 9 条取得 HLS/TS 响应；CCTV8 和多路其他必需频道未通过，未改动现有 `live.txt`。这次检查不代表 GitHub runner 或用户电视的网络结果。工作流若得到同样的结果，会报告失败并保留远端文件，不能把自动维护配置完成表述为直播超时问题已经解决。
