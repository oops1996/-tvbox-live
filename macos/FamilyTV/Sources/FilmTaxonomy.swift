import Foundation

/// Classification uses source metadata; a broad 欧美 label never becomes 美国.
enum FilmTaxonomy {
    // Common CMS short-drama subcolumns; only used when that source declares a short-drama root.
    static let shortColumns: Set<String> = ["女频恋爱", "反转爽剧", "古装仙侠", "年代穿越", "脑洞悬疑", "现代都市", "都市脑洞"]
    static let groups = ["全部", "电影", "电视剧", "综艺", "动漫", "短剧", "纪录片", "戏曲", "音乐", "体育", "学习", "其他"]
    static let regions = ["全部地区", "国产", "中国香港", "中国台湾", "港台", "韩国", "日本", "日韩", "美国", "英国", "法国", "德国", "泰国", "印度", "欧美", "其他地区"]
    static let genres = ["全部题材", "动作", "喜剧", "爱情", "科幻", "悬疑", "惊悚", "恐怖", "犯罪", "剧情", "战争", "历史", "古装", "武侠", "奇幻", "家庭", "青春", "冒险", "纪录", "真人秀", "都市", "励志", "谍战", "仙侠", "穿越", "校园", "热血", "儿童"]
    static func group(_ name: String) -> String {
        if name.contains("短剧") || name.contains("微剧") { return "短剧" }
        if name.contains("综艺") || name.contains("真人秀") { return "综艺" }
        if name.contains("动漫") || name.contains("动画") || name.contains("漫剧") { return "动漫" }
        if name.contains("纪录") || name.contains("记录片") { return "纪录片" }
        if ["戏曲", "相声", "评书"].contains(where: name.contains) { return "戏曲" }
        if ["音乐", "演唱"].contains(where: name.contains) { return "音乐" }
        if ["体育", "足球", "篮球", "球赛"].contains(where: name.contains) { return "体育" }
        if ["教学", "学习", "教育"].contains(where: name.contains) { return "学习" }
        if name.contains("电影") || name.hasSuffix("片") { return "电影" }
        if name.contains("电视") || (name.hasSuffix("剧") && name != "喜剧") { return "电视剧" }
        return "其他"
    }
    static func group(_ category: FilmCategory, in categories: [FilmCategory]) -> String {
        if let parent = categories.first(where: { $0.id == category.parentID }), parent.group != "其他" {
            return category.group == "纪录片" ? "纪录片" : parent.group
        }
        if shortColumns.contains(category.name), categories.contains(where: { $0.name.contains("短剧") }) { return "短剧" }
        var current = category
        var visited = Set<String>()
        while visited.insert(current.id).inserted {
            if current.group != "其他" { return current.group }
            guard let parent = categories.first(where: { $0.id == current.parentID }) else { break }
            current = parent
        }
        return "其他"
    }
    static func group(_ item: FilmItem, in categories: [FilmCategory]) -> String {
        if item.genre.contains("短剧") { return "短剧" }
        if group(item.category) == "纪录片" { return "纪录片" }
        if let parent = categories.first(where: { $0.id == item.parentCategoryID }), parent.group != "其他" { return parent.group }
        if let category = categories.first(where: { $0.id == item.categoryID || $0.name == item.category }) { return group(category, in: categories) }
        return group(item.category)
    }
    static func regions(_ text: String) -> Set<String> {
        var values = Set<String>()
        if ["国产", "大陆", "内地", "中国大陆", "中国内地"].contains(where: text.contains) || text == "中国" || text.contains("China") { values.insert("国产") }
        if text.contains("香港") || text == "港剧" || text.contains("Hong Kong") { values.insert("中国香港") }
        if text.contains("台湾") || text == "台剧" || text.contains("Taiwan") { values.insert("中国台湾") }
        let aliases: [(String, [String])] = [("韩国",["韩国","韩剧","Korea"]),("日本",["日本","日剧","日漫","Japan"]),
          ("美国",["美国","美剧","USA","United States"]),("英国",["英国","英剧","UK","United Kingdom"]),("法国",["法国","France"]),
          ("德国",["德国","Germany"]),("泰国",["泰国","泰剧","Thailand"]),("印度",["印度","India"])]
        for (name, words) in aliases {
            if words.contains(where: { word in text.contains(word) && !(word == "美剧" && (text.contains("欧美") || text.contains("英美"))) }) { values.insert(name) }
        }
        if text.contains("港台") || !values.isDisjoint(with: ["中国香港","中国台湾"]) { values.insert("港台") }
        if text.contains("日韩") || !values.isDisjoint(with: ["韩国","日本"]) { values.insert("日韩") }
        if text.contains("欧美") || text.contains("英美") || !values.isDisjoint(with: ["美国","英国","法国","德国"]) { values.insert("欧美") }
        return values
    }
    static func regions(_ item: FilmItem) -> Set<String> {
        let metadata = item.area.trimmingCharacters(in: .whitespacesAndNewlines)
        return regions(metadata.isEmpty ? item.category : metadata)
    }
}

struct FilmFilter: Equatable {
    var group = "全部"
    var region = "全部地区"
    var genre = "全部题材"
    var year = "全部年份"
    var isEmpty: Bool { self == FilmFilter() }
    func matches(_ item: FilmItem, categories: [FilmCategory]) -> Bool {
        if group != "全部", FilmTaxonomy.group(item, in: categories) != group { return false }
        if region != "全部地区" {
            let areas = FilmTaxonomy.regions(item)
            if region == "其他地区" {
                guard !item.area.isEmpty, areas.isEmpty else { return false }
            } else if !areas.contains(region) { return false }
        }
        if genre != "全部题材", !(item.genre + " " + item.category).contains(genre) { return false }
        if year != "全部年份" {
            guard let value = Int(item.year) else { return false }
            if year == "更早" {
                guard value < Calendar.current.component(.year, from: Date()) - 14 else { return false }
            } else if item.year != year { return false }
        }
        return true
    }
    func candidateCategories(_ categories: [FilmCategory]) -> [String?] {
        if isEmpty || categories.isEmpty { return [nil] }
        let matching = categories.filter { category in
            if group != "全部", FilmTaxonomy.group(category, in: categories) != group { return false }
            let areas = FilmTaxonomy.regions(category.name)
            // Generic movie categories and broad regional buckets require exact item metadata filtering.
            if region != "全部地区", region != "其他地区", !areas.isEmpty, !areas.contains(region) {
                let broad = (areas.contains("欧美") && ["美国","英国","法国","德国"].contains(region))
                    || (areas.contains("日韩") && ["韩国","日本"].contains(region))
                    || (areas.contains("港台") && ["中国香港","中国台湾"].contains(region))
                if !broad { return false }
            }
            return true
        }
        let parents = Set(matching.map(\.parentID))
        let leaves = matching.filter { !parents.contains($0.id) }
        return leaves.map { Optional($0.id) }
    }
}
