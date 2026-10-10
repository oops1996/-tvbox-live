import SwiftUI

struct FilmView: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var library: FilmLibrary
    @State private var managingSources = false
    @State private var selectedSource: UUID?
    @State private var filter = FilmFilter()
    @State private var category: String?
    @State private var query = ""
    @State private var section = "片库"
    @State private var selectedLine = ""
    @State private var playbackNote = ""
    private var sourceCategories: [FilmCategory] {
        library.categories.filter { filter.group == "全部" || FilmTaxonomy.group($0, in: library.categories) == filter.group }
    }
    private var years: [String] {
        let current = Calendar.current.component(.year, from: Date())
        return ["全部年份"] + (0..<15).map { String(current - $0) } + ["更早"]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("影视").font(.largeTitle.bold())
                Picker("浏览", selection: $section) {
                    Text("片库").tag("片库")
                    Text("热度榜").tag("热度榜")
                }.pickerStyle(.segmented).frame(width: 180)
                Spacer()
                Picker("当前源", selection: $selectedSource) {
                    Text("请选择源").tag(nil as UUID?)
                    ForEach(library.sources) { source in
                        Text(source.name + (source.canBrowse ? "" : " · " + (source.kind == .subscription ? "订阅" : "暂不支持")))
                            .tag(source.id as UUID?)
                    }
                }.frame(maxWidth: 300)
                Button("管理 / 导入源") { managingSources = true }
            }
            if section == "热度榜" {
                FilmRankingView(canSearch: library.selected?.canBrowse == true) { name in
                    filter = FilmFilter(); category = nil; query = name; section = "片库"
                    refresh()
                }
            } else {
                catalogue
            }
        }.padding(24)
        .sheet(isPresented: $managingSources) { FilmSourceManager(library: library) }
        .onChange(of: selectedSource) { value in
            guard let value else { if library.selectedID != nil { library.clearSelection() }; return }
            guard value != library.selectedID else { return }
            filter = FilmFilter(); category = nil; query = ""
            Task { await library.select(value) }
        }
        .task {
            selectedSource = library.selectedID
            if let id = library.selectedID, library.items.isEmpty { await library.select(id) }
        }
        .onChange(of: library.selectedID) { value in
            selectedSource = value; filter = FilmFilter(); category = nil; query = ""
        }
        .onChange(of: filter) { _ in category = nil; refresh() }
        .onChange(of: category) { _ in refresh() }
    }

    private var catalogue: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                TextField("搜索当前源的影片", text: $query).textFieldStyle(.roundedBorder).onSubmit { refresh() }
                Button("搜索") { refresh() }.disabled(library.busy || library.selected?.canBrowse != true)
                Button("刷新") { refresh() }.disabled(library.busy || library.selected?.canBrowse != true)
                if library.busy { ProgressView().controlSize(.small) }
            }
            HStack {
                Picker("类型", selection: $filter.group) { ForEach(FilmTaxonomy.groups, id: \.self) { Text($0).tag($0) } }
                Picker("地区", selection: $filter.region) { ForEach(FilmTaxonomy.regions, id: \.self) { Text($0).tag($0) } }
                Picker("题材", selection: $filter.genre) { ForEach(FilmTaxonomy.genres, id: \.self) { Text($0).tag($0) } }
                Picker("年份", selection: $filter.year) { ForEach(years, id: \.self) { Text($0).tag($0) } }
                Button("重置") { filter = FilmFilter(); category = nil; query = ""; refresh() }
            }.disabled(library.selected?.canBrowse != true)
            if !sourceCategories.isEmpty {
                Picker("源内栏目", selection: $category) {
                    Text("全部栏目").tag(nil as String?)
                    ForEach(sourceCategories) { Text($0.name).tag($0.id as String?) }
                }.frame(maxWidth: 360)
            }
            Text(library.status).font(.caption).foregroundStyle(.secondary)
            Text("按源内栏目及影片资料筛选，可继续加载更多结果。地区、年份、题材资料缺失的影片不会归入对应筛选。")
                .font(.caption2).foregroundStyle(.secondary)
            if library.selected?.kind == .subscription, let source = library.selected {
                Button("导入此订阅分支") { Task { await library.importURL(source.api) } }.disabled(library.busy)
            }
            HSplitView {
                VStack(alignment: .leading, spacing: 10) {
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
                                    Text([item.category, item.area, item.year, item.remarks].filter { !$0.isEmpty }.joined(separator: " · "))
                                        .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                                }
                            }
                        }.buttonStyle(.plain)
                    }.overlay {
                        if library.items.isEmpty && !library.busy { Text(library.hasMore ? "暂未找到匹配影片，可继续加载" : "没有匹配影片，请调整筛选或更换源").font(.caption).foregroundStyle(.secondary).padding() }
                    }
                    HStack {
                        Text("已显示 \(library.items.count) 部").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button(library.hasMore ? "继续加载" : "已到末尾") { Task { await library.loadMore() } }
                            .disabled(library.busy || !library.hasMore)
                    }
                }.frame(minWidth: 290)
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        PlayerPanel()
                        if let detail = library.detail {
                            Text(detail.name).font(.title2.bold())
                            Text([detail.category, detail.area, detail.year, detail.genre, detail.language].filter { !$0.isEmpty }.joined(separator: " · "))
                                .font(.caption).foregroundStyle(.secondary)
                            if !detail.lines.isEmpty {
                                Picker("播放线路", selection: $selectedLine) {
                                    Text("请选择线路").tag("")
                                    ForEach(detail.lines) { Text($0.name).tag($0.id) }
                                }
                                let line = detail.lines.first { $0.id == selectedLine } ?? detail.lines.first
                                if let line {
                                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 90))], alignment: .leading) {
                                        ForEach(line.episodes) { episode in Button(episode.name) { play(detail: detail, episode: episode) }.lineLimit(1) }
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
        }
    }
    private func refresh() {
        let requestedFilter = filter, requestedCategory = category, requestedSearch = query
        Task { await library.browse(filter: requestedFilter, category: requestedCategory, search: requestedSearch) }
    }
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

