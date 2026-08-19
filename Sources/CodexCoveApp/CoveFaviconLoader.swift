import AppKit
import Darwin
import Foundation
import ImageIO
import SwiftUI

/// Fetches a deliberately small, privacy-preserving favicon for a saved web link.
/// Callers decide whether a link is confirmed and should be requested at all.
@MainActor
final class CoveFaviconLoader: ObservableObject {
    static var shared = CoveFaviconLoader()

    private static let maximumBytes = 256 * 1024
    private let cache = NSCache<NSURL, NSImage>()
    private let delegate: DownloadDelegate
    private lazy var session: URLSession = URLSession(
        configuration: configuration,
        delegate: delegate,
        delegateQueue: nil
    )
    private let configuration: URLSessionConfiguration
    private var inFlight: Set<URL> = []

    /// Test hosts may observe the rendered state without making the favicon
    /// itself part of the accessibility tree.
    var onPresentation: ((URL, String, Bool) -> Void)?

    @Published private(set) var revision = 0

    /// Supplying a configuration lets focused tests register a custom URLProtocol.
    init(configuration: URLSessionConfiguration = .ephemeral) {
        let configuration = (configuration.copy() as? URLSessionConfiguration)
            ?? .ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.timeoutIntervalForRequest = 5
        configuration.timeoutIntervalForResource = 5
        self.configuration = configuration
        self.delegate = DownloadDelegate(maximumBytes: Self.maximumBytes)
        cache.countLimit = 128
    }

    func image(for artifactURL: URL) -> NSImage? {
        guard let faviconURL = Self.faviconURL(for: artifactURL) else { return nil }
        return cache.object(forKey: faviconURL as NSURL)
    }

    func load(for artifactURL: URL) {
        guard let faviconURL = Self.faviconURL(for: artifactURL),
              cache.object(forKey: faviconURL as NSURL) == nil,
              !inFlight.contains(faviconURL)
        else { return }

        inFlight.insert(faviconURL)
        var request = URLRequest(url: faviconURL)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 5
        delegate.start(request, session: session) { [weak self] data in
            DispatchQueue.main.async {
                guard let self else { return }
                defer {
                    self.inFlight.remove(faviconURL)
                    self.revision &+= 1
                }
                guard let data, let image = Self.decode(data) else { return }
                self.cache.setObject(image, forKey: faviconURL as NSURL)
            }
        }
    }

    func notePresentation(for artifactURL: URL, context: String?) {
        guard let context,
              let faviconURL = Self.faviconURL(for: artifactURL)
        else { return }
        onPresentation?(
            faviconURL,
            context,
            cache.object(forKey: faviconURL as NSURL) != nil
        )
    }

    static func faviconURL(for artifactURL: URL) -> URL? {
        guard let scheme = artifactURL.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = artifactURL.host?.lowercased(),
              isPublicHostname(host)
        else { return nil }

        var components = URLComponents()
        components.scheme = "https"
        components.host = host
        components.path = "/favicon.ico"
        return components.url
    }

    private static func isPublicHostname(_ host: String) -> Bool {
        let normalized = host.trimmingCharacters(in: CharacterSet(charactersIn: "."))
        guard !normalized.isEmpty,
              normalized != "localhost",
              normalized != "home.arpa",
              normalized.contains("."),
              !normalized.contains(":"),
              !isIPv4Address(normalized)
        else { return false }

        let blockedSuffixes = [
            ".local", ".localhost", ".localdomain", ".test", ".example",
            ".invalid", ".internal", ".intranet", ".home", ".home.arpa",
            ".lan", ".corp",
            ".private"
        ]
        return !blockedSuffixes.contains { normalized.hasSuffix($0) }
    }

    private static func isIPv4Address(_ host: String) -> Bool {
        var address = in_addr()
        return host.withCString { inet_aton($0, &address) == 1 }
    }

    private static func decode(_ data: Data) -> NSImage? {
        decodeImage(data) ?? decodeICO(data)
    }

