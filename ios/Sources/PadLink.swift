import UIKit

protocol PadLinkDelegate: AnyObject {
    func linkStatusChanged()
    func linkReceived(_ message: [String: Any])
}

/// 노트북 프로그램(pc/server.js)과의 연결.
/// 실시간 메시지는 웹소켓으로, 필기 파일을 올리고 받는 것은 HTTP로 한다.
/// 모든 콜백은 메인 스레드에서 불린다.
final class PadLink: NSObject, URLSessionWebSocketDelegate {
    static let defaultPort = 8787
    static let statusChanged = Notification.Name("PadLinkStatusChanged")

    enum Status: Equatable {
        case off
        case connecting
        case connected
        /// 다시 시도해도 소용없는 거절. 이유: bad / none / locked / replaced
        case denied(String)
    }

    struct Found {
        let host: String
        let id: String
        let name: String
    }

    weak var delegate: PadLinkDelegate?

    private(set) var status: Status = .off {
        didSet {
            guard status != oldValue else { return }
            delegate?.linkStatusChanged()
            NotificationCenter.default.post(name: Self.statusChanged, object: self)
        }
    }

    private let defaults = UserDefaults.standard

    var host: String { defaults.string(forKey: "host") ?? "" }
    var code: String { defaults.string(forKey: "code") ?? "" }
    private(set) var serverName: String {
        get { defaults.string(forKey: "serverName") ?? "" }
        set { defaults.set(newValue, forKey: "serverName") }
    }
    private var serverId: String {
        get { defaults.string(forKey: "serverId") ?? "" }
        set { defaults.set(newValue, forKey: "serverId") }
    }

