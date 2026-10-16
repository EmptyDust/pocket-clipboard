import Foundation
import ImageIO

struct RelayImage: Decodable {
    let mime: String
    let data: String?
    let size: Int
    let at: Int64
    let hostedStatus: String?
    let hostedUrl: String?
    let hostedError: String?
}

private struct SessionResponse: Decodable { let code: String }
private struct LatestResponse: Decodable { let image: RelayImage? }

// State and callbacks belong to the main thread; JSON/image decoding runs on URLSession's queue.
final class RelayClient {
    var onSession: ((String) -> Void)?
    var onStatus: ((String) -> Void)?
    var onMetadata: ((RelayImage) -> Void)?
    var onImage: ((RelayImage, Data) -> Bool)?
    private let origin: String
    private let session: URLSession
    private let interval: TimeInterval
    private var task: URLSessionDataTask?
    private var timer: Timer?
    private var generation = UUID()
    private var code = ""
    private var etag: String?
    private var lastImageAt: Int64 = 0
    private var failures = 0
    private(set) var nextDelay: TimeInterval = 0

    init(origin: String, configuration: URLSessionConfiguration = .ephemeral, interval: TimeInterval = 2) {
        self.origin = origin
        self.interval = interval
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 30
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        session = URLSession(configuration: configuration)
    }

    deinit { timer?.invalidate(); task?.cancel(); session.invalidateAndCancel() }

    func stop() {
        generation = UUID()
        timer?.invalidate(); timer = nil
        task?.cancel(); task = nil
    }

    func start() {
        stop()
        code = ""; etag = nil; lastImageAt = 0; failures = 0
        onStatus?("正在创建配对码…")
        createSession()
    }

    private func schedule(_ delay: TimeInterval) {
        nextDelay = delay
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            guard let self else { return }
            if self.code.isEmpty { self.createSession() } else { self.poll() }
        }
    }

    private func retry() {
        failures = min(failures + 1, 5)
        onStatus?("连接暂时失败，正在重试…")
        schedule(min(30, interval * pow(2, Double(failures - 1))))
    }

    private func recovered() {
        if failures > 0 { onStatus?(lastImageAt > 0 ? "连接已恢复，等待新图片" : "等待手机发送") }
        failures = 0
    }

    private func createSession() {
        let expected = generation
        var request = URLRequest(url: URL(string: "\(origin)/api/session")!)
        request.httpMethod = "POST"
        task = session.dataTask(with: request) { [weak self] data, response, error in
            let result = data.flatMap { try? JSONDecoder().decode(SessionResponse.self, from: $0) }
            DispatchQueue.main.async {
                guard let self, self.generation == expected else { return }
                self.task = nil
                guard error == nil, (response as? HTTPURLResponse)?.statusCode == 201,
                      let result, result.code.range(of: "^\\d{6}$", options: .regularExpression) != nil else { self.retry(); return }
                self.code = result.code; self.failures = 0
                self.onSession?(result.code)
                self.onStatus?("等待手机发送")
                self.poll()
            }
        }
        task?.resume()
    }

    private func poll() {
        guard task == nil, !code.isEmpty else { return }
        let expected = generation
        var request = URLRequest(url: URL(string: "\(origin)/api/room/\(code)/latest?meta=1")!)
        if let etag { request.setValue(etag, forHTTPHeaderField: "If-None-Match") }
        task = session.dataTask(with: request) { [weak self] data, response, error in
            let http = response as? HTTPURLResponse
            let decoded = data.flatMap { try? JSONDecoder().decode(LatestResponse.self, from: $0) }
            DispatchQueue.main.async {
                guard let self, self.generation == expected else { return }
                self.task = nil
                if http?.statusCode == 404 { self.start(); return }
                guard error == nil else { self.retry(); return }
                if http?.statusCode == 304 {
                    self.recovered()
                    self.schedule(self.interval)
                    return
                }
                guard http?.statusCode == 200, let decoded else { self.retry(); return }
                let newTag = http?.value(forHTTPHeaderField: "ETag")
                guard let image = decoded.image else { self.recovered(); self.etag = newTag; self.schedule(self.interval); return }
                if image.at > self.lastImageAt { self.download(expected: expected, newTag: newTag) }
                else { self.recovered(); self.etag = newTag; self.onMetadata?(image); self.schedule(self.interval) }
            }
        }
        task?.resume()
    }

    private func download(expected: UUID, newTag: String?) {
        let url = URL(string: "\(origin)/api/room/\(code)/latest")!
        task = session.dataTask(with: url) { [weak self] data, response, error in
            let http = response as? HTTPURLResponse
            var result: (RelayImage, Data)?
            if error == nil, http?.statusCode == 200, let data, data.count <= 12 * 1024 * 1024,
               let image = try? JSONDecoder().decode(LatestResponse.self, from: data).image,
               let encoded = image.data, let raw = Data(base64Encoded: encoded), raw.count <= 8 * 1024 * 1024,
               let png = Self.clipboardPNG(raw) {
                result = (image, png)
            }
            DispatchQueue.main.async {
                guard let self, self.generation == expected else { return }
                self.task = nil
                if http?.statusCode == 404 { self.start(); return }
                guard let (image, png) = result, self.onImage?(image, png) == true else { self.retry(); return }
                self.lastImageAt = image.at
                self.etag = newTag
                self.failures = 0
                self.schedule(self.interval)
            }
        }
        task?.resume()
    }

    private static func clipboardPNG(_ data: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 4096,
                kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary) else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, "public.png" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }
}
