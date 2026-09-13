import Foundation
import SwiftUI
import CoreGraphics
import ImageIO
import CryptoKit

enum MorphPackCache {
    private static let directoryName = "MorphPreviewPacks-v1"

    private static func cacheURL(for url: URL) -> URL? {
        let hash = url.deletingPathExtension().lastPathComponent
        guard hash.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil,
              let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else {
            return nil
        }
        return caches.appendingPathComponent(directoryName, isDirectory: true)
            .appendingPathComponent("\(hash).morphpack")
    }

    static func read(for url: URL) -> Data? {
        guard let path = cacheURL(for: url),
              let data = try? Data(contentsOf: path),
              !data.isEmpty else { return nil }
        return data
    }

    static func write(_ data: Data, for url: URL) {
        guard let path = cacheURL(for: url) else { return }
        do {
            try FileManager.default.createDirectory(
                at: path.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: path, options: .atomic)
        } catch {
            NSLog("Cubacadabra morph pack cache write skipped: %@", error.localizedDescription)
        }
    }
}

/// Loads a validated game manifest and script from cache, bundle, or the host.
struct GamePackageLoader {
    // The generated Luau package format changed with the Build Together UI.
    // Versioning these keys separates per-game packages from older caches.
    // Release selection below also keeps an equal-version cache from masking
    // the package shipped in a newer app build.
    private static let cachedPackageKeyPrefix = "cubacadabra.cached-package.v5."
    private static let maximumManifestBytes = 512_000
    private static let maximumScriptBytes = 512_000
    private static let maximumImageAssetBytes = 8 * 1024 * 1024
    private static let maximumMorphPackBytes = 64 * 1024 * 1024
    private static let maximumMorphResidentBytes = 16 * 1024 * 1024
    private static let audioIDPattern = "^[A-Za-z0-9._-]{1,64}$"
    private static let audioPathPattern = "^assets/(?:[A-Za-z0-9_-][A-Za-z0-9._-]*/)*[A-Za-z0-9_-][A-Za-z0-9._-]*\\.wav$"
    private static let imageIDPattern = "^[A-Za-z0-9._-]{1,64}$"
    private static let imagePathPattern = "^assets/(?:[A-Za-z0-9_-][A-Za-z0-9._-]*/)*[A-Za-z0-9_-][A-Za-z0-9._-]*\\.(?:png|jpe?g)$"
    private static let morphIDPattern = "^[a-z0-9-]+:[a-z0-9_-]+(?:/[a-z0-9_-]+)*\\.v[1-9][0-9]*$"
    private static let morphPathPattern = "^assets/(?:[A-Za-z0-9_-][A-Za-z0-9._-]*/)*[A-Za-z0-9_-][A-Za-z0-9._-]*\\.morphpack$"

    func load(
        gameID: String = "first-game",
        packageBaseURL: URL? = nil,
        additionalMorphPackURLs: [URL] = []
    ) async throws -> LoadedGamePackage {
        guard Self.isValidGameID(gameID) else { throw GamePackageError.invalidGameID }
        NSLog(
            "Cubacadabra package load: game=%@ requestedBase=%@ backend=%@ gameBase=%@",
            gameID,
            packageBaseURL?.absoluteString ?? "<nil>",
            ClientConfiguration.backendURL.absoluteString,
            ClientConfiguration.gameBaseURL(for: gameID).absoluteString
        )
        if let packageBaseURL {
            return try await fetchPackage(
                for: gameID,
                baseURL: packageBaseURL,
                cache: false,
                additionalMorphPackURLs: additionalMorphPackURLs
            )
        }
#if DEBUG
        // The Xcode build phase assembles the sibling game project into the
        // app bundle. Prefer that package during local development so a
        // source edit or package error is not hidden by an earlier cache.
        return try await loadBundledPackage(for: gameID, additionalMorphPackURLs: additionalMorphPackURLs)
#else
        let bundled = try? await loadBundledPackage(for: gameID, additionalMorphPackURLs: additionalMorphPackURLs)
        let cached = await cachedPackage(for: gameID, additionalMorphPackURLs: additionalMorphPackURLs)
        if let bundled {
            guard let cached,
                  let cachedVersion = cached.version,
                  let bundledVersion = bundled.version,
                  cachedVersion > bundledVersion else {
                return bundled
            }
            return cached
        }
        if let cached { return cached }
        return try await fetchPackage(
            for: gameID,
            baseURL: remoteBaseURL(for: gameID),
            cache: true,
            additionalMorphPackURLs: additionalMorphPackURLs
        )
#endif
    }