    private lazy var socketSession = URLSession(configuration: .default, delegate: self, delegateQueue: .main)
    private let http: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 20
        config.waitsForConnectivity = false
        return URLSession(configuration: config)
    }()

    private var task: URLSessionWebSocketTask?
    private var wanted = false
    private var failures = 0
    private var lastAlive = Date()
    private var retryTimer: Timer?
    private var connectTimer: Timer?
    private var pingTimer: Timer?
    private var scanning = false

    // MARK: 설정

    func configure(host: String, code: String) {
        var h = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        for prefix in ["http://", "https://", "ws://"] where h.hasPrefix(prefix) {
            h.removeFirst(prefix.count)
        }
        if let slash = h.firstIndex(of: "/") { h = String(h[..<slash]) }
        if h != self.host {
            serverId = ""
            serverName = ""
        }
        defaults.set(h, forKey: "host")
        defaults.set(code.filter { "0123456789".contains($0) }, forKey: "code")
    }

    private var endpoint: (host: String, port: Int)? {
        let h = host
        guard !h.isEmpty else { return nil }
        let parts = h.split(separator: ":")
        if parts.count == 2, let port = Int(parts[1]) { return (String(parts[0]), port) }
        return (h, Self.defaultPort)
    }

    // MARK: 연결

    /// 연결을 (다시) 시작한다. 끊기면 알아서 다시 붙는다.
    func start() {
        wanted = true
        failures = 0
        open()
    }

    /// 앱이 다시 앞으로 왔을 때: 끊겨 있으면 다시 연결하고, 붙어 있으면 살아 있는지 확인한다.
    func wake() {
        guard !host.isEmpty else { return }
        switch status {
        case .denied:
            break
        case .connected:
            ping()
        case .off, .connecting:
            start()
        }
    }

    private func open() {
        closeTask()
        guard wanted, let e = endpoint else {
            status = .off
            return
        }
        var parts = URLComponents()
        parts.scheme = "ws"
        parts.host = e.host
        parts.port = e.port
        parts.path = "/ws"
        parts.queryItems = [
            URLQueryItem(name: "role", value: "pad"),
            URLQueryItem(name: "code", value: code),
            URLQueryItem(name: "name", value: UIDevice.current.name),
        ]
        guard let url = parts.url else {
            status = .off
            return
        }

        status = .connecting
        let t = socketSession.webSocketTask(with: url)
        t.maximumMessageSize = 4 * 1024 * 1024
        task = t
        t.resume()
        listen(t)
        // 없는 주소로 붙으려 하면 오래 기다리게 되므로 5초 안에 안 열리면 끊고 다시 시도한다.
        connectTimer = after(5) { [weak self] in
            guard let self = self, self.task === t, self.status == .connecting else { return }
            self.dropped()
        }
    }

    private func closeTask() {
        retryTimer?.invalidate()
        connectTimer?.invalidate()
        pingTimer?.invalidate()
        retryTimer = nil
        connectTimer = nil
        pingTimer = nil
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
    }

    private func listen(_ t: URLSessionWebSocketTask) {
        t.receive { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self, self.task === t else { return }
                switch result {
                case .failure:
                    self.dropped()
                case .success(let message):
                    self.lastAlive = Date()
                    if case .string(let text) = message,
                       let data = text.data(using: .utf8),
                       let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
                        self.received(object)
                    }
                    if self.task === t { self.listen(t) }
                }
            }
        }
    }

    private func received(_ message: [String: Any]) {
        if message["t"] as? String == "denied" {
            wanted = false
            closeTask()
            status = .denied(message["reason"] as? String ?? "bad")
            return
        }
        delegate?.linkReceived(message)
    }

    private func dropped() {
        guard task != nil else { return }
        closeTask()
        guard wanted else {
            status = .off
            return
        }
        status = .connecting
        failures += 1
        // 계속 안 붙으면 노트북의 주소가 바뀌었을 수 있으니 같은 Wi-Fi에서 다시 찾아본다.
        if failures % 4 == 3 { rediscover() }
        retryTimer = after(failures <= 2 ? 1 : 3) { [weak self] in self?.open() }
    }

    private func ping() {
        guard let t = task else { return }
        if Date().timeIntervalSince(lastAlive) > 25 {
            dropped()
            return
        }
        t.sendPing { [weak self] error in
            DispatchQueue.main.async {
                guard let self = self, self.task === t else { return }
                if error == nil {
                    self.lastAlive = Date()
                } else {
                    self.dropped()
                }
            }
        }
    }

    private func learnServer() {
        request("GET", "/ping") { [weak self] data, _ in
            guard let self = self, let data = data,
                  let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return }
            self.serverId = object["id"] as? String ?? ""
            let name = object["name"] as? String ?? ""
            if name != self.serverName {
                self.serverName = name
                self.delegate?.linkStatusChanged()
            }
        }
    }

    // MARK: URLSessionWebSocketDelegate

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol proto: String?) {
        guard webSocketTask === task else { return }
        connectTimer?.invalidate()
        connectTimer = nil
        failures = 0
        lastAlive = Date()
        status = .connected
        pingTimer?.invalidate()
        let timer = Timer(timeInterval: 8, repeats: true) { [weak self] _ in self?.ping() }
        RunLoop.main.add(timer, forMode: .common)
        pingTimer = timer
        learnServer()
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        guard webSocketTask === task else { return }
        dropped()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard task === self.task else { return }
        dropped()
    }

    // MARK: 보내기

    func send(_ object: [String: Any]) {
        guard status == .connected, let t = task,
              JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object),
              let text = String(data: data, encoding: .utf8) else { return }
        t.send(.string(text)) { _ in }
    }

    /// path는 "/api/..." 형태. 응답이 없으면 (nil, nil)을 돌려준다.
    func request(_ method: String, _ path: String, body: Data? = nil, completion: @escaping (Data?, HTTPURLResponse?) -> Void) {
        guard let e = endpoint, let url = URL(string: "http://\(e.host):\(e.port)\(path)") else {
            DispatchQueue.main.async { completion(nil, nil) }
            return
        }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.cachePolicy = .reloadIgnoringLocalCacheData
        req.setValue(code, forHTTPHeaderField: "X-Code")
        let done: (Data?, URLResponse?, Error?) -> Void = { data, response, _ in
            DispatchQueue.main.async { completion(data, response as? HTTPURLResponse) }
        }
        let job: URLSessionTask
        if let body = body {
            req.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
            job = http.uploadTask(with: req, from: body, completionHandler: done)
        } else {
            job = http.dataTask(with: req, completionHandler: done)
        }
        job.resume()
    }

    // MARK: 같은 Wi-Fi에서 노트북 찾기

    /// 아이패드와 같은 대역(x.x.x.1~254)에 펜슬노트가 켜져 있는지 하나씩 물어본다.
    func scan(completion: @escaping ([Found]) -> Void) {
        guard let ip = Self.wifiAddress() else {
            DispatchQueue.main.async { completion([]) }
            return
        }
        let numbers = ip.split(separator: ".")
        guard numbers.count == 4 else {
            DispatchQueue.main.async { completion([]) }
            return
        }
        let prefix = numbers[0..<3].joined(separator: ".")
        let port = endpoint?.port ?? Self.defaultPort

        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 2
        config.timeoutIntervalForResource = 3
        config.waitsForConnectivity = false
        let session = URLSession(configuration: config)

        let group = DispatchGroup()
        let results = ScanResults()
        for n in 1...254 {
            let host = "\(prefix).\(n)"
            guard let url = URL(string: "http://\(host):\(port)/ping") else { continue }
            group.enter()
            session.dataTask(with: url) { data, _, _ in
                if let data = data,
                   let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                   object["app"] as? String == "pencilnote" {
                    results.add(Found(host: port == PadLink.defaultPort ? host : "\(host):\(port)",
                                      id: object["id"] as? String ?? "",
                                      name: object["name"] as? String ?? host))
                }
                group.leave()
            }.resume()
        }
        group.notify(queue: .main) {
            session.invalidateAndCancel()
            completion(results.all())
        }
    }

    /// 여러 응답이 동시에 들어와도 안전하게 모으는 통
    private final class ScanResults {
        private let lock = NSLock()
        private var items: [Found] = []

        func add(_ item: Found) {
            lock.lock()
            items.append(item)
            lock.unlock()
        }

        func all() -> [Found] {
            lock.lock()
            defer { lock.unlock() }
            return items
        }
    }

    private func rediscover() {
        guard !scanning, !serverId.isEmpty else { return }
        scanning = true
        scan { [weak self] found in
            guard let self = self else { return }
            self.scanning = false
            guard self.status != .connected,
                  let hit = found.first(where: { $0.id == self.serverId }),
                  hit.host != self.host else { return }
            self.defaults.set(hit.host, forKey: "host")
            self.failures = 0
            if self.wanted { self.open() }
        }
    }

    /// 아이패드의 Wi-Fi IPv4 주소
    static func wifiAddress() -> String? {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return nil }
        defer { freeifaddrs(list) }

        var result: String?
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let item = cursor {
            cursor = item.pointee.ifa_next
            guard let address = item.pointee.ifa_addr,
                  address.pointee.sa_family == UInt8(AF_INET),
                  let rawName = item.pointee.ifa_name else { continue }
            let name = String(cString: rawName)
            guard name.hasPrefix("en") else { continue }

            var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let ok = getnameinfo(address, socklen_t(address.pointee.sa_len), &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST) == 0
            guard ok else { continue }
            let ip = buffer.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
            if ip.hasPrefix("169.254.") { continue }
            if result == nil || name == "en0" { result = ip }
        }
        return result
    }
}
