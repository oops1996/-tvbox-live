import Foundation
import Combine

enum FilmSourceKind: String, Codable { case json, xml, subscription, plugin }

struct FilmSource: Identifiable, Codable, Hashable {
    let id: UUID
    var name: String
    var api: String
    var origin: String
    var kind: FilmSourceKind
    var note: String
    var canBrowse: Bool { kind == .json || kind == .xml }
}

struct FilmCategory: Identifiable, Hashable {
    let id: String
    let name: String
    var parentID = ""
    var group: String { FilmTaxonomy.group(name) }
}

struct FilmEpisode: Identifiable, Hashable {
    var id: String { url + name }
    let name: String
    let url: String
}
struct FilmLine: Identifiable, Hashable {
    var id: String { name + (episodes.first?.url ?? "") }
    let name: String
    let episodes: [FilmEpisode]
}
struct FilmItem: Identifiable, Hashable {
    let id: String
    let name: String
    let category: String
    let poster: String
    let remarks: String
    let description: String
    let lines: [FilmLine]
    var categoryID = ""
    var parentCategoryID = ""
    var area = ""
    var year = ""
    var genre = ""
    var language = ""
}
struct FilmPage {
    var categories: [FilmCategory] = []
    var items: [FilmItem] = []
    var pageCount = 1
}

enum SourceError: LocalizedError {
    case invalidURL, http(Int), format, unsupported, empty
    var errorDescription: String? {
        switch self {
        case .invalidURL: return "请输入完整的 HTTP / HTTPS 接口地址；账号密码请勿写入链接。"
        case .http(let code): return "接口返回 HTTP \(code)，请检查链接或更换源。"
        case .format: return "没有识别到有效配置。链接可能是网页、已失效，或采用了不支持的加密格式。"
        case .unsupported: return "此站点依赖 Android 插件，当前 Mac 版无法运行。请更换为 JSON / XML 采集接口。"
        case .empty: return "接口没有返回分类或影片，请更换源或重试。"
        }
    }
}

enum FilmSourceClient {
    static func url(_ text: String) throws -> URL {
        guard let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil,
              url.user == nil, url.password == nil else { throw SourceError.invalidURL }
        return url
    }

    static func fetch(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.setValue("okhttp/3.12.13", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw SourceError.format }
        guard (200...299).contains(http.statusCode) else { throw SourceError.http(http.statusCode) }
        guard data.count <= 5_000_000 else { throw SourceError.format }
        return data
    }

    /// Read common TVBox image/base64 envelopes as data; never download or execute spider code.
    static func json(_ data: Data) throws -> [String: Any] {
        var payload = data
        if data.starts(with: [0xff, 0xd8]),
           let end = data.range(of: Data([0xff, 0xd9])),
           let marker = data.range(of: Data("**".utf8), in: end.upperBound..<data.endIndex),
           let decoded = Data(base64Encoded: data[marker.upperBound...], options: .ignoreUnknownCharacters) {
            payload = decoded
        } else if let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  text.hasPrefix("**"), let decoded = Data(base64Encoded: String(text.dropFirst(2))) {
            payload = decoded
        }
        guard let result = try? JSONSerialization.jsonObject(with: payload, options: [.json5Allowed]) as? [String: Any] else {
            throw SourceError.format
        }
        return result
    }

    static func importSources(from value: String) async throws -> [FilmSource] {
        let address = try url(value)
        let data = try await fetch(address)
        if String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("<") == true,
           (try? parseXML(data).categories.isEmpty) == false {
            return [FilmSource(id: UUID(), name: address.host ?? "XML 接口", api: address.absoluteString,
                               origin: value, kind: .xml, note: "XML 采集接口")]
        }
        let root = try json(data)
        var result: [FilmSource] = []
        for entry in (root["urls"] as? [[String: Any]] ?? []).prefix(100) {
            guard let child = entry["url"] as? String,
                  let resolved = URL(string: child, relativeTo: address)?.absoluteURL,
                  (try? url(resolved.absoluteString)) != nil else { continue }
            result.append(FilmSource(id: UUID(), name: string(entry["name"]), api: resolved.absoluteString,
                                     origin: value, kind: .subscription, note: "订阅分支：点击导入"))
        }
        for entry in (root["sites"] as? [[String: Any]] ?? []).prefix(200) {
            let api = string(entry["api"])
            let type = Int(string(entry["type"])) ?? -1
            let resolved = URL(string: api, relativeTo: address)?.absoluteURL.absoluteString ?? api
            let native = (type == 0 || type == 1) && (try? url(resolved)) != nil
            let kind: FilmSourceKind = native ? (type == 0 ? .xml : .json) : .plugin
            result.append(FilmSource(id: UUID(), name: string(entry["name"]), api: native ? resolved : api,
                                     origin: value, kind: kind,
                                     note: native ? "可读取分类和剧集，播放需实测" : "需要 Android / JS 插件，Mac 暂不支持"))
        }
        if result.isEmpty && (root["class"] != nil || root["list"] != nil) {
            result.append(FilmSource(id: UUID(), name: address.host ?? "影视接口", api: address.absoluteString,
                                     origin: value, kind: .json, note: "JSON 采集接口"))
        }
        guard !result.isEmpty else { throw SourceError.format }
        return result
    }