    /// Refreshes the validated package for the next launch. The bundled
    /// package for each game remains the offline fallback if the host is unavailable.
    func refreshPackage(gameID: String = "first-game") async {
        guard Self.isValidGameID(gameID) else { return }
        let baseURL = remoteBaseURL(for: gameID)
        let manifestURL = baseURL.appendingPathComponent("manifest.json")
        let scriptURL = baseURL.appendingPathComponent("game.luau")
        let packageURL = baseURL.appendingPathComponent("package.json")
        guard let packageData = try? await fetch(packageURL, maximumBytes: Self.maximumManifestBytes),
              let manifestData = try? await fetch(manifestURL, maximumBytes: Self.maximumManifestBytes),
              let scriptData = try? await fetch(scriptURL, maximumBytes: Self.maximumScriptBytes),
              verifyPackageDescriptor(packageData, gameID: gameID, manifestData: manifestData, scriptData: scriptData),
              let script = String(data: scriptData, encoding: .utf8),
              let loaded = try? makePackage(
                manifestData: manifestData,
                script: script,
                audioBaseURL: baseURL,
                expectedGameID: gameID
              ),
              (try? await loadImageAssets(from: loaded, baseURL: baseURL)) != nil else { return }
        cachePackage(packageData: packageData, manifestData: manifestData, script: script, gameID: gameID)
    }

    private func fetchPackage(
        for gameID: String,
        baseURL: URL,
        cache: Bool,
        additionalMorphPackURLs: [URL]
    ) async throws -> LoadedGamePackage {
        let packageData = try await fetch(
            baseURL.appendingPathComponent("package.json"),
            maximumBytes: Self.maximumManifestBytes
        )
        let manifestURL = baseURL.appendingPathComponent("manifest.json")
        let scriptURL = baseURL.appendingPathComponent("game.luau")
        NSLog(
            "Cubacadabra package fetch: game=%@ base=%@ manifest=%@ script=%@ cache=%@",
            gameID,
            baseURL.absoluteString,
            manifestURL.absoluteString,
            scriptURL.absoluteString,
            cache ? "yes" : "no"
        )
        let manifestData = try await fetch(manifestURL, maximumBytes: Self.maximumManifestBytes)
        let scriptData = try await fetch(scriptURL, maximumBytes: Self.maximumScriptBytes)
        guard verifyPackageDescriptor(packageData, gameID: gameID, manifestData: manifestData, scriptData: scriptData) else {
            throw GamePackageError.invalidBundledPackage
        }
        guard let script = String(data: scriptData, encoding: .utf8) else { throw GamePackageError.invalidScript }
        let loaded = try makePackage(
            manifestData: manifestData,
            script: script,
            audioBaseURL: baseURL,
            expectedGameID: gameID
        )
        let loadedPackage = try await loadImageAssets(
            from: loaded,
            baseURL: baseURL,
            additionalMorphPackURLs: additionalMorphPackURLs
        )
        NSLog(
            "Cubacadabra package loaded: game=%@ manifestBytes=%ld scriptBytes=%ld imageCount=%ld",
            gameID,
            manifestData.count,
            scriptData.count,
            loadedPackage.imageAssets.count
        )
        if cache { cachePackage(packageData: packageData, manifestData: manifestData, script: script, gameID: gameID) }
        return loadedPackage
    }

