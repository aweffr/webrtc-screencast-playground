import CryptoKit
import Foundation

struct DiagnosticManifest: Codable, Equatable, Sendable {
    struct FileEntry: Codable, Equatable, Sendable {
        let path: String
        let sha256: String
        let bytes: UInt64
    }

    let schemaVersion: Int
    let files: [FileEntry]

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case files
    }
}

struct DiagnosticExportResult: Equatable, Sendable {
    let archiveURL: URL
    let manifest: DiagnosticManifest
}

enum DiagnosticExporterError: Error, Equatable {
    case invalidSecret
    case secretFound(path: String)
    case archiveFailed(Int32)
}

enum DiagnosticExporter {
    static func export(
        sessionDirectory: URL,
        outputURL: URL,
        forbiddenSecrets: [String],
        fileManager: FileManager = .default
    ) async throws -> DiagnosticExportResult {
        let secrets = forbiddenSecrets.filter { !$0.isEmpty }
        guard secrets.count == forbiddenSecrets.count else { throw DiagnosticExporterError.invalidSecret }
        let files = try regularFiles(in: sessionDirectory, fileManager: fileManager)
        for file in files {
            let data = try Data(contentsOf: file)
            for secret in secrets where data.range(of: Data(secret.utf8)) != nil {
                throw DiagnosticExporterError.secretFound(path: relativePath(file, under: sessionDirectory))
            }
        }

        let entries = try files.map { file -> DiagnosticManifest.FileEntry in
            let data = try Data(contentsOf: file)
            return DiagnosticManifest.FileEntry(
                path: relativePath(file, under: sessionDirectory),
                sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(),
                bytes: UInt64(data.count)
            )
        }.sorted { $0.path < $1.path }
        let manifest = DiagnosticManifest(schemaVersion: 1, files: entries)

        let stagingRoot = fileManager.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let stagedSession = stagingRoot.appending(path: sessionDirectory.lastPathComponent, directoryHint: .isDirectory)
        try fileManager.createDirectory(at: stagingRoot, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: stagingRoot) }
        try fileManager.copyItem(at: sessionDirectory, to: stagedSession)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(manifest).write(to: stagedSession.appending(path: "manifest.json"), options: .atomic)

        if fileManager.fileExists(atPath: outputURL.path) { try fileManager.removeItem(at: outputURL) }
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/ditto")
        process.arguments = ["-c", "-k", "--keepParent", stagedSession.path, outputURL.path]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw DiagnosticExporterError.archiveFailed(process.terminationStatus)
        }
        return DiagnosticExportResult(archiveURL: outputURL, manifest: manifest)
    }

    private static func regularFiles(in directory: URL, fileManager: FileManager) throws -> [URL] {
        guard let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        return try enumerator.compactMap { item -> URL? in
            guard let url = item as? URL,
                  try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { return nil }
            return url
        }
    }

    private static func relativePath(_ file: URL, under directory: URL) -> String {
        let filePath = file.standardizedFileURL.path
        let directoryPath = directory.standardizedFileURL.path
        return String(filePath.dropFirst(directoryPath.count))
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }
}
