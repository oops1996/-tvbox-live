import Foundation
import Combine

struct FilmRank: Identifiable, Equatable {
    var id: Int { rank }
    let rank: Int
    let name: String
    let heat: String
    let metadata: String
}
struct FilmRankingSnapshot {
    let items: [FilmRank]
    let updated: Date
    let fetched: Date
    let url: URL
}
enum RankingError: LocalizedError {
    case unavailable, outdated
    var errorDescription: String? {
        switch self {
        case .unavailable: return "榜单暂时无法读取，可刷新重试或打开官方榜单。"
        case .outdated: return "官方榜单返回的更新时间过早，暂不作为当前热度展示。"
        }
    }
}

/// Reads public server-rendered ranking rows as data; never evaluates website scripts.
enum FilmRankingClient {
    static let channels = ["总榜": "-1", "电视剧": "2", "电影": "1", "综艺": "6", "动漫": "4", "短剧": "35"]
    static func url(_ group: String) -> URL { URL(string: "https://www.iqiyi.com/ranks1/\(channels[group] ?? "2")/0")! }
    static func fetch(_ group: String) async throws -> FilmRankingSnapshot {
        let endpoint = url(group)
        var request = URLRequest(url: endpoint, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200, data.count < 3_000_000,
              let html = String(data: data, encoding: .utf8) else { throw RankingError.unavailable }
        return try parse(html, url: endpoint)
    }
    static func captures(_ pattern: String, _ text: String) -> [[String]] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else { return [] }
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).map { match in
            (1..<match.numberOfRanges).map { index in Range(match.range(at: index), in: text).map { String(text[$0]) } ?? "" }
        }
    }
    static func decode(_ text: String) -> String {
        var result = text
        for (entity, value) in [("&amp;","&"),("&quot;","\""),("&#39;","'"),("&lt;","<"),("&gt;",">"),("&nbsp;"," ")] { result = result.replacingOccurrences(of: entity, with: value) }
        for match in captures("&#(x[0-9a-fA-F]+|[0-9]+);", result) {
            let value = match[0]
            if let code = UInt32(value.hasPrefix("x") ? String(value.dropFirst()) : value, radix: value.hasPrefix("x") ? 16 : 10), let scalar = UnicodeScalar(code) {
                result = result.replacingOccurrences(of: "&#\(value);", with: String(scalar))
            }
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    static func parse(_ html: String, url: URL, now: Date = Date()) throws -> FilmRankingSnapshot {
        guard let stamp = captures("最近更新([0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2})", html).first?.first else { throw RankingError.unavailable }
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = calendar.timeZone; formatter.dateFormat = "yyyy-MM-dd HH:mm"; formatter.isLenient = false
        let year = calendar.component(.year, from: now)
        guard var updated = formatter.date(from: "\(year)-\(stamp)") else { throw RankingError.unavailable }
        if updated.timeIntervalSince(now) > 86400 { updated = calendar.date(byAdding: .year, value: -1, to: updated)! }
        guard now.timeIntervalSince(updated) < 48 * 3600, updated.timeIntervalSince(now) < 900 else { throw RankingError.outdated }
        var items: [FilmRank] = []; var seen = Set<Int>()
        for row in captures("<a\\b[^>]*class=\"[^\"]*\\brvi__box\\b[^\"]*\"[^>]*>(.*?)</a>", html) {
            let block = row[0]
            guard block.contains("实时热度"), let name = captures("<div\\b[^>]*title=\"([^\"]+)\"[^>]*class=\"rvi__tit1\"", block).first?.first,
                  let rankText = captures("class=\"rvi__No__txt\"[^>]*>([0-9]+)</span>", block).first?.first, let rank = Int(rankText),
                  let heat = captures("class=\"rvi__index__num\"[^>]*>([0-9]+)</span>", block).first?.first, seen.insert(rank).inserted else { continue }
            let metadata = captures("<div\\b[^>]*title=\"([^\"]*)\"[^>]*class=\"rvi__type1\"", block).first?.first ?? ""
            items.append(FilmRank(rank: rank, name: decode(name), heat: heat, metadata: decode(metadata)))
        }
        guard !items.isEmpty else { throw RankingError.unavailable }
        return FilmRankingSnapshot(items: items.sorted { $0.rank < $1.rank }, updated: updated, fetched: now, url: url)
    }
}

@MainActor final class FilmRankingLibrary: ObservableObject {
    @Published private(set) var snapshot: FilmRankingSnapshot?
    @Published private(set) var busy = false
    @Published private(set) var error = ""
    private var token = UUID()
    func refresh(_ group: String) async {
        let current = UUID(); token = current; busy = true; error = ""; snapshot = nil
        defer { if token == current { busy = false } }
        do {
            let value = try await FilmRankingClient.fetch(group)
            guard token == current else { return }
            snapshot = value
        } catch { if token == current { self.error = error.localizedDescription } }
    }
}