    private func loadBundledPackage(
        for gameID: String,
        additionalMorphPackURLs: [URL]
    ) async throws -> LoadedGamePackage {
        let packageSubdirectory = "games/\(gameID)"
        let manifestURL = Bundle.main.url(
            forResource: "manifest",
            withExtension: "json",
            subdirectory: packageSubdirectory
        )
        let scriptURL = Bundle.main.url(
            forResource: "game",
            withExtension: "luau",
            subdirectory: packageSubdirectory
        )
        let packageURL = Bundle.main.url(
            forResource: "package",
            withExtension: "json",
            subdirectory: packageSubdirectory
        )
        guard let packageURL, let manifestURL, let scriptURL,
              let packageData = try? Data(contentsOf: packageURL),
              let manifestData = try? Data(contentsOf: manifestURL),
              let scriptData = try? Data(contentsOf: scriptURL),
              let script = String(data: scriptData, encoding: .utf8) else { throw GamePackageError.missingBundledPackage }
        guard verifyPackageDescriptor(packageData, gameID: gameID, manifestData: manifestData, scriptData: scriptData) else {
            throw GamePackageError.invalidBundledPackage
        }
#if DEBUG
        NSLog("Cubacadabra using %@ package at %@", gameID, scriptURL.path)
#endif
        let loaded = try makePackage(
            manifestData: manifestData,
            script: script,
            audioBaseURL: manifestURL.deletingLastPathComponent(),
            expectedGameID: gameID
        )
        return try await loadImageAssets(
            from: loaded,
            baseURL: manifestURL.deletingLastPathComponent(),
            additionalMorphPackURLs: additionalMorphPackURLs
        )
    }

    private func cachedPackage(
        for gameID: String,
        additionalMorphPackURLs: [URL]
    ) async -> LoadedGamePackage? {
        guard let cached = cachedPackageData(for: gameID),
              verifyPackageDescriptor(cached.package, gameID: gameID, manifestData: cached.manifest, scriptData: Data(cached.script.utf8)),
              cached.manifest.count <= Self.maximumManifestBytes,
              cached.script.utf8.count <= Self.maximumScriptBytes else { return nil }
        guard let loaded = try? makePackage(
            manifestData: cached.manifest,
            script: cached.script,
            audioBaseURL: remoteBaseURL(for: gameID),
            expectedGameID: gameID
        ) else { return nil }
        // Image payloads are not stored in UserDefaults with the manifest and
        // script. Keep a valid cached game playable offline, using its normal
        // material-color fallback until the package can be refreshed online.
        return (try? await loadImageAssets(
            from: loaded,
            baseURL: remoteBaseURL(for: gameID),
            additionalMorphPackURLs: additionalMorphPackURLs
        )) ?? loaded
    }

    private struct CachedPackage: Codable {
        let package: Data
        let manifest: Data
        let script: String
    }

    private func cachedPackageData(for gameID: String) -> CachedPackage? {
        guard let data = UserDefaults.standard.data(forKey: Self.cachedPackageKeyPrefix + gameID) else { return nil }
        return try? JSONDecoder().decode(CachedPackage.self, from: data)
    }

    private func cachePackage(packageData: Data, manifestData: Data, script: String, gameID: String) {
        guard let data = try? JSONEncoder().encode(CachedPackage(package: packageData, manifest: manifestData, script: script)) else { return }
        UserDefaults.standard.set(data, forKey: Self.cachedPackageKeyPrefix + gameID)
    }

    private func verifyPackageDescriptor(
        _ packageData: Data,
        gameID: String,
        manifestData: Data,
        scriptData: Data
    ) -> Bool {
        guard let descriptor = try? JSONSerialization.jsonObject(with: packageData) as? [String: Any],
              descriptor["id"] as? String == gameID,
              descriptor["entry"] as? String == "game.luau",
              descriptor["manifest"] as? String == "manifest.json",
              let checksums = descriptor["sha256"] as? [String: String],
              let manifestHash = checksums["manifest.json"],
              let scriptHash = checksums["game.luau"] else { return false }
        let actualManifestHash = SHA256.hash(data: manifestData).map { String(format: "%02x", $0) }.joined()
        let actualScriptHash = SHA256.hash(data: scriptData).map { String(format: "%02x", $0) }.joined()
        return manifestHash == actualManifestHash && scriptHash == actualScriptHash
    }

