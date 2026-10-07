import SwiftUI
import AppKit

enum SidebarItem: String, CaseIterable, Identifiable {
    case home = "首页"
    case live = "直播"
    case films = "影视"
    case drive = "我的网盘"
    case search = "搜索"
    case favorites = "收藏"
    case history = "历史"
    case settings = "设置"
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .home: return "house"
        case .live: return "tv"
        case .films: return "film"
        case .drive: return "externaldrive"
        case .search: return "magnifyingglass"
        case .favorites: return "star"
        case .history: return "clock"
        case .settings: return "gearshape"
        }
    }
}

struct ContentView: View {
    @EnvironmentObject var model: AppModel
    @State private var selection: SidebarItem? = .home

    var body: some View {
        NavigationSplitView {
            List(SidebarItem.allCases, selection: $selection) { item in
                Label(item.rawValue, systemImage: item.icon).tag(item)
            }
            .navigationTitle("家庭电视")
        } detail: {
            switch selection ?? .home {
            case .home: HomeView()
            case .live: LiveView()
            case .films: FilmView(library: model.films)
            case .drive: WebDAVView()
            case .search: SearchView()
            case .favorites: FavoritesView()
            case .history: HistoryView()
            case .settings: SettingsView()
            }
        }
        .task { if model.liveChannels.isEmpty { await model.loadLive() } }
    }
}

struct HomeView: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("家庭电视").font(.system(size: 36, weight: .bold))
            Text("直播 + OpenList / WebDAV，一个入口。")
                .foregroundStyle(.secondary)
            HStack(spacing: 16) {
                StatCard(title: "直播频道", value: "\(model.liveChannels.count)", icon: "tv")
                StatCard(title: "收藏", value: "\(model.favorites.count)", icon: "star")
                StatCard(title: "历史", value: "\(model.history.count)", icon: "clock")
            }
            Spacer()
        }
        .padding(32)
    }
}

struct StatCard: View {
    let title: String
    let value: String
    let icon: String
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Image(systemName: icon).font(.title)
            Text(value).font(.system(size: 34, weight: .semibold))
            Text(title).foregroundStyle(.secondary)
        }
        .padding(22).frame(width: 220, height: 150, alignment: .leading)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 18))
    }
}

struct PlayerPanel: View {
    @EnvironmentObject var model: AppModel
    var body: some View { PlayerContent(playback: model.playback) }
}

struct PlayerContent: View {
    @ObservedObject var playback: IPTVPlayer
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ZStack {
                VLCVideoSurface(playback: playback)
                if !playback.hasMedia {
                    Text("选择内容开始播放").foregroundStyle(.white.opacity(0.75))
                } else if playback.isBuffering {
                    ProgressView().colorScheme(.dark)
                } else if playback.failed {
                    VStack(spacing: 12) {
                        Image(systemName: "exclamationmark.triangle").font(.largeTitle)
                        Text("暂时无法播放")
                        Button("重试") { playback.retry() }
                    }.foregroundStyle(.white)
                }
            }
            .aspectRatio(16/9, contentMode: .fit)
            .background(.black)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            if playback.hasMedia {
                if playback.canSeek {
                    Slider(value: Binding(get: { playback.position }, set: { playback.seek(to: $0) }), in: 0...1)
                        .accessibilityLabel("播放进度")
                }
                HStack(spacing: 14) {
                    Button { playback.togglePause() } label: {
                        Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill")
                    }.help("播放 / 暂停")
                    Button { playback.stop() } label: { Image(systemName: "stop.fill") }.help("停止")
                    Button("重试") { playback.retry() }
                    Spacer()
                    Image(systemName: "speaker.wave.2")
                    Slider(value: $playback.volume, in: 0...100).frame(width: 100).accessibilityLabel("音量")
                    Button { playback.videoView.window?.toggleFullScreen(nil) } label: {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                    }.help("全屏")
                }
                Text(playback.status).font(.caption).foregroundStyle(playback.failed ? .red : .secondary)
            }
        }
    }
}

struct LiveView: View {
    @EnvironmentObject var model: AppModel
    @State private var query = ""
    var filtered: [LiveChannel] {
        query.isEmpty ? model.liveChannels : model.liveChannels.filter {
            $0.name.localizedCaseInsensitiveContains(query) || $0.group.localizedCaseInsensitiveContains(query)
        }
    }
    var groups: [String] { Array(Set(filtered.map(\.group))).sorted() }

    var body: some View {
        HSplitView {
            VStack {
                HStack {
                    TextField("搜索频道", text: $query)
                    Button("刷新") { Task { await model.loadLive() } }
                }.padding()
                List {
                    ForEach(groups, id: \.self) { group in
                        Section(group) {
                            ForEach(filtered.filter { $0.group == group }) { ch in
                                HStack {
                                    Button(ch.name) { model.play(channel: ch) }
                                        .buttonStyle(.plain)
                                    Spacer()
                                    Button {
                                        model.toggleFavorite(ch)
                                    } label: {
                                        Image(systemName: model.favorites.contains(ch.url) ? "star.fill" : "star")
                                    }.buttonStyle(.borderless)
                                }
                            }
                        }
                    }
                }
            }.frame(minWidth: 360)
            VStack(alignment: .leading, spacing: 12) {
                Text(model.selectedChannel?.name ?? "直播").font(.title2.bold())
                PlayerPanel()
                Text(model.statusText).foregroundStyle(.secondary)
                Spacer()
            }.padding(24)
        }
    }
}