    static func request(_ source: FilmSource, category: String? = nil, page: Int = 1,
                        search: String? = nil, id: String? = nil) async throws -> FilmPage {
        guard source.canBrowse else { throw SourceError.unsupported }
        var components = URLComponents(url: try url(source.api), resolvingAgainstBaseURL: false)!
        var query = components.queryItems ?? []
        let managed = Set(["ac", "t", "pg", "wd", "ids"])
        query.removeAll { managed.contains($0.name) }
        query.append(URLQueryItem(name: "ac", value: source.kind == .xml ? "videolist" : "detail"))
        query.append(URLQueryItem(name: "pg", value: String(page)))
        if let category { query.append(URLQueryItem(name: "t", value: category)) }
        if let search, !search.isEmpty { query.append(URLQueryItem(name: "wd", value: search)) }
        if let id { query.append(URLQueryItem(name: "ids", value: id)) }
        components.queryItems = query
        guard let endpoint = components.url else { throw SourceError.invalidURL }
        let data = try await fetch(endpoint)
        var result = try source.kind == .xml ? parseXML(data) : parseJSON(json(data))
        // Most CMS detail endpoints omit class; retrieve their public class list separately.
        if result.categories.isEmpty, category == nil, page == 1, id == nil, search?.isEmpty != false {
            components.queryItems = query.filter { !managed.contains($0.name) } + [URLQueryItem(name: "ac", value: "list"), URLQueryItem(name: "pg", value: "1")]
            if let classURL = components.url, let classData = try? await fetch(classURL),
               let classPage = try? source.kind == .xml ? parseXML(classData) : parseJSON(json(classData)) {
                result.categories = classPage.categories
            }
        }
        return result
    }

    static func string(_ value: Any?) -> String {
        if let s = value as? String { return s }
        if let n = value as? NSNumber { return n.stringValue }
        return ""
    }

    static func lines(names: String, urls: String) -> [FilmLine] {
        let labels = names.components(separatedBy: "$$$")
        return urls.components(separatedBy: "$$$").enumerated().compactMap { index, block in
            let episodes = block.components(separatedBy: "#").enumerated().compactMap { offset, value -> FilmEpisode? in
                let pair = value.split(separator: "$", maxSplits: 1).map(String.init)
                let link = pair.last?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                guard let endpoint = try? url(link) else { return nil }
                return FilmEpisode(name: pair.count == 2 ? pair[0] : "第 \(offset + 1) 集", url: endpoint.absoluteString)
            }
            guard !episodes.isEmpty else { return nil }
            return FilmLine(name: index < labels.count && !labels[index].isEmpty ? labels[index] : "线路 \(index + 1)", episodes: episodes)
        }
    }

    static func parseJSON(_ root: [String: Any]) -> FilmPage {
        let categories = (root["class"] as? [[String: Any]] ?? []).compactMap { item -> FilmCategory? in
            let id = string(item["type_id"]), name = string(item["type_name"])
            return id.isEmpty || name.isEmpty ? nil : FilmCategory(id: id, name: name, parentID: string(item["type_pid"]))
        }
        let items = (root["list"] as? [[String: Any]] ?? []).compactMap { item -> FilmItem? in
            let id = string(item["vod_id"]), name = string(item["vod_name"])
            guard !id.isEmpty, !name.isEmpty else { return nil }
            return FilmItem(id: id, name: name, category: string(item["type_name"]), poster: string(item["vod_pic"]),
                            remarks: string(item["vod_remarks"]), description: string(item["vod_content"]),
                            lines: lines(names: string(item["vod_play_from"]), urls: string(item["vod_play_url"])),
                            categoryID: string(item["type_id"]), parentCategoryID: string(item["type_id_1"]), area: string(item["vod_area"]), year: string(item["vod_year"]),
                            genre: string(item["vod_class"]), language: string(item["vod_lang"]))
        }
        return FilmPage(categories: categories, items: items, pageCount: max(1, Int(string(root["pagecount"])) ?? 1))
    }