    private func makePackage(
        manifestData: Data,
        script: String,
        audioBaseURL: URL,
        expectedGameID: String? = nil
    ) throws -> LoadedGamePackage {
        guard !script.isEmpty, script.utf8.count <= Self.maximumScriptBytes else { throw GamePackageError.invalidScript }
        guard manifestData.count <= Self.maximumManifestBytes, let manifest = String(data: manifestData, encoding: .utf8) else { throw GamePackageError.invalidBundledPackage }
        let package: GamePackage
        do { package = try JSONDecoder().decode(GamePackage.self, from: manifestData) }
        catch { throw GamePackageError.invalidBundledPackage }
        guard package.worldDefinition(named: package.initialWorld) != nil else { throw GamePackageError.missingWorld(package.initialWorld) }
        let manifestObject = try? JSONSerialization.jsonObject(with: manifestData) as? [String: Any]
        if let expectedGameID,
           let manifestObject,
           let manifestGameID = manifestObject["id"] as? String,
           manifestGameID != expectedGameID { throw GamePackageError.invalidGameID }
        let audioAssets = try normalizedAudioAssets(package.assets?.audio, baseURL: audioBaseURL)
        return LoadedGamePackage(
            package: package,
            manifest: manifest,
            script: script,
            audioAssets: audioAssets,
            imageAssets: [:],
            morphPacks: [],
            version: GamePackageVersion(manifestObject?["version"] as? String)
        )
    }

    private func normalizedAudioAssets(
        _ definitions: [String: GameAudioAssetDefinition]?,
        baseURL: URL
    ) throws -> [String: LoadedGameAudioAsset] {
        try (definitions ?? [:]).reduce(into: [:]) { assets, entry in
            let (id, definition) = entry
            guard id.range(of: Self.audioIDPattern, options: .regularExpression) != nil else {
                throw GamePackageError.invalidAudioAsset(id)
            }
            guard definition.path.range(
                of: Self.audioPathPattern,
                options: [.regularExpression, .caseInsensitive]
            ) != nil else {
                throw GamePackageError.invalidAudioAsset(id)
            }
            guard definition.volume.isFinite, (0...1).contains(definition.volume),
                  let url = URL(string: definition.path, relativeTo: baseURL)?.absoluteURL else {
                throw GamePackageError.invalidAudioAsset(id)
            }
            assets[id] = LoadedGameAudioAsset(url: url, volume: definition.volume)
        }
    }

    private func loadImageAssets(
        from loaded: LoadedGamePackage,
        baseURL: URL,
        additionalMorphPackURLs: [URL] = []
    ) async throws -> LoadedGamePackage {
        let definitions = try normalizedImageAssets(loaded.package.assets?.images, baseURL: baseURL)
        NSLog("Cubacadabra image assets declared: count=%ld base=%@", definitions.count, baseURL.absoluteString)
        var imageAssets: [String: LoadedGameImageAsset] = [:]
        for entry in definitions {
            let (id, definition) = entry
            let data: Data
            if definition.url.isFileURL {
                NSLog("Cubacadabra image asset read from bundle: id=%@ url=%@", id, definition.url.absoluteString)
                guard let fileData = try? Data(contentsOf: definition.url) else {
                    NSLog("Cubacadabra image asset bundle read failed: id=%@ url=%@", id, definition.url.absoluteString)
                    throw GamePackageError.invalidImageAsset(id)
                }
                data = fileData
                guard data.count <= Self.maximumImageAssetBytes else {
                    NSLog("Cubacadabra image asset too large: id=%@ bytes=%ld", id, data.count)
                    throw GamePackageError.invalidImageAsset(id)
                }
            } else {
                NSLog("Cubacadabra image asset fetch: id=%@ url=%@", id, definition.url.absoluteString)
                data = try await fetch(definition.url, maximumBytes: Self.maximumImageAssetBytes)
            }
            NSLog("Cubacadabra image asset loaded: id=%@ bytes=%ld", id, data.count)
            imageAssets[id] = LoadedGameImageAsset(data: data)
        }
        return LoadedGamePackage(
            package: loaded.package,
            manifest: loaded.manifest,
            script: loaded.script,
            audioAssets: loaded.audioAssets,
            imageAssets: imageAssets,
            morphPacks: try await loadMorphPacks(
                from: loaded,
                baseURL: baseURL,
                additionalMorphPackURLs: additionalMorphPackURLs
            ),
            version: loaded.version
        )
    }

