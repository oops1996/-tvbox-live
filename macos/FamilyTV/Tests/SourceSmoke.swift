import Foundation
@main struct SourceSmoke {
 enum Failure: LocalizedError {
  case check(String)
  var errorDescription: String? { if case .check(let text) = self { return text }; return nil }
 }
 static func check(_ condition: @autoclosure () -> Bool, _ label: String) throws { if !condition() { throw Failure.check(label) } }
 @MainActor static func main() async {
  do { let base = CommandLine.arguments[1]
        let imported = try await FilmSourceClient.importSources(from: base + "/config.json")
        try check(imported.count == 2 && imported.filter(\.canBrowse).count == 1, "TVBox compatibility detection failed")
        let native = imported.first { $0.canBrowse }!
        let home = try await FilmSourceClient.request(native)
        try check(Set(home.categories.map(\.group)) == Set(["电影", "电视剧", "综艺"]), "Categories failed")
        let category = try await FilmSourceClient.request(native, category: "2", page: 2)
        try check(category.items.first?.name == "第 2 页电视剧", "Category or page parameters failed")
        let search = try await FilmSourceClient.request(native, search: "测试 搜索")
        try check(search.items.first?.name == "测试 搜索", "Search encoding failed")
        let detail = try await FilmSourceClient.request(native, id: "1")
        try check(detail.items.first?.lines.first?.episodes.count == 2, "Episode parsing failed")
        let xml = try await FilmSourceClient.importSources(from: base + "/api.xml")
        let xmlPage = try await FilmSourceClient.request(xml[0])
        try check(xmlPage.categories.count == 3 && xmlPage.items.first?.lines.first?.episodes.count == 2, "XML catalogue failed")
        let embedded = Data([0xff,0xd8,0xff,0xd9]) + Data("marker**".utf8) + Data(Data("{ /* comment */ sites: [], }".utf8).base64EncodedString().utf8)
        let embeddedJSON = try FilmSourceClient.json(embedded)
        try check(embeddedJSON["sites"] != nil, "Image/JSON5 envelope failed")
        let unicodeURL = try FilmSourceClient.url("http://www.饭太硬.net/tv")
        try check(unicodeURL.host != nil, "Unicode URL failed")
        try check(xmlPage.items.first?.area == "美国" && xmlPage.items.first?.year == "2026", "XML metadata failed")
        try check(FilmTaxonomy.group("喜剧片") == "电影" && FilmTaxonomy.group("纪录片") == "纪录片", "Movie type precedence failed")
        let parentCategories = [FilmCategory(id: "1", name: "电影"), FilmCategory(id: "10", name: "悬疑", parentID: "1")]
        try check(FilmTaxonomy.group(parentCategories[1], in: parentCategories) == "电影", "Parent category failed")
        let short = FilmSourceClient.parseJSON(["list": [["vod_id": "short", "vod_name": "测试短剧", "type_name": "现代都市", "type_id_1": "54"]]])
        try check(FilmTaxonomy.group(short.items[0], in: [FilmCategory(id: "54", name: "爽文短剧")]) == "短剧", "Item parent ID classification failed")
        let flatShort = [FilmCategory(id: "54", name: "爽文短剧"), FilmCategory(id: "69", name: "现代都市"), FilmCategory(id: "65", name: "反转爽剧")]
        try check(FilmFilter(group: "短剧").candidateCategories(flatShort).compactMap { $0 } == ["54", "69", "65"], "Flat CMS short-drama subcolumns missed")
        var unknown = FilmItem(id: "x", name: "地区测试", category: "欧美剧", poster: "", remarks: "", description: "", lines: [])
        let american = FilmFilter(group: "电视剧", region: "美国", genre: "全部题材", year: "全部年份")
        try check(!american.matches(unknown, categories: []), "Broad 欧美 bucket incorrectly becomes 美国")
        try check(!FilmTaxonomy.regions("日韩动漫").contains("韩国") && !FilmTaxonomy.regions("港台剧").contains("中国台湾"), "Broad regional buckets become exact countries")
        unknown.area = "美国,英国"; unknown.genre = "犯罪,悬疑"; unknown.year = "2026"
        try check(american.matches(unknown, categories: []), "US metadata filter failed")
        try check(FilmFilter(group: "电视剧", region: "英国", genre: "悬疑", year: "2026").matches(unknown, categories: []), "Combined metadata filter failed")
        try check(!FilmFilter(group: "电影").matches(unknown, categories: []), "Type mismatch leaked")
        let suite = UserDefaults(suiteName: "familytv-tests-" + UUID().uuidString)!
        let browsingSource = FilmSource(id: UUID(), name: "分页测试", api: base + "/browse.json", origin: base, kind: .json, note: "")
        suite.set(try JSONEncoder().encode([browsingSource]), forKey: "filmSources")
        let library = FilmLibrary(defaults: suite)
        await library.select(browsingSource.id)
        await library.browse(filter: american)
        try check(library.items.map(\.id) == ["102"] && library.loadedPages == 2 && !library.hasMore, "Filtered pagination failed to reach matching later page")
        let reopened = FilmLibrary(defaults: suite)
        try check(reopened.selectedID == browsingSource.id, "Selection persistence failed")
        try check(library.removeSources([UUID()]) == 0 && library.sources.count == 1, "Unselected sources removed")
        try check(library.removeSources([browsingSource.id]) == 1, "Selected deletion count failed")
        try check(library.items.isEmpty && library.selectedID == nil && FilmLibrary(defaults: suite).sources.isEmpty, "Deletion persistence or selection cleanup failed")
        let slow = FilmSource(id: UUID(), name: "延迟测试", api: base + "/slow.json", origin: base, kind: .json, note: "")
        suite.set(try JSONEncoder().encode([slow]), forKey: "filmSources")
        let slowLibrary = FilmLibrary(defaults: suite)
        let task = Task { await slowLibrary.select(slow.id) }
        while !slowLibrary.busy { await Task.yield() }
        slowLibrary.removeSources([slow.id]); await task.value
        try check(slowLibrary.items.isEmpty && slowLibrary.selectedID == nil && !slowLibrary.busy, "Deleted source restored by in-flight request")
        let fixedNow = ISO8601DateFormatter().date(from: "2026-01-01T01:00:00Z")!
        let row = "<a class=\"rvi__box rvi__box3\"><span class=\"rvi__No__txt\">1</span><div title=\"测试&amp;剧\" class=\"rvi__tit1\">测试</div><div title=\"2026 / 悬疑\" class=\"rvi__type1\"></div><span class=\"rvi__index__num\">7654</span>实时热度</a>"
        let ranking = try FilmRankingClient.parse("最近更新12-31 23:00" + row, url: FilmRankingClient.url("电视剧"), now: fixedNow)
        try check(ranking.items.first?.name == "测试&剧" && ranking.items.first?.heat == "7654" && Calendar.current.component(.year, from: ranking.updated) == 2025, "Ranking data or year rollover failed")
        try check((try? FilmRankingClient.parse("最近更新12-20 23:00" + row, url: ranking.url, now: fixedNow)) == nil, "Stale ranking presented as current")
        try check((try? FilmRankingClient.parse("最近更新12-31 23:00", url: ranking.url, now: fixedNow)) == nil, "Empty ranking accepted")
   print("PASS: TVBox import, native/plugin detection, JSON/XML categories, pagination, search, episodes, image envelope, metadata, combined filters, later-page matches, source deletion persistence/races and ranking freshness")
  } catch { print("FAIL:", error.localizedDescription); exit(1) }
 }
}
