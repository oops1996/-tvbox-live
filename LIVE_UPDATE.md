# 自动维护直播源

直播订阅地址保持不变：

`https://cdn.jsdelivr.net/gh/oops1996/-tvbox-live@main/live.txt`

转换脚本仅使用 Python 标准库，默认读取以下两个 IPTV-CN 分类订阅，再合并一个经仓库所有者确认的补充上游：

- https://iptv-cn.github.io/IPTV/categories/cctv.m3u
- https://iptv-cn.github.io/IPTV/categories/卫视.m3u
- https://guovin.github.io/iptv-api/result.m3u （[Guovin/iptv-api](https://github.com/Guovin/iptv-api) 当前官方 Pages 输出）

新增本地、电视剧、动漫及地区频道还使用 [iptv-org](https://github.com/iptv-org/iptv) 的公开分类文件作为可选补充：

- https://raw.githubusercontent.com/iptv-org/iptv/master/streams/cn.m3u
- https://iptv-org.github.io/iptv/countries/tw.m3u
- https://iptv-org.github.io/iptv/countries/hk.m3u
- https://iptv-org.github.io/iptv/countries/mo.m3u
- https://raw.githubusercontent.com/xiongjian83/TvBox/main/live.m3u （[公开仓库](https://github.com/xiongjian83/TvBox)，补充江西本地等候选线路）

这些补充文件仅为新增频道提供线路，不混入原有 25 个核心频道，保留原先的线路来源优先级。

最后一个订阅包含 TVBox 的线路显示标签，仅对该订阅移除末尾明确的 `$LR•IPV4/6『线路数字』` 标签；查询参数和请求设置不改写。其余不支持的控制字符、协议或额外 header/DRM 依赖继续排除。

## 扩展频道

下列名称是自动抓取的候选范围，不是当前都能播放的保证。每轮只有通过网络检查的频道才会写入，空分组不显示；某个补充订阅无法下载或格式不合格时跳过该订阅。原有 CCTV1–17 和 8 个卫视继续作为完整性保护门槛。

| 分组 | 候选频道 |
| --- | --- |
| 江西本地 | 江西都市、经济生活、影视、公共农业、少儿，南昌新闻综合、赣州新闻综合/公共/教育、萍乡新闻综合、抚州公共 |
| 电视剧场 | 第一剧场、风云剧场、怀旧剧场、都市剧场、欢笑剧场、湖南电视剧、福建电视剧、淘剧场 |
| 动漫少儿 | 金鹰卡通、优漫卡通、卡酷动画、炫动卡通、动漫秀场、爱动漫 |
| 更多卫视 | 辽宁、吉林、黑龙江、新疆、山东、河南、四川、湖北、安徽、东南卫视 |
| 台湾频道 | 台视、华视、TVBS 亚洲 |
| 香港频道 | 翡翠台、凤凰香港、凤凰中文 |
| 澳门频道 | 澳视澳门、澳门莲花 |

采用有限的中文/繁体/英文名称及台标 ID 对照，不把华视新闻、TVBS 新闻等不同节目合并成综合频道。可选大订阅中未选频道的空条目不会影响选定频道，但选定条目缺 URL、错误结构或需要额外请求设置时不会转成可播地址。

## 更新规则

- 固定顺序保留 CCTV1–17、江西/湖南/浙江/江苏/东方/广东/北京/深圳卫视；CCTV5+ 有上游线路时一并保留，再按表中分组纳入通过检查的新增频道。
- 合并同一频道的名称变体、去重 URL，保留多个不同线路。查询参数不重排、不解码，避免破坏签名 URL。
- 保留 TVBox 的 `分组名,#genre#` / `频道名,URL` 格式。同名频道的不同线路分多行写入：当前 APK 固定版本的 `LiveParser.txt()` 通过 `Group.find()` 合并同名频道并追加 URL。这种写法也能被现有 macOS 客户端读取。
- 排除已知超时网段 `74.91.0.0/16`、`107.150.0.0/16`，不会把上一版文件的线路重新混入新列表。
- 排除补充源中明确错标的 CCTV4K → CCTV4、CCTV5+ → CCTV5 条目；不根据 URL 猜测其他频道身份。
- 校验 M3U 头、EXTINF 与 URL 配对、HTTP/HTTPS 地址、端口、编码和输出分组；不接受私网 IP、账号密码、TVBox 控制字符，也不静默移除直播请求必需的 header/DRM 设置。带这类设置的条目跳过，并由频道完整性检查兜底。
- 三个核心订阅均成功，且所有 25 个必需频道均有合格线路，才会生成并原子替换 `live.txt`。核心缺台、空文件、HTML 错误页、下载失败、格式错误、写入失败时返回非零状态，保留现有文件。新增频道采用可选策略，不能用新增频道数量掩盖核心缺台。
- Actions 还启用 `--probe`，对每条候选线路执行有超时和大小限制的 GET，检查 HLS 播放列表或 MPEG-TS 数据。HLS 最多读取 512 KiB，排除末尾 `ENDLIST` 或 `PLAYLIST-TYPE:VOD` 标明的录播；重定向后的地址也检查已知超时网段。只保留通过检查的线路；如果任何必需频道都没有通过检查的线路，整个更新失败，不发布残缺列表。
- 相同内容不重复写入或提交。更新只提交 `live.txt`，不会触发 APK/macOS 的构建。
- 新列表成功推送后，工作流调用 jsDelivr 的缓存刷新接口。刷新失败只显示警告，已发布的文件保留，订阅地址等待 CDN 缓存自然过期。
- 日志列出缺失的新增频道、跳过的可选订阅、各分组的实际频道数。未响应的新增频道不计入统计，不写入失效占位地址。

## 定时与手动运行

工作流 `.github/workflows/update-live.yml` 每天北京时间 **09:23、21:23** 运行，也可在 GitHub → Actions → **Update live TV playlist** → **Run workflow** 手动运行。转换脚本、测试或工作流有改动推送到 `main` 时也运行一次。拉取请求仅运行测试。

更新工作具有 `contents: write` 权限，以仓库自带 `GITHUB_TOKEN` 提交文件，不需要新建个人令牌，也不修改账号权限。仓库或组织策略如果禁止写入，推送会失败并保留远端文件。并发运行排队；如果其他提交抢先更新 `main`，普通推送被拒绝，下一次运行重新抓取，不强制覆盖其他提交。

GitHub 定时任务可能延迟；公开仓库连续 60 天没有活动时，GitHub 会停用定时工作流，可在 Actions 中重新启用。依据：[GitHub schedule 说明](https://docs.github.com/en/actions/reference/workflows-and-actions/events-that-trigger-workflows#schedule)。jsDelivr 有缓存，工作流会在新列表发布后尝试刷新缓存；电视端仍需刷新订阅。缓存刷新接口可能限流或失败，详细结果可在 Actions 步骤摘要查看。依据：[jsDelivr 缓存刷新工具](https://www.jsdelivr.com/tools/purge)。

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

发布前的本机连通检查为 26 个频道（含 CCTV5+）、153 条去重后候选线路，其中 9 条取得 HLS/TS 响应；CCTV8 和多路其他必需频道未通过，当时未改动本地 `live.txt`。发布后的首次 GitHub runner 更新成功，生成 26 个频道、70 条有响应的线路，并自动提交。两种环境结果不同，不能把 runner 检查通过当作用户电视已经可播。

最终列表核对还发现上游有 3 条 CCTV4K/CCTV5+ 错标，以及 2 条末尾带 `ENDLIST` 的卫视录播链接；已增加针对性的排除规则和回归测试，避免仅凭 HTTP/HLS 响应把它们当作正确直播备用源。

排除规则生效后的 GitHub runner 更新成功，生成 **26 个频道、61 条线路**，其中 CCTV8 有 4 条线路，25 个必需频道齐全。23 项回归测试通过。首次发布后也已成功调用 jsDelivr 缓存刷新接口；这不代表电视端已完成播放验证。
