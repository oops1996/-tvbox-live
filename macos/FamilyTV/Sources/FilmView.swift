import SwiftUI

struct FilmView: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var library: FilmLibrary
    @State private var managingSources = false
    @State private var selectedSource: UUID?
    @State private var category: String?
    @State private var group = "全部"
    @State private var query = ""
    @State private var selectedLine = ""
    @State private var playbackNote = ""
    private var groups: [String] {
        ["全部"] + ["电影", "电视剧", "综艺", "动漫", "短剧", "戏曲", "音乐", "体育", "学习", "其他"].filter { name in
            library.categories.contains { $0.group == name }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("影视").font(.largeTitle.bold())
                Spacer()
                Picker("当前源", selection: $selectedSource) {
                    Text("请选择源").tag(nil as UUID?)
                    ForEach(library.sources) { source in
                        Text(source.name + (source.canBrowse ? "" : " · " + (source.kind == .subscription ? "订阅" : "暂不支持")))
                            .tag(source.id as UUID?)
                    }
                }.frame(maxWidth: 330)
                Button("管理 / 导入源") { managingSources = true }
            }
            HStack {
                TextField("搜索当前源的影片", text: $query).textFieldStyle(.roundedBorder)
                    .onSubmit { search() }
                Button("搜索") { search() }.disabled(library.busy || library.selected?.canBrowse != true)
                Button("刷新") { Task { await library.load(category: category) } }
                    .disabled(library.busy || library.selected?.canBrowse != true)
                if library.busy { ProgressView().controlSize(.small) }
            }
            Text(library.status).font(.caption).foregroundStyle(.secondary)
            if library.selected?.kind == .subscription, let source = library.selected {
                Button("导入此订阅分支") { Task { await library.importURL(source.api) } }.disabled(library.busy)
            }
            HSplitView {
                VStack(alignment: .leading, spacing: 10) {
                    if !library.categories.isEmpty {
                        Picker("分类", selection: $group) {
                            ForEach(groups, id: \.self) { Text($0).tag($0) }
                        }.pickerStyle(.menu)
                        ScrollView(.horizontal) {
                            HStack {
                                Button("全部内容") { category = nil; Task { await library.load() } }
                                ForEach(library.categories.filter { group == "全部" || $0.group == group }) { item in
                                    Button(item.name) { category = item.id; query = ""; Task { await library.load(category: item.id) } }
                                        .tint(category == item.id ? .accentColor : .secondary)
                                }
                            }
                        }
                    }
                    List(library.items) { item in
                        Button {
                            selectedLine = ""; playbackNote = ""
                            Task { await library.open(item) }
                        } label: {
                            HStack(spacing: 12) {
                                AsyncImage(url: URL(string: item.poster)) { image in image.resizable().scaledToFill() }
                                placeholder: { Rectangle().fill(.quaternary).overlay(Image(systemName: "film")) }
                                    .frame(width: 48, height: 65).clipped()
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(item.name).lineLimit(2)
                                    Text([item.category, item.remarks].filter { !$0.isEmpty }.joined(separator: " · "))
                                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                            }
                        }.buttonStyle(.plain)
                    }
                    HStack {
                        Button("上一页") { loadPage(library.page - 1) }.disabled(library.busy || library.page <= 1)
                        Spacer()
                        Text("\(library.page) / \(library.pageCount)").font(.caption)
                        Spacer()
                        Button("下一页") { loadPage(library.page + 1) }.disabled(library.busy || library.page >= library.pageCount)
                    }
                }.frame(minWidth: 290)
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        PlayerPanel()
                        if let detail = library.detail {
                            Text(detail.name).font(.title2.bold())
                            if !detail.lines.isEmpty {
                                Picker("播放线路", selection: $selectedLine) {
                                    Text("请选择线路").tag("")
                                    ForEach(detail.lines) { Text($0.name).tag($0.id) }
                                }
                                let line = detail.lines.first { $0.id == selectedLine } ?? detail.lines.first
                                if let line {
                                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 90))], alignment: .leading) {
                                        ForEach(line.episodes) { episode in
                                            Button(episode.name) { play(detail: detail, episode: episode) }
                                                .lineLimit(1)
                                        }
                                    }
                                }
                            }
                            if !playbackNote.isEmpty { Text(playbackNote).font(.caption).foregroundStyle(.orange) }
                            if !detail.description.isEmpty {
                                Text(detail.description.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }.padding(.leading, 16)
                }.frame(minWidth: 420)
            }
        }.padding(24)
        .sheet(isPresented: $managingSources) { FilmSourceManager(library: library) }
        .onChange(of: selectedSource) { value in
            guard let value else { return }
            category = nil; group = "全部"; query = ""
            Task { await library.select(value) }
        }
        .task { if let id = library.selectedID { selectedSource = id } }
        .onChange(of: library.selectedID) { selectedSource = $0 }
        .onChange(of: group) { value in
            guard value != "全部", let first = library.categories.first(where: { $0.group == value }) else { return }
            category = first.id; query = ""; Task { await library.load(category: first.id) }
        }
    }

    private func search() { category = nil; Task { await library.load(search: query) } }
    private func loadPage(_ page: Int) { Task { await library.load(category: category, page: page, search: query) } }
    private func play(detail: FilmItem, episode: FilmEpisode) {
        guard let url = URL(string: episode.url) else { return }
        let blockedHosts = ["youku.com", "iqiyi.com", "v.qq.com", "mgtv.com", "bilibili.com"]
        if blockedHosts.contains(where: { url.host == $0 || url.host?.hasSuffix("." + $0) == true }) {
            playbackNote = "这条线路返回的是网页地址，需要源提供直连媒体或 Mac 可用的解析接口。请切换线路或源。"
            return
        }
        playbackNote = ""
        model.play(name: detail.name + " · " + episode.name, url: episode.url, headers: [:])
    }
}

struct FilmSourceManager: View {
    @ObservedObject var library: FilmLibrary
    @Environment(\.dismiss) private var dismiss
    @State private var address = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("管理影视源").font(.title2.bold())
                Spacer()
                Button("完成") { dismiss() }
            }
            Text("可导入 TVBox 配置、订阅列表或 JSON / XML 采集接口，地址可随时更换。")
            HStack {
                TextField("粘贴完整接口地址", text: $address).textFieldStyle(.roundedBorder)
                Button("导入 / 更新") { Task { await library.importURL(address) } }
                    .disabled(library.busy || address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            Text(library.status).font(.caption).foregroundStyle(.secondary)
            List(library.sources) { source in
                HStack {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(source.name).font(.headline)
                        Text(source.note).font(.caption).foregroundStyle(source.canBrowse ? Color.secondary : Color.orange)
                        Text(source.origin).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer()
                    Button("编辑链接") { address = source.origin }
                    if source.canBrowse {
                        Button("使用") { Task { await library.select(source.id) }; dismiss() }
                    } else if source.kind == .subscription {
                        Button("导入分支") { Task { await library.importURL(source.api) } }.disabled(library.busy)
                    }
                }.padding(.vertical, 5)
            }
            Text("Android / JS 插件和加密脚本暂不支持；能导入配置不代表站点或剧集已经验证可播放。")
                .font(.caption).foregroundStyle(.secondary)
        }.padding(24).frame(width: 760, height: 560)
    }
}
