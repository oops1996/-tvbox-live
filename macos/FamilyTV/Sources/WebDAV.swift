import Foundation

struct DAVItem: Identifiable, Hashable {
    let id = UUID()
    let name: String
    let href: String
    let isDirectory: Bool
}

final class DAVParser: NSObject, XMLParserDelegate {
    var items: [DAVItem] = []
    private var currentElement = ""
    private var href = ""
    private var displayName = ""
    private var isCollection = false
    private var inResponse = false

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String : String] = [:]) {
        currentElement = elementName.lowercased()
        if currentElement.hasSuffix("response") {
            inResponse = true
            href = ""
            displayName = ""
            isCollection = false
        }
        if currentElement.hasSuffix("collection") { isCollection = true }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard inResponse else { return }
        if currentElement.hasSuffix("href") { href += string }
        if currentElement.hasSuffix("displayname") { displayName += string }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        let e = elementName.lowercased()
        if e.hasSuffix("response") {
            let decoded = href.removingPercentEncoding ?? href
            var name = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
            if name.isEmpty {
                name = decoded.split(separator: "/").last.map(String.init) ?? decoded
            }
            if !href.isEmpty {
                items.append(DAVItem(name: name, href: href.trimmingCharacters(in: .whitespacesAndNewlines), isDirectory: isCollection))
            }
            inResponse = false
        }
        currentElement = ""
    }
}

struct WebDAVClient {
    let baseURL: String
    let username: String
    let password: String

    var authHeader: [String: String] {
        guard !username.isEmpty else { return [:] }
        let token = Data("\(username):\(password)".utf8).base64EncodedString()
        return ["Authorization": "Basic \(token)"]
    }

    func list(path: String) async throws -> [DAVItem] {
        let root = baseURL.hasSuffix("/") ? baseURL : baseURL + "/"
        let rel = path.hasPrefix("/") ? String(path.dropFirst()) : path
        guard let url = URL(string: root + rel) else { return [] }

        var request = URLRequest(url: url)
        request.httpMethod = "PROPFIND"
        request.setValue("1", forHTTPHeaderField: "Depth")
        request.setValue("application/xml", forHTTPHeaderField: "Content-Type")
        for (k, v) in authHeader { request.setValue(v, forHTTPHeaderField: k) }
        request.httpBody = """
        <?xml version="1.0" encoding="utf-8" ?>
        <d:propfind xmlns:d="DAV:">
          <d:prop><d:displayname/><d:resourcetype/></d:prop>
        </d:propfind>
        """.data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) || http.statusCode == 207 else {
            throw URLError(.userAuthenticationRequired)
        }
        let parser = XMLParser(data: data)
        let delegate = DAVParser()
        parser.delegate = delegate
        parser.parse()

        let all = delegate.items
        if all.count <= 1 { return all }
        return Array(all.dropFirst())
    }

    func absoluteURL(for href: String) -> String {
        if href.hasPrefix("http://") || href.hasPrefix("https://") { return href }
        guard let base = URL(string: baseURL) else { return href }
        if href.hasPrefix("/") {
            var c = URLComponents(url: base, resolvingAgainstBaseURL: false)
            c?.path = href
            return c?.url?.absoluteString ?? href
        }
        return base.appendingPathComponent(href).absoluteString
    }
}