    private static func decodeImage(_ data: Data) -> NSImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            return nil
        }
        let options: CFDictionary = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: 32
        ] as CFDictionary
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else {
            return nil
        }
        return NSImage(cgImage: image, size: NSSize(width: 32, height: 32))
    }

    /// ImageIO on macOS does not decode ICO containers. Extract a bounded PNG
    /// frame, or wrap a standard DIB frame as BMP and let ImageIO downsample it.
    private static func decodeICO(_ data: Data) -> NSImage? {
        guard data.count >= 6,
              littleEndian16(data, at: 0) == 0,
              littleEndian16(data, at: 2) == 1,
              let count = littleEndian16(data, at: 4),
              count > 0,
              count <= 64,
              data.count >= 6 + count * 16
        else { return nil }
        let entries = (0..<count).compactMap {
            index -> (Int, Int, Int, Int, Int)? in
            let base = 6 + index * 16
            guard let size = littleEndian32(data, at: base + 8),
                  let offset = littleEndian32(data, at: base + 12),
                  size > 0,
                  offset >= 6 + count * 16,
                  offset <= data.count,
                  size <= data.count - offset
            else { return nil }
            let width = data[data.startIndex + base] == 0
                ? 256 : Int(data[data.startIndex + base])
            let height = data[data.startIndex + base + 1] == 0
                ? 256 : Int(data[data.startIndex + base + 1])
            return (max(width, height), width, height, offset, size)
        }.sorted { $0.0 > $1.0 }
        for (_, width, height, offset, size) in entries {
            let payload = data.subdata(in: offset..<(offset + size))
            if payload.starts(with: [137, 80, 78, 71, 13, 10, 26, 10]),
               let image = decodeImage(payload) {
                return image
            }
            if let bitmap = bitmapData(
                fromICODIB: payload,
                maximumWidth: width,
                maximumHeight: height
            ),
               let image = decodeImage(bitmap) {
                return image
            }
        }
        return nil
    }

    private static func bitmapData(
        fromICODIB data: Data,
        maximumWidth: Int,
        maximumHeight: Int
    ) -> Data? {
        guard let headerSize = littleEndian32(data, at: 0),
              headerSize >= 40,
              headerSize <= data.count,
              let width = littleEndian32(data, at: 4),
              let rawHeight = littleEndian32(data, at: 8),
              width > 0,
              width <= maximumWidth,
              width <= 256,
              rawHeight >= 2,
              rawHeight.isMultiple(of: 2),
              rawHeight / 2 <= maximumHeight,
              rawHeight / 2 <= 256,
              let bitsPerPixel = littleEndian16(data, at: 14),
              [1, 4, 8, 16, 24, 32].contains(bitsPerPixel),
              let compression = littleEndian32(data, at: 16),
              compression == 0 || compression == 3,
              let colorsUsed = littleEndian32(data, at: 32)
        else { return nil }
        let paletteEntries = colorsUsed > 0
            ? colorsUsed : (bitsPerPixel <= 8 ? 1 << bitsPerPixel : 0)
        let masks = compression == 3 && headerSize == 40 ? 12 : 0
        let dibPixelOffset = headerSize + masks + paletteEntries * 4
        let height = rawHeight / 2
        let rowBytes = ((width * bitsPerPixel + 31) / 32) * 4
        guard dibPixelOffset <= data.count,
              rowBytes * height <= data.count - dibPixelOffset
        else { return nil }
        let pixelOffset = 14 + dibPixelOffset
        var dib = data
        writeLittleEndian32(rawHeight / 2, to: &dib, at: 8)
        var bitmap = Data([0x42, 0x4D])
        appendLittleEndian32(14 + dib.count, to: &bitmap)
        bitmap.append(contentsOf: [0, 0, 0, 0])
        appendLittleEndian32(pixelOffset, to: &bitmap)
        bitmap.append(dib)
        return bitmap
    }

    private static func littleEndian16(_ data: Data, at offset: Int) -> Int? {
        guard offset >= 0, offset <= data.count - 2 else { return nil }
        return Int(data[data.startIndex + offset])
            | Int(data[data.startIndex + offset + 1]) << 8
    }

    private static func littleEndian32(_ data: Data, at offset: Int) -> Int? {
        guard offset >= 0, offset <= data.count - 4 else { return nil }
        return Int(data[data.startIndex + offset])
            | Int(data[data.startIndex + offset + 1]) << 8
            | Int(data[data.startIndex + offset + 2]) << 16
            | Int(data[data.startIndex + offset + 3]) << 24
    }

    private static func appendLittleEndian32(_ value: Int, to data: inout Data) {
        data.append(contentsOf: [
            UInt8(truncatingIfNeeded: value),
            UInt8(truncatingIfNeeded: value >> 8),
            UInt8(truncatingIfNeeded: value >> 16),
            UInt8(truncatingIfNeeded: value >> 24),
        ])
    }

    private static func writeLittleEndian32(
        _ value: Int,
        to data: inout Data,
        at offset: Int
    ) {
        for (index, byte) in [
            UInt8(truncatingIfNeeded: value),
            UInt8(truncatingIfNeeded: value >> 8),
            UInt8(truncatingIfNeeded: value >> 16),
            UInt8(truncatingIfNeeded: value >> 24),
        ].enumerated() {
            data[data.startIndex + offset + index] = byte
        }
    }
}