private struct FilmSourceDeletion: Identifiable {
    let id = UUID()
    let sources: [FilmSource]
}

struct FilmSourceManager: View {
    @ObservedObject var library: FilmLibrary
    @Environment(\.dismiss) private var dismiss
    @State private var address = ""
    @State private var checked = Set<UUID>()
    @State private var deletion: FilmSourceDeletion?
    private var allIDs: Set<UUID> { Set(library.sources.map(\.id)) }
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
            HStack {
                Button(checked == allIDs && !allIDs.isEmpty ? "取消全选" : "全选") {
                    checked = checked == allIDs ? [] : allIDs
                }.disabled(allIDs.isEmpty)
                Text("已选 \(checked.count) / \(library.sources.count) 个源").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("删除所选（\(checked.count)）", role: .destructive) {
                    deletion = FilmSourceDeletion(sources: library.sources.filter { checked.contains($0.id) })
                }.disabled(checked.isEmpty)
            }
            Text(library.status).font(.caption).foregroundStyle(.secondary)
            List(library.sources) { source in
                HStack {
                    Toggle("选择 \(source.name)", isOn: Binding(get: { checked.contains(source.id) }, set: { value in
                        if value { checked.insert(source.id) } else { checked.remove(source.id) }
                    })).toggleStyle(.checkbox).labelsHidden().accessibilityLabel("选择 \(source.name)")
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
        }.padding(24).frame(width: 800, height: 600)
        .onChange(of: library.sources) { _ in checked.formIntersection(allIDs) }
        .sheet(item: $deletion) { request in
            VStack(alignment: .leading, spacing: 14) {
                Text("删除这 \(request.sources.count) 个源？").font(.title2.bold())
                Text("仅移除下面列出的影视源配置；影视文件、收藏、历史和网盘设置不受影响。删除后可重新导入。")
                List(request.sources) { source in
                    VStack(alignment: .leading) { Text(source.name); Text(source.api).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
                }
                HStack {
                    Spacer()
                    Button("取消") { deletion = nil }.keyboardShortcut(.cancelAction)
                    Button("确认删除 \(request.sources.count) 个源", role: .destructive) {
                        library.removeSources(Set(request.sources.map(\.id))); checked.subtract(request.sources.map(\.id)); deletion = nil
                    }
                }
            }.padding(24).frame(width: 650, height: 420)
        }
    }
}

struct FilmRankingView: View {
    var canSearch: Bool
    var search: (String) -> Void
    @StateObject private var ranking = FilmRankingLibrary()
    @State private var group = "电视剧"
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Picker("榜单", selection: $group) { ForEach(["总榜", "电视剧", "电影", "综艺", "动漫", "短剧"], id: \.self) { Text($0).tag($0) } }
                    .pickerStyle(.segmented).frame(maxWidth: 520)
                Spacer()
                if ranking.busy { ProgressView().controlSize(.small) }
                Button("刷新榜单") { Task { await ranking.refresh(group) } }.disabled(ranking.busy)
                Link("官方榜单", destination: FilmRankingClient.url(group))
            }
            Text("爱奇艺热播榜 · 按平台实时热度排名").font(.headline)
            Text("榜单反映爱奇艺平台热度。点“在当前源搜索”查找片名，能否播放取决于所选源。")
                .font(.caption).foregroundStyle(.secondary)
            if let snapshot = ranking.snapshot {
                Text("官方更新：\(snapshot.updated.formatted(date: .numeric, time: .shortened)) · 读取时间：\(snapshot.fetched.formatted(date: .omitted, time: .shortened))")
                    .font(.caption).foregroundStyle(.secondary)
                List(snapshot.items) { item in
                    HStack(spacing: 16) {
                        Text(String(item.rank)).font(.title2.bold()).foregroundStyle(item.rank <= 3 ? Color.orange : Color.secondary).frame(width: 35)
                        VStack(alignment: .leading, spacing: 6) { Text(item.name).font(.headline); Text(item.metadata).font(.caption).foregroundStyle(.secondary) }
                        Spacer()
                        Text("热度 \(item.heat)").monospacedDigit()
                        Button("在当前源搜索") { search(item.name) }.disabled(!canSearch)
                    }.padding(.vertical, 6)
                }
            } else {
                Spacer()
                Text(ranking.busy ? "正在读取官方热度榜…" : ranking.error).foregroundStyle(.secondary).frame(maxWidth: .infinity)
                Spacer()
            }
            if !canSearch { Text("先选择可用影视源，即可搜索榜单片名。").font(.caption).foregroundStyle(.secondary) }
        }
        .task(id: group) {
            await ranking.refresh(group)
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: 300_000_000_000) } catch { return }
                guard !Task.isCancelled else { return }
                await ranking.refresh(group)
            }
        }
    }
}