    static func parseXML(_ data: Data) throws -> FilmPage {
        let parser = XMLParser(data: data)
        let delegate = FilmXMLParser()
        parser.shouldResolveExternalEntities = false
        parser.delegate = delegate
        guard parser.parse() else { throw SourceError.format }
        return delegate.result
    }
}

private final class FilmXMLParser: NSObject, XMLParserDelegate {
    var result = FilmPage()
    private var text = ""
    private var video: [String: String]?
    private var categoryID = ""
    private var parentID = ""
    private var lineName = ""
    private var playNames: [String] = []
    private var playURLs: [String] = []
    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
        text = ""
        if name == "ty" { categoryID = attributes["id"] ?? ""; parentID = attributes["pid"] ?? "" }
        if name == "list" { result.pageCount = max(1, Int(attributes["pagecount"] ?? "1") ?? 1) }
        if name == "video" { video = [:]; playNames = []; playURLs = [] }
        if name == "dd" { lineName = attributes["flag"] ?? "线路" }
    }
    func parser(_ parser: XMLParser, foundCharacters value: String) { text += value }
    func parser(_ parser: XMLParser, foundCDATA block: Data) { text += String(data: block, encoding: .utf8) ?? "" }
    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if name == "ty", !categoryID.isEmpty { result.categories.append(FilmCategory(id: categoryID, name: value, parentID: parentID)) }
        if name == "dd" { playNames.append(lineName); playURLs.append(value) }
        if name == "video", let v = video, let id = v["id"], let title = v["name"] {
            result.items.append(FilmItem(id: id, name: title, category: v["type"] ?? "", poster: v["pic"] ?? "",
                                         remarks: v["note"] ?? "", description: v["des"] ?? "",
                                         lines: FilmSourceClient.lines(names: playNames.joined(separator: "$$$"), urls: playURLs.joined(separator: "$$$")),
                                         categoryID: v["tid"] ?? "", parentCategoryID: v["tid1"] ?? "", area: v["area"] ?? "", year: v["year"] ?? "",
                                         genre: v["class"] ?? "", language: v["lang"] ?? ""))
            video = nil
        } else if video != nil { video?[name] = value }
        text = ""
    }
}

