import AppKit

/// Downloads album art once per URL and keeps a small in-memory cache plus a
/// disk copy, so skipping back and forth through a playlist never flickers.
@MainActor
final class ArtworkCache {

    static let shared = ArtworkCache()

    private var memory = NSCache<NSString, NSImage>()
    private var waiters: [String: [(NSImage?) -> Void]] = [:]
    private let directory: URL

    private init() {
        memory.countLimit = 60
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        directory = base.appendingPathComponent("BarDeck/artwork", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    /// Demo mode puts its generated covers here under made-up URLs.
    func register(_ image: NSImage, for urlString: String) {
        memory.setObject(image, forKey: urlString as NSString)
    }

    func image(for urlString: String, completion: @escaping (NSImage?) -> Void) {
        guard !urlString.isEmpty else { completion(nil); return }
        let key = urlString as NSString

        if let cached = memory.object(forKey: key) { completion(cached); return }

        let fileURL = directory.appendingPathComponent(Self.filename(for: urlString))
        if let data = try? Data(contentsOf: fileURL), let image = NSImage(data: data) {
            memory.setObject(image, forKey: key)
            completion(image)
            return
        }

        guard let url = URL(string: urlString) else { completion(nil); return }
        // The cover is asked for by the card and the Control Strip item at once: both get it.
        if waiters[urlString] != nil { waiters[urlString]?.append(completion); return }
        waiters[urlString] = [completion]

        Task { [weak self] in
            let data = try? await URLSession.shared.data(from: url).0
            let image = data.flatMap(NSImage.init(data:))
            if let data, image != nil { try? data.write(to: fileURL) }
            guard let self else { return }
            if let image { self.memory.setObject(image, forKey: urlString as NSString) }
            let callbacks = self.waiters.removeValue(forKey: urlString) ?? []
            callbacks.forEach { $0(image) }
        }
    }

    private static func filename(for url: String) -> String {
        // Spotify's artwork URLs carry a stable content hash, so a simple digest of
        // the whole string is a fine cache key.
        var hash: UInt64 = 5381
        for byte in url.utf8 { hash = (hash &* 33) ^ UInt64(byte) }
        return String(format: "%016llx.img", hash)
    }
}