    private func loadMorphPacks(
        from loaded: LoadedGamePackage,
        baseURL: URL,
        additionalMorphPackURLs: [URL] = []
    ) async throws -> [LoadedGameMorphPack] {
        let definitions = try normalizedMorphPacks(loaded.package.assets?.morphPacks, baseURL: baseURL)
        var totalBytes = 0
        var packs: [LoadedGameMorphPack] = []
        var entries = definitions.sorted(by: { $0.key < $1.key }).map { ($0.key, $0.value.url) }
        var seenURLs = Set(entries.map { $0.1 })
        for (index, url) in additionalMorphPackURLs.enumerated() where seenURLs.insert(url).inserted {
            entries.append(("account-morph-\(index)", url))
        }
        for (id, url) in entries {
            let data: Data
            if url.isFileURL {
                guard let fileData = try? Data(contentsOf: url) else {
                    throw GamePackageError.invalidMorphPack(id)
                }
                data = fileData
            } else {
                if let cached = MorphPackCache.read(for: url) {
                    data = cached
                } else {
                    let fetched = try await fetch(url, maximumBytes: Self.maximumMorphPackBytes)
                    MorphPackCache.write(fetched, for: url)
                    data = fetched
                }
            }
            guard !data.isEmpty, data.count <= Self.maximumMorphPackBytes else {
                throw GamePackageError.invalidMorphPack(id)
            }
            totalBytes += data.count
            guard totalBytes <= Self.maximumMorphResidentBytes else {
                throw GamePackageError.morphPackResidencyTooLarge
            }
            packs.append(LoadedGameMorphPack(data: data))
        }
        return packs
    }

    private func normalizedImageAssets(
        _ definitions: [String: GameImageAssetDefinition]?,
        baseURL: URL
    ) throws -> [String: LoadedGameImageDefinition] {
        let entries = definitions ?? [:]
        guard entries.count <= 16 else { throw GamePackageError.tooManyImageAssets }
        return try entries.reduce(into: [:]) { assets, entry in
            let (id, definition) = entry
            guard id.range(of: Self.imageIDPattern, options: .regularExpression) != nil,
                  definition.path.range(
                    of: Self.imagePathPattern,
                    options: [.regularExpression, .caseInsensitive]
                  ) != nil,
                  let url = URL(string: definition.path, relativeTo: baseURL)?.absoluteURL else {
                throw GamePackageError.invalidImageAsset(id)
            }
            assets[id] = LoadedGameImageDefinition(url: url)
        }
    }

    private func normalizedMorphPacks(
        _ definitions: [String: GameMorphPackDefinition]?,
        baseURL: URL
    ) throws -> [String: LoadedGameMorphDefinition] {
        let entries = definitions ?? [:]
        guard entries.count <= 32 else { throw GamePackageError.tooManyMorphPacks }
        return try entries.reduce(into: [:]) { packs, entry in
            let (id, definition) = entry
            guard id.range(of: Self.morphIDPattern, options: .regularExpression) != nil,
                  definition.path.range(
                    of: Self.morphPathPattern,
                    options: [.regularExpression, .caseInsensitive]
                  ) != nil,
                  let url = URL(string: definition.path, relativeTo: baseURL)?.absoluteURL else {
                throw GamePackageError.invalidMorphPack(id)
            }
            packs[id] = LoadedGameMorphDefinition(url: url)
        }
    }