struct WebDAVView: View {
    @EnvironmentObject var model: AppModel
    @State private var path = ""
    @State private var items: [DAVItem] = []
    @State private var stack: [String] = []
    @State private var error = ""

    var client: WebDAVClient {
        WebDAVClient(baseURL: model.webDAVBase, username: model.webDAVUser, password: model.webDAVPassword)
    }

    var body: some View {
        HSplitView {
            VStack {
                HStack {
                    Button {
                        if !stack.isEmpty {
                            path = stack.removeLast()
                            Task { await reload() }
                        }
                    } label: { Image(systemName: "chevron.left") }
                    .disabled(stack.isEmpty)
                    Text(path.isEmpty ? "/" : path).lineLimit(1)
                    Spacer()
                    Button("刷新") { Task { await reload() } }
                }.padding()
                List(items) { item in
                    HStack {
                        Image(systemName: item.isDirectory ? "folder" : "play.rectangle")
                        Text(item.name)
                        Spacer()
                    }
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) { open(item) }
                }
                if !error.isEmpty { Text(error).foregroundStyle(.red).padding() }
            }.frame(minWidth: 380)
            VStack(alignment: .leading, spacing: 12) {
                Text("我的网盘").font(.title2.bold())
                PlayerPanel()
                Text("双击文件夹进入，双击视频播放。").foregroundStyle(.secondary)
                Spacer()
            }.padding(24)
        }
        .task { await reload() }
    }

    func reload() async {
        do {
            items = try await client.list(path: path)
            error = ""
        } catch let err {
            error = "WebDAV 读取失败：\(err.localizedDescription)"
        }
    }

    func open(_ item: DAVItem) {
        if item.isDirectory {
            stack.append(path)
            let decoded = item.href.removingPercentEncoding ?? item.href
            if let range = decoded.range(of: "/dav/") {
                path = String(decoded[range.upperBound...]).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            } else {
                path = decoded.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            }
            Task { await reload() }
        } else {
            let url = client.absoluteURL(for: item.href)
            model.play(name: item.name, url: url, headers: model.headers(for: url))
        }
    }
}

struct SearchView: View {
    @EnvironmentObject var model: AppModel
    @State private var query = ""
    var results: [LiveChannel] {
        guard !query.isEmpty else { return [] }
        return model.liveChannels.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }
    var body: some View {
        VStack(alignment: .leading) {
            Text("搜索").font(.largeTitle.bold())
            TextField("搜索直播频道", text: $query).textFieldStyle(.roundedBorder).frame(maxWidth: 500)
            List(results) { ch in
                Button(ch.name) { model.play(channel: ch) }.buttonStyle(.plain)
            }
            PlayerPanel().frame(maxWidth: 850)
        }.padding(28)
    }
}

struct FavoritesView: View {
    @EnvironmentObject var model: AppModel
    var items: [LiveChannel] { model.liveChannels.filter { model.favorites.contains($0.url) } }
    var body: some View {
        VStack(alignment: .leading) {
            Text("收藏").font(.largeTitle.bold())
            List(items) { ch in
                HStack {
                    Button(ch.name) { model.play(channel: ch) }.buttonStyle(.plain)
                    Spacer()
                    Button("取消收藏") { model.toggleFavorite(ch) }.buttonStyle(.borderless)
                }
            }
            PlayerPanel().frame(maxWidth: 850)
        }.padding(28)
    }
}

struct HistoryView: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        VStack(alignment: .leading) {
            HStack {
                Text("历史").font(.largeTitle.bold())
                Spacer()
                Button("清空") { model.clearHistory() }
            }
            List(model.history) { item in
                Button {
                    model.play(history: item)
                } label: {
                    HStack {
                        Text(item.name)
                        Spacer()
                        Text(item.date, style: .relative).foregroundStyle(.secondary)
                    }
                }.buttonStyle(.plain)
            }
            PlayerPanel().frame(maxWidth: 850)
        }.padding(28)
    }
}

struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        Form {
            Section("直播") {
                TextField("直播源地址", text: $model.liveURL)
                Button("重新载入直播源") { Task { await model.loadLive() } }
            }
            Section("OpenList / WebDAV") {
                TextField("WebDAV 地址", text: $model.webDAVBase)
                TextField("用户名", text: $model.webDAVUser)
                SecureField("密码", text: $model.webDAVPassword)
                Text("推荐地址格式：http://192.168.1.x:5244/dav/")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("播放") {
                Toggle("软件解码（直播兼容性优先）", isOn: $model.softwareDecoding)
                Slider(value: $model.networkCache, in: 500...5000, step: 500) {
                    Text("网络缓冲")
                }
                Text("网络缓冲：\(Int(model.networkCache)) 毫秒；更改后点击播放器重试生效。")
                    .font(.caption).foregroundStyle(.secondary)
                Text("播放内核：VLC / VLCKit 3.7.3")
            }
            Section("说明") {
                Text("账号和密码只保存在这台 Mac 的本地偏好设置中，不写入 GitHub。")
            }
        }
        .formStyle(.grouped)
        .padding(20)
    }
}