/// A decorative favicon with the existing SF Symbol fallback.
struct CoveFaviconView: View {
    let artifactURL: URL
    var fallbackSystemImage = "link"
    var presentationContext: String?
    @ObservedObject private var loader: CoveFaviconLoader

    @MainActor
    init(
        artifactURL: URL,
        fallbackSystemImage: String = "link",
        presentationContext: String? = nil
    ) {
        self.artifactURL = artifactURL
        self.fallbackSystemImage = fallbackSystemImage
        self.presentationContext = presentationContext
        self.loader = .shared
    }

    @MainActor
    init(
        artifactURL: URL,
        fallbackSystemImage: String = "link",
        presentationContext: String? = nil,
        loader: CoveFaviconLoader
    ) {
        self.artifactURL = artifactURL
        self.fallbackSystemImage = fallbackSystemImage
        self.presentationContext = presentationContext
        self.loader = loader
    }

    var body: some View {
        Group {
            if let image = loader.image(for: artifactURL) {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
            } else {
                Image(systemName: fallbackSystemImage)
            }
        }
        .accessibilityHidden(true)
        .onAppear {
            loader.load(for: artifactURL)
            loader.notePresentation(for: artifactURL, context: presentationContext)
        }
        .onChange(of: loader.revision) { _, _ in
            loader.notePresentation(for: artifactURL, context: presentationContext)
        }
    }
}

private final class DownloadDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private struct Pending {
        var data = Data()
        var acceptedResponse = false
        let completion: @Sendable (Data?) -> Void
    }

    private let maximumBytes: Int
    private let lock = NSLock()
    private var pending: [Int: Pending] = [:]

    init(maximumBytes: Int) {
        self.maximumBytes = maximumBytes
    }

    func start(
        _ request: URLRequest,
        session: URLSession,
        completion: @escaping @Sendable (Data?) -> Void
    ) {
        let task = session.dataTask(with: request)
        lock.lock()
        pending[task.taskIdentifier] = Pending(completion: completion)
        lock.unlock()
        task.resume()
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        let isAccepted: Bool
        if let response = response as? HTTPURLResponse {
            isAccepted = (200...299).contains(response.statusCode)
                && (response.expectedContentLength < 0
                    || response.expectedContentLength <= Int64(maximumBytes))
        } else {
            isAccepted = false
        }
        update(dataTask.taskIdentifier) { $0.acceptedResponse = isAccepted }
        completionHandler(isAccepted ? .allow : .cancel)
        if !isAccepted { finish(dataTask.taskIdentifier, data: nil) }
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive data: Data
    ) {
        var exceededLimit = false
        lock.lock()
        if var request = pending[dataTask.taskIdentifier] {
            if request.data.count > maximumBytes - data.count {
                exceededLimit = true
            } else {
                request.data.append(data)
                pending[dataTask.taskIdentifier] = request
            }
        }
        lock.unlock()
        if exceededLimit {
            dataTask.cancel()
            finish(dataTask.taskIdentifier, data: nil)
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: (any Error)?
    ) {
        let data: Data? = error == nil ? acceptedData(for: task.taskIdentifier) : nil
        finish(task.taskIdentifier, data: data)
    }

    private func update(_ identifier: Int, _ body: (inout Pending) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        guard var request = pending[identifier] else { return }
        body(&request)
        pending[identifier] = request
    }

    private func acceptedData(for identifier: Int) -> Data? {
        lock.lock()
        defer { lock.unlock() }
        guard let request = pending[identifier], request.acceptedResponse else { return nil }
        return request.data
    }

    private func finish(_ identifier: Int, data: Data?) {
        lock.lock()
        let completion = pending.removeValue(forKey: identifier)?.completion
        lock.unlock()
        completion?(data)
    }
}