    private func remoteBaseURL(for gameID: String) -> URL {
        ClientConfiguration.gameBaseURL(for: gameID)
    }

    private static func isValidGameID(_ gameID: String) -> Bool {
        (3...64).contains(gameID.utf8.count)
            && gameID.range(of: "^[a-z0-9]+(?:-[a-z0-9]+)*$", options: .regularExpression) != nil
    }

    private func fetch(_ url: URL, maximumBytes: Int) async throws -> Data {
        var request = URLRequest(url: url)
        request.timeoutInterval = 5
        NSLog("Cubacadabra asset request: %@", url.absoluteString)
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            NSLog("Cubacadabra asset network error: url=%@ error=%@", url.absoluteString, error.localizedDescription)
            throw error
        }
        NSLog(
            "Cubacadabra asset response: url=%@ status=%ld bytes=%ld contentType=%@",
            url.absoluteString,
            (response as? HTTPURLResponse)?.statusCode ?? 0,
            data.count,
            (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type") ?? "<nil>"
        )
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            NSLog("Cubacadabra asset HTTP failure: url=%@ status=%ld", url.absoluteString, (response as? HTTPURLResponse)?.statusCode ?? 0)
            throw GamePackageError.httpFailure((response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        guard data.count <= maximumBytes else {
            NSLog("Cubacadabra asset exceeded byte limit: url=%@ bytes=%ld limit=%ld", url.absoluteString, data.count, maximumBytes)
            throw GamePackageError.invalidBundledPackage
        }
        return data
    }
}

struct LoadedGamePackage {
    let package: GamePackage
    let manifest: String
    let script: String
    let audioAssets: [String: LoadedGameAudioAsset]
    let imageAssets: [String: LoadedGameImageAsset]
    let morphPacks: [LoadedGameMorphPack]
    let version: GamePackageVersion?
}

struct LoadedGameImageAsset {
    let data: Data
}

struct LoadedGameMorphPack {
    let data: Data
}

private struct LoadedGameImageDefinition {
    let url: URL
}

private struct LoadedGameMorphDefinition {
    let url: URL
}

struct GameImageAtlas {
    let width: Int
    let height: Int
    let pixels: Data
    let regionsJSON: String
}

enum GameImageAtlasBuilder {
    private static let maxAtlasDimension = 2048
    private static let maxUploadDimension = 1020
    private static let padding = 2

    static func make(from assets: [String: LoadedGameImageAsset]) throws -> GameImageAtlas? {
        guard !assets.isEmpty else { return nil }
        let images = try assets.keys.sorted().map { id in
            let asset = assets[id]!
            let image = try decode(asset.data, id: id)
            return try fit(image, id: id)
        }

        var placements: [(image: DecodedGameImage, x: Int, y: Int)] = []
        var x = padding
        var y = padding
        var rowHeight = 0
        for image in images {
            guard image.width + padding * 2 <= maxAtlasDimension,
                  image.height + padding * 2 <= maxAtlasDimension else {
                throw GamePackageError.invalidImageAsset(image.id)
            }
            if x + image.width + padding > maxAtlasDimension {
                x = padding
                y += rowHeight + padding
                rowHeight = 0
            }
            guard y + image.height + padding <= maxAtlasDimension else {
                throw GamePackageError.imageAtlasTooLarge
            }
            placements.append((image: image, x: x, y: y))
            x += image.width + padding
            rowHeight = max(rowHeight, image.height)
        }

        var height = 1
        let usedHeight = y + rowHeight + padding
        while height < usedHeight { height *= 2 }
        guard height <= maxAtlasDimension else { throw GamePackageError.imageAtlasTooLarge }
        let width = maxAtlasDimension
        var atlasPixels = [UInt8](repeating: 0, count: width * height * 4)
        var regions: [String: [Double]] = [:]
        for placement in placements {
            let image = placement.image
            for row in 0..<image.height {
                let sourceStart = row * image.width * 4
                let destinationStart = ((placement.y + row) * width + placement.x) * 4
                atlasPixels.replaceSubrange(
                    destinationStart..<(destinationStart + image.width * 4),
                    with: image.pixels[sourceStart..<(sourceStart + image.width * 4)]
                )
            }
        }
        // Keep the region math explicit so it stays in the same normalized
        // form as the browser atlas: x/width, y/height, w/width, h/height.
        for placement in placements {
            regions[placement.image.id] = [
                (Double(placement.x) + 0.5) / Double(width),
                (Double(placement.y) + 0.5) / Double(height),
                Double(max(1, placement.image.width - 1)) / Double(width),
                Double(max(1, placement.image.height - 1)) / Double(height),
            ]
        }
        let regionData = try JSONSerialization.data(withJSONObject: regions)
        guard let regionsJSON = String(data: regionData, encoding: .utf8) else {
            throw GamePackageError.imageAtlasEncodingFailed
        }
        return GameImageAtlas(width: width, height: height, pixels: Data(atlasPixels), regionsJSON: regionsJSON)
    }

    private static func decode(_ data: Data, id: String) throws -> DecodedGameImage {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(
                source,
                0,
                [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceThumbnailMaxPixelSize: maxUploadDimension,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                ] as CFDictionary
              ),
              image.width > 0, image.height > 0 else {
            throw GamePackageError.invalidImageAsset(id)
        }
        let bytesPerRow = image.width * 4
        var pixels = [UInt8](repeating: 0, count: image.height * bytesPerRow)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let rendered = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: image.width,
                height: image.height,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return true
        }
        guard rendered else { throw GamePackageError.invalidImageAsset(id) }
        return DecodedGameImage(id: id, width: image.width, height: image.height, pixels: pixels)
    }

    private static func fit(_ image: DecodedGameImage, id: String) throws -> DecodedGameImage {
        guard image.width <= maxUploadDimension, image.height <= maxUploadDimension else {
            throw GamePackageError.invalidImageAsset(id)
        }
        return image
    }
}

private struct DecodedGameImage {
    let id: String
    let width: Int
    let height: Int
    let pixels: [UInt8]
}

struct GamePackageVersion: Comparable {
    let major: Int
    let minor: Int
    let patch: Int
    let prerelease: String?