@MainActor
final class FilmLibrary: ObservableObject {
    @Published private(set) var sources: [FilmSource] = []
    @Published private(set) var selectedID: UUID?
    @Published private(set) var categories: [FilmCategory] = []
    @Published private(set) var items: [FilmItem] = []
    @Published private(set) var detail: FilmItem?
    @Published private(set) var status = "粘贴影视配置或采集接口地址，导入后可随时更换。"
    @Published private(set) var busy = false
    @Published private(set) var hasMore = false
    @Published private(set) var loadedPages = 0
    private var selectionToken = UUID()
    private let defaults: UserDefaults
    private var filter = FilmFilter()
    private var search = ""
    private var browseCategories: [String?] = []
    private var categoryIndex = 0
    private var nextPage = 1
    private var seen = Set<String>()
    var selected: FilmSource? { sources.first { $0.id == selectedID } }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: "filmSources"),
           let stored = try? JSONDecoder().decode([FilmSource].self, from: data) { sources = stored }
        selectedID = defaults.string(forKey: "filmSelectedID").flatMap(UUID.init(uuidString:))
        if selected == nil { selectedID = nil }
    }

    func importURL(_ text: String) async {
        let token = UUID(); selectionToken = token
        busy = true
        defer { if selectionToken == token { busy = false } }
        do {
            let imported = try await FilmSourceClient.importSources(from: text)
            guard selectionToken == token else { return }
            for var source in imported {
                if let index = sources.firstIndex(where: { $0.origin == source.origin && $0.api == source.api && $0.name == source.name }) {
                    source = FilmSource(id: sources[index].id, name: source.name, api: source.api, origin: source.origin, kind: source.kind, note: source.note)
                    sources[index] = source
                } else { sources.append(source) }
            }
            save()
            let native = imported.filter(\.canBrowse).count
            status = "已导入 \(imported.count) 个站点，其中 \(native) 个可直接读取。"
            busy = false
            if let first = sources.first(where: { $0.origin == text && $0.canBrowse }) { await select(first.id) }
        } catch { if selectionToken == token { status = "导入失败：\(error.localizedDescription)" } }
    }

    /// Called only after the user confirms the exact selected entries in source management.
    @discardableResult func removeSources(_ ids: Set<UUID>) -> Int {
        let count = sources.filter { ids.contains($0.id) }.count
        guard count > 0 else { return 0 }
        selectionToken = UUID(); busy = false
        sources.removeAll { ids.contains($0.id) }
        if let id = selectedID, ids.contains(id) {
            selectedID = nil
            defaults.removeObject(forKey: "filmSelectedID")
            categories = []; items = []; detail = nil; hasMore = false
            browseCategories = []; seen = []; loadedPages = 0
        }
        save()
        status = "已删除 \(count) 个源。可随时重新导入；影视文件和网盘设置不受影响。"
        return count
    }

    func clearSelection() {
        selectionToken = UUID(); busy = false; selectedID = nil
        defaults.removeObject(forKey: "filmSelectedID")
        categories = []; items = []; detail = nil; hasMore = false; loadedPages = 0
        status = "请选择影视源。"
    }

    func select(_ id: UUID) async {
        guard sources.contains(where: { $0.id == id }) else { return }
        selectionToken = UUID(); busy = false
        selectedID = id
        defaults.set(id.uuidString, forKey: "filmSelectedID")
        categories = []; items = []; detail = nil; hasMore = false; loadedPages = 0
        guard let selected else { return }
        guard selected.canBrowse else { status = selected.note; return }
        await browse()
    }

    func browse(filter: FilmFilter = FilmFilter(), category: String? = nil, search: String = "") async {
        guard let source = selected, source.canBrowse else { return }
        let token = UUID(); selectionToken = token; busy = true
        defer { if selectionToken == token { busy = false } }
        self.filter = filter; self.search = search.trimmingCharacters(in: .whitespacesAndNewlines)
        items = []; detail = nil; seen = []; loadedPages = 0; categoryIndex = 0; nextPage = 1; hasMore = false
        do {
            var initial: FilmPage?
            if categories.isEmpty {
                let result = try await FilmSourceClient.request(source)
                guard selectionToken == token else { return }
                categories = result.categories
                if filter.isEmpty, category == nil, self.search.isEmpty { initial = result }
            }
            if !self.search.isEmpty { browseCategories = [nil] }
            else if let category { browseCategories = [category] }
            else { browseCategories = filter.candidateCategories(categories) }
            hasMore = !browseCategories.isEmpty
            if let initial {
                append(initial.items)
                loadedPages = 1; nextPage = 2; hasMore = initial.pageCount > 1
                if !hasMore { categoryIndex = browseCategories.count }
                updateStatus(source)
            } else { await readMore(source, token: token) }
        } catch { if selectionToken == token { status = "读取失败：\(error.localizedDescription)" } }
    }

    func loadMore() async {
        guard !busy, hasMore, let source = selected else { return }
        let token = UUID(); selectionToken = token; busy = true
        defer { if selectionToken == token { busy = false } }
        await readMore(source, token: token)
    }

    private func readMore(_ source: FilmSource, token: UUID) async {
        let startingCount = items.count
        // Bound each action; continue from the last source page when the user loads more.
        for _ in 0..<6 {
            guard selectionToken == token, categoryIndex < browseCategories.count else { break }
            do {
                let result = try await FilmSourceClient.request(source, category: browseCategories[categoryIndex], page: nextPage, search: search)
                guard selectionToken == token else { return }
                append(result.items); loadedPages += 1
                if nextPage >= result.pageCount { categoryIndex += 1; nextPage = 1 }
                else { nextPage += 1 }
                hasMore = categoryIndex < browseCategories.count
                if !hasMore || items.count - startingCount >= 40 { break }
            } catch {
                guard selectionToken == token else { return }
                status = "读取失败：\(error.localizedDescription)；已加载结果保留，点击继续加载重试。"
                return
            }
        }
        guard selectionToken == token else { return }
        updateStatus(source)
    }

    private func append(_ values: [FilmItem]) {
        for item in values where filter.matches(item, categories: categories) {
            if seen.insert(item.id).inserted { items.append(item) }
        }
    }
    private func updateStatus(_ source: FilmSource) {
        status = "\(source.name) · 已检查 \(loadedPages) 页 · 找到 \(items.count) 部" + (hasMore ? "，可继续加载" : "，已到末尾")
    }

    func open(_ item: FilmItem) async {
        guard let source = selected else { return }
        let token = UUID(); selectionToken = token; busy = true
        defer { if selectionToken == token { busy = false } }
        do {
            let result = try await FilmSourceClient.request(source, id: item.id)
            guard selectionToken == token else { return }
            detail = result.items.first ?? item
            status = detail?.lines.isEmpty == true ? "此影片没有返回可识别的剧集链接。" : "选择线路和剧集播放。"
        } catch { if selectionToken == token { status = "影片读取失败：\(error.localizedDescription)" } }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(sources) { defaults.set(data, forKey: "filmSources") }
    }
}
