import Foundation

nonisolated struct AmiiboEntry: Codable, Identifiable, Equatable, Sendable {
    let relativePath: String
    let series: String
    let name: String
    let uid: [UInt8]
    let hasUnexpectedManufacturer: Bool

    var id: String { relativePath }
    var displayName: String { "\(series) / \(name)" }

    func matches(_ query: String) -> Bool {
        let normalizedQuery = AmiiboNameNormalizer.normalize(query)
        guard !normalizedQuery.isEmpty else { return true }
        return AmiiboNameNormalizer.normalize(displayName).contains(normalizedQuery)
    }
}

nonisolated struct AmiiboDatabaseIndex: Codable, Equatable, Sendable {
    let generatedAt: Date
    let entries: [AmiiboEntry]
}

nonisolated struct AmiiboDatabaseMetadata: Codable, Equatable, Sendable {
    var installedRevision: String? = nil
    var lastCheckedRevision: String? = nil
    var lastSuccessfulUpdateCheck: Date? = nil
}

nonisolated enum AmiiboDatabaseUpdateResult: Equatable, Sendable {
    case current(AmiiboDatabaseIndex)
    case updated(AmiiboDatabaseIndex)
}

nonisolated enum AmiiboDatabaseError: LocalizedError {
    case missingBinDirectory
    case invalidBinDirectory
    case cacheUnavailable
    case dumpOutsideDatabase
    case unreadableFilename
    case entryMissing(String)
    case entryChanged(String)
    case invalidRevisionResponse
    case downloadFailed(statusCode: Int)

    var errorDescription: String? {
        switch self {
        case .missingBinDirectory:
            "The downloaded archive does not contain an Amiibo Bin directory."
        case .invalidBinDirectory:
            "The Amiibo Bin path is not a readable directory."
        case .cacheUnavailable:
            "The Amiibo database cache directory is unavailable."
        case .dumpOutsideDatabase:
            "An Amiibo dump resolves outside the database directory."
        case .unreadableFilename:
            "An Amiibo filename could not be read."
        case .entryMissing(let path):
            "The indexed Amiibo dump is missing: \(path)."
        case .entryChanged(let path):
            "The indexed Amiibo dump changed and must be reindexed: \(path)."
        case .invalidRevisionResponse:
            "GitHub returned an invalid AmiiboDB revision response."
        case .downloadFailed(let statusCode):
            "AmiiboDB download failed with HTTP status \(statusCode)."
        }
    }
}

nonisolated enum AmiiboNameNormalizer {
    static func normalize(_ input: String) -> String {
        let composed = input.precomposedStringWithCanonicalMapping.lowercased()
        var result = ""
        var separatorPending = false

        for scalar in composed.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                if separatorPending, !result.isEmpty {
                    result.append(" ")
                }
                result.unicodeScalars.append(scalar)
                separatorPending = false
            } else {
                separatorPending = true
            }
        }
        return result
    }
}