    init?(_ source: String?) {
        guard let source else { return nil }
        let withoutBuild = source.split(separator: "+", maxSplits: 1)[0]
        let versionParts = withoutBuild.split(
            separator: "-",
            maxSplits: 1,
            omittingEmptySubsequences: false
        )
        let core = versionParts[0].split(separator: ".", omittingEmptySubsequences: false)
        guard core.count == 3,
              let major = Int(core[0]), major >= 0,
              let minor = Int(core[1]), minor >= 0,
              let patch = Int(core[2]), patch >= 0 else { return nil }
        self.major = major
        self.minor = minor
        self.patch = patch
        prerelease = versionParts.count == 2 ? String(versionParts[1]) : nil
    }

    static func < (left: Self, right: Self) -> Bool {
        let leftCore = (left.major, left.minor, left.patch)
        let rightCore = (right.major, right.minor, right.patch)
        if leftCore != rightCore {
            if left.major != right.major { return left.major < right.major }
            if left.minor != right.minor { return left.minor < right.minor }
            return left.patch < right.patch
        }
        switch (left.prerelease, right.prerelease) {
        case (nil, nil): return false
        case (nil, _): return false
        case (_, nil): return true
        case let (left?, right?): return left.localizedStandardCompare(right) == .orderedAscending
        }
    }
}

extension Color {
    init(hex: String) {
        let cleaned = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        let value = UInt64(cleaned, radix: 16) ?? 0xffffff
        self.init(red: Double((value >> 16) & 0xff) / 255, green: Double((value >> 8) & 0xff) / 255, blue: Double(value & 0xff) / 255)
    }
}
