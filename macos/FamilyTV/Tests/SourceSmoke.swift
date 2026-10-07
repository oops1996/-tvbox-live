import Foundation
@main struct SourceSmoke {
 enum Failure: LocalizedError {
  case check(String)
  var errorDescription: String? { if case .check(let text) = self { return text }; return nil }
 }
 static func check(_ condition: @autoclosure () -> Bool, _ label: String) throws { if !condition() { throw Failure.check(label) } }
 static func main() async {
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
   print("PASS: TVBox import, native/plugin detection, JSON/XML categories, pagination, search, episodes, image envelope and Unicode URLs")
  } catch { print("FAIL:", error.localizedDescription); exit(1) }
 }
}
