import Cocoa
import ImageIO

final class StubProtocol: URLProtocol {
    struct Reply { var status: Int; var headers: [String: String] = [:]; var body = Data(); var delay: TimeInterval = 0 }
    static let lock = NSLock()
    static var requests: [URLRequest] = []
    static var handlers: [String: (URLRequest) -> Reply] = [:]
    static var currentHost = ""
    private var stopped = false
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock()
        Self.requests.append(request)
        let reply = Self.handlers[request.url!.host!]!(request)
        Self.lock.unlock()
        let send = { [self] in
            Self.lock.lock(); let cancelled = stopped; Self.lock.unlock()
            if cancelled { return }
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: reply.headers)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: reply.body)
            client?.urlProtocolDidFinishLoading(self)
        }
        if reply.delay > 0 { DispatchQueue.global().asyncAfter(deadline: .now() + reply.delay, execute: send) }
        else { send() }
    }
    override func stopLoading() { Self.lock.lock(); stopped = true; Self.lock.unlock() }
    static func snapshot() -> [URLRequest] { lock.lock(); defer { lock.unlock() }; return requests.filter { $0.url?.host == currentHost } }
}

func json(_ object: Any) -> Data { try! JSONSerialization.data(withJSONObject: object) }
func spin(_ seconds: TimeInterval) {
    let end = Date().addingTimeInterval(seconds)
    while Date() < end { _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.003)) }
}
func until(_ condition: () -> Bool) -> Bool {
    let end = Date().addingTimeInterval(3)
    while !condition() && Date() < end { spin(0.005) }
    return condition()
}
var failures = 0
func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() { failures += 1; print("FAIL: \(message)") }
}
func client(_ handler: @escaping (URLRequest) -> StubProtocol.Reply) -> RelayClient {
    let host = "test-" + UUID().uuidString.lowercased() + ".invalid"
    StubProtocol.lock.lock(); StubProtocol.requests = []; StubProtocol.currentHost = host; StubProtocol.handlers[host] = handler; StubProtocol.lock.unlock()
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [StubProtocol.self]
    return RelayClient(origin: "https://" + host, configuration: config, interval: 0.02)
}
let context = CGContext(data: nil, width: 32, height: 32, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
context.setFillColor(CGColor(red: 0.2, green: 0.6, blue: 0.4, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 32, height: 32))
let png = NSMutableData()
let destination = CGImageDestinationCreateWithData(png, "public.png" as CFString, 1, nil)!
CGImageDestinationAddImage(destination, context.makeImage()!, nil); CGImageDestinationFinalize(destination)
var metadata: [String: Any] = ["mime": "image/png", "size": png.length, "at": 100, "hostedStatus": "pending"]
var payload = metadata; payload["data"] = (png as Data).base64EncodedString()

do {
    let receiver = client { request in
        if request.httpMethod == "POST" { return .init(status: 201, body: json(["code": "123456"])) }
        if request.url!.query == "meta=1" {
            if request.value(forHTTPHeaderField: "If-None-Match") == "v1" { return .init(status: 304) }
            return .init(status: 200, headers: ["ETag": "v1"], body: json(["image": metadata]))
        }
        return .init(status: 200, body: json(["image": payload]))
    }
    var copies = 0
    receiver.onImage = { _, bytes in
        check(Thread.isMainThread, "clipboard callback must run on main thread")
        check(NSImage(data: bytes) != nil, "decoded clipboard PNG is readable")
        copies += 1; return true
    }
    receiver.start()
    check(until { copies == 1 && StubProtocol.snapshot().filter { $0.url!.query == "meta=1" }.count >= 5 }, "steady-state polling completes")
    receiver.stop()
    check(copies == 1, "unchanged image copied once")
    check(StubProtocol.snapshot().filter { $0.httpMethod != "POST" && $0.url!.query == nil }.count == 1, "unchanged image downloaded once")
    let count = StubProtocol.snapshot().count; spin(0.06)
    check(StubProtocol.snapshot().count == count, "stop cancels polling")
    print("PASS: download once, conditional metadata, clipboard PNG, stop")
}

do {
    var polls = 0
    let receiver = client { request in
        if request.httpMethod == "POST" { return .init(status: 201, body: json(["code": "123456"])) }
        if request.url!.query != nil {
            polls += 1
            var meta = metadata
            if polls > 1 { meta["hostedStatus"] = "completed"; meta["hostedUrl"] = "https://example.invalid/image.png" }
            return .init(status: 200, headers: ["ETag": "v\(polls)"], body: json(["image": meta]))
        }
        return .init(status: 200, body: json(["image": payload]))
    }
    var copies = 0; var completed = false
    receiver.onImage = { _, _ in copies += 1; return true }
    receiver.onMetadata = { completed = $0.hostedStatus == "completed" }
    receiver.start(); check(until { completed }, "archive metadata still updates")
    receiver.stop(); check(copies == 1, "archive update does not download/copy image again")
    print("PASS: archive metadata update without image download")
}

do {
    var downloads = 0
    let receiver = client { request in
        if request.httpMethod == "POST" { return .init(status: 201, body: json(["code": "123456"])) }
        if request.url!.query != nil { return .init(status: 200, headers: ["ETag": "v1"], body: json(["image": metadata])) }
        downloads += 1
        return downloads == 1 ? .init(status: 500) : .init(status: 200, body: json(["image": payload]))
    }
    var copies = 0
    receiver.onImage = { _, _ in copies += 1; return true }
    receiver.start(); check(until { copies == 1 }, "failed image download is retried")
    receiver.stop(); check(downloads == 2, "failed download is not marked received")
    print("PASS: failed image download retry")
}

do {
    let receiver = client { _ in .init(status: 503) }
    receiver.start(); check(until { receiver.nextDelay >= 0.08 }, "outage backs off exponentially")
    receiver.stop()
    check(StubProtocol.snapshot().count == 3, "outage uses bounded request rate")
    print("PASS: outage backoff")
}

do {
    var sessions = 0; var codes: [String] = []
    let receiver = client { request in
        if request.httpMethod == "POST" {
            sessions += 1
            return .init(status: 201, body: json(["code": sessions == 1 ? "111111" : "222222"]), delay: sessions == 1 ? 0.15 : 0)
        }
        return .init(status: 200, body: json(["image": NSNull()]))
    }
    receiver.onSession = { codes.append($0) }
    receiver.start(); spin(0.01); receiver.start()
    check(until { codes == ["222222"] }, "refresh creates new pairing")
    spin(0.2); receiver.stop()
    check(codes == ["222222"], "cancelled old response cannot overwrite refreshed pairing")
    print("PASS: refresh cancellation")
}

do {
    var sessions = 0; var polls = 0
    var deliveredCodes: [String] = []
    let receiver = client { request in
        if request.httpMethod == "POST" { sessions += 1; return .init(status: 201, body: json(["code": "123456"])) }
        polls += 1
        return polls == 1 ? .init(status: 404) : .init(status: 200, body: json(["image": NSNull()]))
    }
    receiver.onSession = { deliveredCodes.append($0) }
    receiver.start()
    let recovered = until { deliveredCodes.count == 2 && StubProtocol.snapshot().filter { $0.url!.query != nil }.count >= 2 }
    if !recovered { print("expiry diagnostic: codes=\(deliveredCodes), requests=\(StubProtocol.snapshot().map { $0.url!.absoluteString })") }
    check(recovered, "expired room recreates pairing")
    receiver.stop()
    print("PASS: room expiry recovery")
}

do {
    let receiver = client { request in
        if request.httpMethod == "POST" { return .init(status: 201, body: json(["code": "123456"])) }
        if request.url!.query != nil { return .init(status: 200, headers: ["ETag": "v1"], body: json(["image": metadata])) }
        return .init(status: 500)
    }
    receiver.onImage = { _, _ in false }
    receiver.start()
    check(until { receiver.nextDelay >= 0.08 }, "repeated full-image failure also backs off despite successful metadata")
    receiver.stop()
    check(StubProtocol.snapshot().filter { $0.httpMethod != "POST" && $0.url!.query == nil }.count == 3, "failed large payload requests remain bounded")
    print("PASS: persistent image failure backoff")
}

print("Receiver regression failures: \(failures)")
exit(failures == 0 ? 0 : 1)
