import Foundation

@main struct LiveTransportSmoke {
    enum Failure: Error { case check(String) }
    static func check(_ condition: @autoclosure () -> Bool, _ text: String) throws {
        if !condition() { throw Failure.check(text) }
    }
    static func main() async {
        do {
            let base = CommandLine.arguments[1]
            let relay = LiveNetworkProxy()
            let start = try await relay.mediaURL(for: URL(string: base + "/redirect")!)
            let config = URLSessionConfiguration.ephemeral
            config.connectionProxyDictionary = [:]
            config.timeoutIntervalForRequest = 10
            let session = URLSession(configuration: config)
            func get(_ url: URL, range: String? = nil) async throws -> (Data, HTTPURLResponse) {
                var request = URLRequest(url: url)
                request.setValue("relay-fixture-agent", forHTTPHeaderField: "User-Agent")
                request.setValue(base + "/", forHTTPHeaderField: "Referer")
                if let range { request.setValue(range, forHTTPHeaderField: "Range") }
                let (data, response) = try await session.data(for: request)
                return (data, response as! HTTPURLResponse)
            }
            let (master, response) = try await get(start)
            try check(response.statusCode == 200 && response.url?.host == "127.0.0.1", "Redirect escaped loopback")
            let text = String(data: master, encoding: .utf8)!
            let expression = try NSRegularExpression(pattern: "http://127\\.0\\.0\\.1:[0-9]+/direct/[^\\\"\\r\\n]+")
            let urls = expression.matches(in: text, range: NSRange(text.startIndex..., in: text)).map {
                URL(string: String(text[Range($0.range, in: text)!]))!
            }
            try check(urls.count == 3, "Master/key/map URIs were not all rewritten")
            let (key, _) = try await get(urls[0])
            let (map, mapResponse) = try await get(urls[1], range: "bytes=2-5")
            try check(key == Data("0123456789abcdef".utf8), "Key request lost headers/query")
            try check(map == Data("2345".utf8) && mapResponse.statusCode == 206 && mapResponse.value(forHTTPHeaderField: "Content-Range") == "bytes 2-5/10", "Byte range was not preserved")
            let (media, _) = try await get(urls[2])
            let child = String(data: media, encoding: .utf8)!.components(separatedBy: "\n").first { !$0.isEmpty && !$0.hasPrefix("#") }!
            let (segment, _) = try await get(URL(string: child)!)
            try check(segment == Data([0x47, 1, 2, 3]), "Chunked media playlist or TS streaming failed")
            let invalid = URL(string: start.absoluteString.replacingOccurrences(of: "/direct/", with: "/invalid/"))!
            let (_, denied) = try await get(invalid)
            try check(denied.statusCode == 400, "Invalid local transport token accepted")
            print("PASS: direct HLS redirect, master/key/map/segment URI rewriting, chunked playlist, headers, ranges and loopback token")
        } catch { print("FAIL: \(error)"); exit(1) }
    }
}
