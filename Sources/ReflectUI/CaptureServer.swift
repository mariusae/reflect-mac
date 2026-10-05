import AppKit
import Network
import ReflectCore

/// Where the browser extension sends what it captures: a small HTTP server
/// on this Mac alone — `127.0.0.1`, never the network — for as long as the
/// app runs.
///
/// Web pages are not answered: a browser always says which page a request
/// comes from, and only an extension's origin — or none, as an extension's
/// requests to a host it may reach often have — is let in. And only a
/// browser the person allowed captures: the first time, the extension asks
/// to pair, and the app asks the person; allowed, the browser gets a token
/// to send with each capture after.
///
///     GET  /ping      the app, and the graph it writes to
///     POST /pair      {"browser"} → {"token"}, once allowed
///     POST /capture   {"url", "title", "description", "highlights", "screenshot"} → {"path", "title"}
///     POST /open      {"path"}: the note shown, and the app brought forward
@MainActor
package final class CaptureServer {
    private static let maxBody = 40 * 1024 * 1024

    /// The app's name, as the extension and the person are told it.
    private let app: String
    /// Where it listens — each app its own, a scripted run beside it.
    package let port: UInt16
    private let tokensKey: String
    private let isScripted: Bool

    /// `port`, and the key the browsers allowed are kept under: a scripted
    /// run's apart from the app in use.
    package init(app: String, port: UInt16, tokensKey: String, isScripted: Bool) {
        self.app = app
        self.port = port
        self.tokensKey = tokensKey
        self.isScripted = isScripted
    }

    /// Saves a capture, and says where; set by the window.
    package var onCapture: ((WebCapture.Page, _ screenshot: Data?) throws -> (path: String, title: String))?
    /// Shows a note, bringing the app forward.
    package var onOpen: ((String) -> Void)?
    /// The graph's name, for the extension to show.
    package var graphName: () -> String = { "" }

    private var listener: NWListener?

    package func start() {
        guard listener == nil else { return }
        do {
            let parameters = NWParameters.tcp
            parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!)
            parameters.allowLocalEndpointReuse = true
            let listener = try NWListener(using: parameters)
            listener.newConnectionHandler = { [weak self] connection in
                MainActor.assumeIsolated { self?.accept(connection) }
            }
            listener.stateUpdateHandler = { state in
                if case .failed(let error) = state {
                    Log.shared.warning("capture", "The capture server stopped", detail: error.localizedDescription)
                }
            }
            listener.start(queue: .main)
            self.listener = listener
            Log.shared.info("capture", "Listening for the browser extension on 127.0.0.1:\(port)")
        } catch {
            Log.shared.warning("capture", "The capture server could not start", detail: error.localizedDescription)
        }
    }

    // MARK: Requests

    private struct Request {
        var method: String
        var path: String
        var headers: [String: String]
        var body: Data
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: .main)
        receive(connection, buffer: Data())
    }

    /// Reads until the headers, and as much body as they say, have come.
    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, complete, error in
            MainActor.assumeIsolated {
                guard let self else { return }
                var buffer = buffer
                if let data { buffer.append(data) }
                if let request = Self.parse(buffer) {
                    self.handle(request, on: connection)
                } else if error != nil || complete || buffer.count > Self.maxBody {
                    connection.cancel()
                } else {
                    self.receive(connection, buffer: buffer)
                }
            }
        }
    }

    /// A whole request from what has come, or nil while more is to come.
    private static func parse(_ data: Data) -> Request? {
        guard let end = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let head = String(decoding: data[..<end.lowerBound], as: UTF8.self).components(separatedBy: "\r\n")
        let first = head.first?.split(separator: " ") ?? []
        guard first.count >= 2 else { return nil }
        var headers: [String: String] = [:]
        for line in head.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let length = Int(headers["content-length"] ?? "0") ?? 0
        let body = data[end.upperBound...]
        guard body.count >= length else { return nil }
        return Request(method: String(first[0]), path: String(first[1]), headers: headers, body: Data(body.prefix(length)))
    }

    /// Whether a request may be answered: not from a page on the web, which
    /// always has an origin of its own. An extension's has its own kind, or,
    /// to a host it has permission for, often none at all.
    private static func mayAnswer(_ origin: String?) -> Bool {
        guard let origin else { return true }
        return ["chrome-extension://", "safari-web-extension://", "moz-extension://"].contains { origin.hasPrefix($0) }
    }

    private func handle(_ request: Request, on connection: NWConnection) {
        let origin = request.headers["origin"]
        guard Self.mayAnswer(origin) else {
            respond(connection, status: 403, json: ["error": "Only the \(app) browser extension may capture."], origin: nil)
            return
        }
        if request.method == "OPTIONS" {
            respond(connection, status: 204, json: nil, origin: origin)
            return
        }
        let body = (try? JSONSerialization.jsonObject(with: request.body)) as? [String: Any] ?? [:]
        switch (request.method, request.path) {
        case ("GET", "/ping"):
            // Which graph, only to a browser allowed to write to it.
            let paired = isAllowed(request)
            respond(connection, status: 200, json: (["app": app, "paired": paired] as [String: Any]).merging(paired ? ["graph": graphName()] : [:]) { $1 }, origin: origin)
        case ("POST", "/pair"):
            let browser = (body["browser"] as? String).map { String($0.prefix(40)) } ?? "A browser"
            pair(browser) { token in
                if let token {
                    self.respond(connection, status: 200, json: ["token": token], origin: origin)
                } else {
                    self.respond(connection, status: 403, json: ["error": "Not allowed."], origin: origin)
                }
            }
        case ("POST", "/capture"):
            guard isAllowed(request) else {
                respond(connection, status: 401, json: ["error": "Pair with \(app) first."], origin: origin)
                return
            }
            capture(body, connection: connection, origin: origin)
        case ("POST", "/open"):
            guard isAllowed(request), let path = body["path"] as? String else {
                respond(connection, status: 401, json: ["error": "Pair with \(app) first."], origin: origin)
                return
            }
            onOpen?(path)
            respond(connection, status: 200, json: ["ok": true], origin: origin)
        default:
            respond(connection, status: 404, json: ["error": "No such thing."], origin: origin)
        }
    }

    private func capture(_ body: [String: Any], connection: NWConnection, origin: String?) {
        guard let url = body["url"] as? String, !url.isEmpty else {
            respond(connection, status: 400, json: ["error": "Nothing to capture."], origin: origin)
            return
        }
        let page = WebCapture.Page(url: url, title: body["title"] as? String ?? "",
                                   description: body["description"] as? String ?? "",
                                   highlights: body["highlights"] as? [String] ?? [])
        // A data URL: `data:image/png;base64,…`.
        let screenshot = (body["screenshot"] as? String).flatMap { dataURL -> Data? in
            guard let comma = dataURL.firstIndex(of: ",") else { return nil }
            return Data(base64Encoded: String(dataURL[dataURL.index(after: comma)...]))
        }
        do {
            guard let saved = try onCapture?(page, screenshot) else { throw CocoaError(.fileWriteUnknown) }
            Log.shared.info("capture", "Captured “\(saved.title)”", detail: url)
            respond(connection, status: 200, json: ["path": saved.path, "title": saved.title], origin: origin)
        } catch {
            Log.shared.error("capture", "Could not capture \(url)", detail: error.localizedDescription)
            respond(connection, status: 500, json: ["error": error.localizedDescription], origin: origin)
        }
    }

    private func respond(_ connection: NWConnection, status: Int, json: [String: Any]?, origin: String?) {
        let body = json.flatMap { try? JSONSerialization.data(withJSONObject: $0) } ?? Data()
        let reason = [200: "OK", 204: "No Content", 400: "Bad Request", 401: "Unauthorized", 403: "Forbidden",
                      404: "Not Found", 500: "Internal Server Error"][status] ?? "OK"
        var head = "HTTP/1.1 \(status) \(reason)\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\n"
        if let origin {
            head += "Access-Control-Allow-Origin: \(origin)\r\nAccess-Control-Allow-Methods: GET, POST, OPTIONS\r\n"
                + "Access-Control-Allow-Headers: Content-Type, Authorization\r\nAccess-Control-Allow-Private-Network: true\r\n"
        }
        connection.send(content: Data((head + "\r\n").utf8) + body, completion: .contentProcessed { _ in connection.cancel() })
    }

    // MARK: Pairing

    private var tokens: [String: String] {
        get { UserDefaults.standard.dictionary(forKey: tokensKey) as? [String: String] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: tokensKey) }
    }

    private func isAllowed(_ request: Request) -> Bool {
        guard let header = request.headers["authorization"], header.hasPrefix("Bearer ") else { return false }
        return tokens[String(header.dropFirst("Bearer ".count))] != nil
    }

    /// Asks the person whether a browser may capture into their notes.
    private func pair(_ browser: String, done: @escaping (String?) -> Void) {
        // A script has no one to ask.
        if isScripted {
            let token = UUID().uuidString
            tokens[token] = browser
            done(token)
            return
        }
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = "Allow \(browser) to save pages into \(app)?"
        alert.informativeText = "The \(app) extension in \(browser) will be able to add web pages, their highlights and screenshots to “\(graphName())”."
        alert.addButton(withTitle: "Allow")
        alert.addButton(withTitle: "Don’t Allow")
        guard alert.runModal() == .alertFirstButtonReturn else {
            done(nil)
            return
        }
        let token = UUID().uuidString + "-" + UUID().uuidString
        tokens[token] = browser
        Log.shared.info("capture", "\(browser) may now capture pages")
        done(token)
    }

    /// Takes every browser's permission away. For the Settings.
    package func forgetBrowsers() { tokens = [:] }
}
