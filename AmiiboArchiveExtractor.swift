import Foundation

#if canImport(ZIPFoundation)
import ZIPFoundation
#endif

nonisolated enum AmiiboArchiveExtractionError: LocalizedError {
    case zipFoundationUnavailable
    case repositoryRootNotFound

    var errorDescription: String? {
        switch self {
        case .zipFoundationUnavailable:
            "ZIPFoundation must be added to the app target before AmiiboDB archives can be extracted."
        case .repositoryRootNotFound:
            "The extracted archive does not contain an Amiibo Bin directory."
        }
    }
}

nonisolated enum AmiiboArchiveExtractor {
    static var isAvailable: Bool {
        #if canImport(ZIPFoundation)
        true
        #else
        false
        #endif
    }

    static func extract(
        archiveURL: URL,
        to destinationURL: URL,
        fileManager: FileManager = .default
    ) throws -> URL {
        try fileManager.createDirectory(at: destinationURL, withIntermediateDirectories: true)

        #if canImport(ZIPFoundation)
        try fileManager.unzipItem(at: archiveURL, to: destinationURL)
        return try repositoryRoot(in: destinationURL, fileManager: fileManager)
        #else
        throw AmiiboArchiveExtractionError.zipFoundationUnavailable
        #endif
    }

    private static func repositoryRoot(
        in destinationURL: URL,
        fileManager: FileManager
    ) throws -> URL {
        if containsAmiiboBin(destinationURL, fileManager: fileManager) {
            return destinationURL
        }

        let children = try fileManager.contentsOfDirectory(
            at: destinationURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        for child in children {
            let values = try child.resourceValues(forKeys: [.isDirectoryKey])
            if values.isDirectory == true, containsAmiiboBin(child, fileManager: fileManager) {
                return child
            }
        }

        throw AmiiboArchiveExtractionError.repositoryRootNotFound
    }

    private static func containsAmiiboBin(_ root: URL, fileManager: FileManager) -> Bool {
        var isDirectory: ObjCBool = false
        let binDirectory = root.appending(path: "Amiibo Bin", directoryHint: .isDirectory)
        return fileManager.fileExists(atPath: binDirectory.path, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }
}
