import UIKit
import CryptoKit

protocol PadLinkDelegate: AnyObject {
    func linkStatusChanged()
    func linkReceived(_ message: [String: Any])
}

/// 노트북 프로그램(pc/server.js)과의 연결.
/// 실시간 메시지는 웹소켓으로, 필기 파일을 올리고 받는 것은 HTTP로 한다. 둘 다 TLS로 암호화된다.
///
/// 공용 Wi-Fi에서도 안전하도록:
/// - 처음 등록할 때(연결 코드 입력) 노트북 인증서의 지문을 기억해 두고, 그 뒤로는 지문이 같은 서버에만 붙는다.
/// - 등록하면 노트북이 이 기기 전용 비밀키를 준다. 그 뒤로는 연결 코드 대신 비밀키로 인증한다.
///
/// 모든 콜백은 메인 스레드에서 불린다.
final class PadLink: NSObject, URLSessionWebSocketDelegate {
    static let defaultPort = 8788
    static let statusChanged = Notification.Name("PadLinkStatusChanged")

    enum Status: Equatable {
        case off
        case connecting
        case connected
        /// 다시 시도해도 소용없는 거절. 이유: token / replaced
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

    /// 붙으려는 서버의 인증서가 기억해 둔 것과 달랐다. (주소가 바뀌었거나, 누군가 노트북인 척하고 있다)
    private(set) var certProblem = false

    private let defaults = UserDefaults.standard

    private(set) var host: String {
        get { defaults.string(forKey: "host") ?? "" }
        set { defaults.set(newValue, forKey: "host") }
    }
    private(set) var serverName: String {
        get { defaults.string(forKey: "serverName") ?? "" }
        set { defaults.set(newValue, forKey: "serverName") }
    }
    private var serverId: String {
        get { defaults.string(forKey: "serverId") ?? "" }
        set { defaults.set(newValue, forKey: "serverId") }
    }
    private var token: String {
        get { defaults.string(forKey: "token") ?? "" }
        set { defaults.set(newValue, forKey: "token") }
    }
    private var pin: String {
        get { defaults.string(forKey: "pin") ?? "" }
        set { defaults.set(newValue, forKey: "pin") }
    }

    /// 노트북에 등록되어 있는지
    var isPaired: Bool { !host.isEmpty && !token.isEmpty && !pin.isEmpty }

    private lazy var socketSession = URLSession(configuration: .default, delegate: self, delegateQueue: .main)
    private lazy var http: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 20
        config.waitsForConnectivity = false
        return URLSession(configuration: config, delegate: self, delegateQueue: .main)
    }()

    private var task: URLSessionWebSocketTask?
    private var wanted = false
    private var failures = 0
    private var lastAlive = Date()
    private var retryTimer: Timer?
    private var connectTimer: Timer?
    private var pingTimer: Timer?
    private var scanning = false

    // MARK: 주소

    static func cleanHost(_ text: String) -> String {
        var h = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        for prefix in ["https://", "http://", "wss://", "ws://"] where h.hasPrefix(prefix) {
            h.removeFirst(prefix.count)
        }
        if let slash = h.firstIndex(of: "/") { h = String(h[..<slash]) }
        return h
    }

    private static func endpoint(_ host: String) -> (host: String, port: Int)? {
        guard !host.isEmpty else { return nil }
        let parts = host.split(separator: ":")
        if parts.count == 2, let port = Int(parts[1]) { return (String(parts[0]), port) }
        return (host, defaultPort)
    }

    // MARK: 등록

    /// 연결 코드로 노트북에 등록한다. 성공하면 nil, 실패하면 이유(bad / none / locked / unreachable)를 돌려준다.
    func pair(host rawHost: String, code: String, completion: @escaping (String?) -> Void) {
        let newHost = Self.cleanHost(rawHost)
        guard let e = Self.endpoint(newHost), let url = URL(string: "https://\(e.host):\(e.port)/api/pair") else {
            DispatchQueue.main.async { completion("unreachable") }
            return
        }
        // 등록할 때만 처음 보는 인증서를 받아들이고, 그 지문을 기억한다.
        let watcher = CertWatcher()
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 8
        config.waitsForConnectivity = false
        let session = URLSession(configuration: config, delegate: watcher, delegateQueue: .main)

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue(code, forHTTPHeaderField: "X-Code")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["name": UIDevice.current.name])