actor AmiiboDatabaseService {
    static let updateInterval: TimeInterval = 24 * 60 * 60

    private static let revisionURL = URL(
        string: "https://api.github.com/repos/AmiiboDB/Amiibo/commits/main"
    )!
    private static let archiveURL = URL(
        string: "https://github.com/AmiiboDB/Amiibo/archive/refs/heads/main.zip"
    )!

    private let fileManager: FileManager
    private let urlSession: URLSession
    private let cacheDirectory: URL
    private let databaseDirectory: URL
    private let indexURL: URL
    private let metadataURL: URL

    init(
        fileManager: FileManager = .default,
        urlSession: URLSession = .shared,
        cacheDirectory: URL? = nil
    ) throws {
        self.fileManager = fileManager
        self.urlSession = urlSession

        if let cacheDirectory {
            self.cacheDirectory = cacheDirectory
        } else {
            guard let applicationSupport = fileManager.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first else {
                throw AmiiboDatabaseError.cacheUnavailable
            }
            self.cacheDirectory = applicationSupport
                .appending(path: "Amiibo Emulator", directoryHint: .isDirectory)
                .appending(path: "AmiiboDB", directoryHint: .isDirectory)
        }

        databaseDirectory = self.cacheDirectory.appending(
            path: "Current",
            directoryHint: .isDirectory
        )
        indexURL = databaseDirectory.appending(path: "index.json", directoryHint: .notDirectory)
        metadataURL = self.cacheDirectory.appending(path: "metadata.json", directoryHint: .notDirectory)
    }

    func loadCachedIndex() throws -> AmiiboDatabaseIndex? {
        guard fileManager.fileExists(atPath: indexURL.path) else { return nil }
        let data = try Data(contentsOf: indexURL)
        return try JSONDecoder().decode(AmiiboDatabaseIndex.self, from: data)
    }

    func loadMetadata() throws -> AmiiboDatabaseMetadata {
        guard fileManager.fileExists(atPath: metadataURL.path) else {
            return AmiiboDatabaseMetadata()
        }
        return try JSONDecoder().decode(
            AmiiboDatabaseMetadata.self,
            from: Data(contentsOf: metadataURL)
        )
    }

    func shouldCheckForUpdates(at date: Date = Date()) throws -> Bool {
        guard let lastCheck = try loadMetadata().lastSuccessfulUpdateCheck else {
            return true
        }
        return date.timeIntervalSince(lastCheck) >= Self.updateInterval
    }

    func fetchRemoteRevision() async throws -> String {
        var request = URLRequest(url: Self.revisionURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, response) = try await urlSession.data(for: request)
        try requireSuccessfulHTTPResponse(response)

        struct RevisionResponse: Decodable {
            let sha: String
        }

        let revision = try JSONDecoder().decode(RevisionResponse.self, from: data).sha
        guard !revision.isEmpty else {
            throw AmiiboDatabaseError.invalidRevisionResponse
        }
        return revision
    }

    func recordSuccessfulUpdateCheck(revision: String, at date: Date = Date()) throws {
        var metadata = try loadMetadata()
        metadata.lastCheckedRevision = revision
        metadata.lastSuccessfulUpdateCheck = date
        try fileManager.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        try JSONEncoder().encode(metadata).write(to: metadataURL, options: .atomic)
        try excludeCacheFromBackup()
    }

    func updateIfNeeded(force: Bool = false) async throws -> AmiiboDatabaseUpdateResult {
        if !force,
           try !shouldCheckForUpdates(),
           let cachedIndex = try loadCachedIndex() {
            return .current(cachedIndex)
        }

        let revision = try await fetchRemoteRevision()
        try recordSuccessfulUpdateCheck(revision: revision)
        let metadata = try loadMetadata()
        if metadata.installedRevision == revision,
           let cachedIndex = try loadCachedIndex() {
            return .current(cachedIndex)
        }

        let archiveURL = try await downloadMainArchive()
        defer { try? fileManager.removeItem(at: archiveURL) }
        let extractionDirectory = cacheDirectory.appending(
            path: "Extraction-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        defer { try? fileManager.removeItem(at: extractionDirectory) }

        let repositoryRoot = try AmiiboArchiveExtractor.extract(
            archiveURL: archiveURL,
            to: extractionDirectory,
            fileManager: fileManager
        )
        let index = try installExtractedRepository(at: repositoryRoot, revision: revision)
        return .updated(index)
    }

    func downloadMainArchive() async throws -> URL {
        let (temporaryURL, response) = try await urlSession.download(from: Self.archiveURL)
        try requireSuccessfulHTTPResponse(response)

        let downloadsDirectory = cacheDirectory.appending(
            path: "Downloads",
            directoryHint: .isDirectory
        )
        try fileManager.createDirectory(at: downloadsDirectory, withIntermediateDirectories: true)
        let archiveURL = downloadsDirectory.appending(
            path: "\(UUID().uuidString).zip",
            directoryHint: .notDirectory
        )
        try fileManager.moveItem(at: temporaryURL, to: archiveURL)
        try excludeCacheFromBackup()
        return archiveURL
    }

    func installExtractedRepository(at repositoryRoot: URL, revision: String) throws
        -> AmiiboDatabaseIndex {
        try fileManager.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        let stagingDirectory = cacheDirectory.appending(
            path: "Staging-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        defer { try? fileManager.removeItem(at: stagingDirectory) }

        try fileManager.copyItem(at: repositoryRoot, to: stagingDirectory)
        let index = try indexDatabase(at: stagingDirectory)
        let stagedIndexURL = stagingDirectory.appending(
            path: "index.json",
            directoryHint: .notDirectory
        )
        try JSONEncoder().encode(index).write(to: stagedIndexURL, options: .atomic)

        if fileManager.fileExists(atPath: databaseDirectory.path) {
            _ = try fileManager.replaceItemAt(
                databaseDirectory,
                withItemAt: stagingDirectory,
                backupItemName: nil,
                options: []
            )
        } else {
            try fileManager.moveItem(at: stagingDirectory, to: databaseDirectory)
        }

        var metadata = try loadMetadata()
        metadata.installedRevision = revision
        metadata.lastCheckedRevision = revision
        metadata.lastSuccessfulUpdateCheck = Date()
        try JSONEncoder().encode(metadata).write(to: metadataURL, options: .atomic)
        try excludeCacheFromBackup()
        return index
    }

    func indexDatabase(at repositoryRoot: URL) throws -> AmiiboDatabaseIndex {
        let binDirectory = repositoryRoot.appending(path: "Amiibo Bin", directoryHint: .isDirectory)
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: binDirectory.path, isDirectory: &isDirectory) else {
            throw AmiiboDatabaseError.missingBinDirectory
        }
        guard isDirectory.boolValue else {
            throw AmiiboDatabaseError.invalidBinDirectory
        }

        let canonicalBinDirectory = binDirectory.resolvingSymlinksInPath().standardizedFileURL
        guard let enumerator = fileManager.enumerator(
            at: canonicalBinDirectory,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles],
            errorHandler: { _, _ in true }
        ) else {
            throw AmiiboDatabaseError.invalidBinDirectory
        }

        var entries: [AmiiboEntry] = []
        for case let candidateURL as URL in enumerator {
            if candidateURL.lastPathComponent == "!Essential Files" {
                enumerator.skipDescendants()
                continue
            }

            let values = try candidateURL.resourceValues(
                forKeys: [.isDirectoryKey, .isRegularFileKey, .fileSizeKey]
            )
            guard values.isRegularFile == true,
                  candidateURL.pathExtension.caseInsensitiveCompare("bin") == .orderedSame,
                  values.fileSize == ValidatedAmiiboDump.byteCount else {
                continue
            }

            let canonicalCandidate = candidateURL.resolvingSymlinksInPath().standardizedFileURL
            guard canonicalCandidate.path.hasPrefix(canonicalBinDirectory.path + "/") else {
                continue
            }
            guard let validated = try? AmiiboDumpValidator.validate(Data(contentsOf: canonicalCandidate)) else {
                continue
            }

            let relativePath = String(
                canonicalCandidate.path.dropFirst(canonicalBinDirectory.path.count + 1)
            )
            let name = canonicalCandidate.deletingPathExtension().lastPathComponent
            guard !name.isEmpty else {
                throw AmiiboDatabaseError.unreadableFilename
            }
            let parentName = canonicalCandidate.deletingLastPathComponent().lastPathComponent
            let series = parentName == canonicalBinDirectory.lastPathComponent
                ? "Uncategorized"
                : parentName

            entries.append(
                AmiiboEntry(
                    relativePath: relativePath,
                    series: series,
                    name: name,
                    uid: Array(validated.uid),
                    hasUnexpectedManufacturer: validated.hasUnexpectedManufacturer
                )
            )
        }

        entries.sort { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
        return AmiiboDatabaseIndex(generatedAt: Date(), entries: entries)
    }

    func persist(_ index: AmiiboDatabaseIndex) throws {
        try fileManager.createDirectory(at: databaseDirectory, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(index)
        try data.write(to: indexURL, options: .atomic)
        try excludeCacheFromBackup()
    }

    func readAndRevalidate(_ entry: AmiiboEntry) throws -> ValidatedAmiiboDump {
        let binDirectory = databaseDirectory.appending(path: "Amiibo Bin", directoryHint: .isDirectory)
        let dumpURL = binDirectory.appending(path: entry.relativePath, directoryHint: .notDirectory)
        let canonicalBinDirectory = binDirectory.resolvingSymlinksInPath().standardizedFileURL
        let canonicalDumpURL = dumpURL.resolvingSymlinksInPath().standardizedFileURL
        guard canonicalDumpURL.path.hasPrefix(canonicalBinDirectory.path + "/") else {
            throw AmiiboDatabaseError.dumpOutsideDatabase
        }
        guard fileManager.fileExists(atPath: canonicalDumpURL.path) else {
            throw AmiiboDatabaseError.entryMissing(entry.relativePath)
        }

        let validated = try AmiiboDumpValidator.validate(Data(contentsOf: canonicalDumpURL))
        guard Array(validated.uid) == entry.uid else {
            throw AmiiboDatabaseError.entryChanged(entry.relativePath)
        }
        return validated
    }

    private func requireSuccessfulHTTPResponse(_ response: URLResponse) throws {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw AmiiboDatabaseError.invalidRevisionResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw AmiiboDatabaseError.downloadFailed(statusCode: httpResponse.statusCode)
        }
    }

    private func excludeCacheFromBackup() throws {
        var resourceValues = URLResourceValues()
        resourceValues.isExcludedFromBackup = true
        var mutableCacheDirectory = cacheDirectory
        try mutableCacheDirectory.setResourceValues(resourceValues)
    }
}