        session.dataTask(with: req) { [weak self] data, response, _ in
            session.finishTasksAndInvalidate()
            guard let self = self else { return }
            let object = data.flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] } ?? [:]
            guard let http = response as? HTTPURLResponse else {
                completion("unreachable")
                return
            }
            guard http.statusCode == 200, let token = object["token"] as? String, let seen = watcher.fingerprint else {
                completion(object["error"] as? String ?? "unreachable")
                return
            }
            self.host = newHost
            self.token = token
            self.pin = seen
            self.serverId = object["id"] as? String ?? ""
            self.serverName = object["name"] as? String ?? ""
            self.certProblem = false
            completion(nil)
        }.resume()
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
        guard isPaired else { return }
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
        guard wanted, isPaired, let e = Self.endpoint(host) else {
            status = .off
            return
        }
        var parts = URLComponents()
        parts.scheme = "wss"
        parts.host = e.host
        parts.port = e.port
        parts.path = "/ws"
        parts.queryItems = [
            URLQueryItem(name: "role", value: "pad"),
            URLQueryItem(name: "token", value: token),
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
            status = .denied(message["reason"] as? String ?? "token")
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

    // MARK: URLSession 대리자

    /// 서버가 내미는 인증서가 등록할 때 기억한 것과 같은지 확인한다. 다르면 연결하지 않는다.
    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        let expected = pin
        if !expected.isEmpty, CertWatcher.fingerprint(of: trust) == expected {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            if !certProblem {
                certProblem = true
                delegate?.linkStatusChanged()
            }
        }
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol proto: String?) {
        guard webSocketTask === task else { return }
        connectTimer?.invalidate()
        connectTimer = nil
        failures = 0
        lastAlive = Date()
        certProblem = false
        status = .connected
        pingTimer?.invalidate()
        let timer = Timer(timeInterval: 8, repeats: true) { [weak self] _ in self?.ping() }
        RunLoop.main.add(timer, forMode: .common)
        pingTimer = timer
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
        guard let e = Self.endpoint(host), let url = URL(string: "https://\(e.host):\(e.port)\(path)") else {
            DispatchQueue.main.async { completion(nil, nil) }
            return
        }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.cachePolicy = .reloadIgnoringLocalCacheData
        req.setValue(token, forHTTPHeaderField: "X-Token")
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
    /// 여기서는 이름만 묻기 때문에 인증서를 가리지 않는다. 진짜인지는 연결할 때 지문으로 확인한다.
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
        let port = Self.endpoint(host)?.port ?? Self.defaultPort

        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 2.5
        config.timeoutIntervalForResource = 4
        config.waitsForConnectivity = false
        let session = URLSession(configuration: config, delegate: CertWatcher(), delegateQueue: nil)

        let group = DispatchGroup()
        let results = ScanResults()
        for n in 1...254 {
            let host = "\(prefix).\(n)"
            guard let url = URL(string: "https://\(host):\(port)/ping") else { continue }
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
            self.host = hit.host
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

/// 어떤 인증서든 받아들이되 그 지문을 적어 두는 대리자. 등록할 때와 노트북을 찾을 때만 쓴다.
final class CertWatcher: NSObject, URLSessionDelegate {
    private let lock = NSLock()
    private var seen: String?

    var fingerprint: String? {
        lock.lock()
        defer { lock.unlock() }
        return seen
    }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        let value = Self.fingerprint(of: trust)
        lock.lock()
        seen = value
        lock.unlock()
        completionHandler(.useCredential, URLCredential(trust: trust))
    }

    /// 서버 인증서의 SHA-256 지문 (소문자 16진수)
    static func fingerprint(of trust: SecTrust) -> String? {
        guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate], let leaf = chain.first else { return nil }
        let der = SecCertificateCopyData(leaf) as Data
        return SHA256.hash(data: der).map { String(format: "%02x", $0) }.joined()
    }
}
