import Foundation
import PDFKit

struct TemporaryRecoveryRecord: Codable, Equatable {
    let identifier: UUID
    let originalPath: String?
    let displayName: String
    let savedAt: Date
    let pageIndex: Int
    let zoom: Double
    let pageLayout: String
}

@MainActor
final class TemporaryRecoveryStore {
    static let shared = TemporaryRecoveryStore()

    private let directoryURL: URL
    private var reservedIdentifiers: Set<UUID> = []

    init(directoryURL: URL? = nil) {
        if let directoryURL {
            self.directoryURL = directoryURL
        } else {
            let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
            let root = caches.appendingPathComponent("zzPDF", isDirectory: true)
            let bundleIdentifier = Bundle.main.bundleIdentifier ?? "it.lucalazzaroni.zzpdf"
            self.directoryURL = root
                .appendingPathComponent(bundleIdentifier, isDirectory: true)
                .appendingPathComponent("Recovery", isDirectory: true)
            if bundleIdentifier == "it.lucalazzaroni.zzpdf" {
                Self.migrateLegacyRecoveryIfNeeded(
                    from: root.appendingPathComponent("Recovery", isDirectory: true),
                    to: self.directoryURL
                )
            }
        }
    }

    func reserve(_ identifier: UUID) {
        reservedIdentifiers.insert(identifier)
    }

    func write(
        document: PDFDocument,
        identifier: UUID,
        originalURL: URL?,
        displayName: String,
        pageIndex: Int,
        zoom: Double,
        pageLayout: PageLayoutMode
    ) -> Bool {
        do {
            try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            let pdfURL = recoveryPDFURL(for: identifier)
            guard document.write(to: pdfURL) else { return false }
            let record = TemporaryRecoveryRecord(
                identifier: identifier,
                originalPath: originalURL?.path,
                displayName: displayName,
                savedAt: Date(),
                pageIndex: max(0, pageIndex),
                zoom: max(0, zoom),
                pageLayout: pageLayout.rawValue
            )
            let data = try JSONEncoder().encode(record)
            try data.write(to: metadataURL(for: identifier), options: .atomic)
            reservedIdentifiers.insert(identifier)
            removeExpiredRecoveries()
            return true
        } catch {
            return false
        }
    }

    func discard(_ identifier: UUID) {
        try? FileManager.default.removeItem(at: recoveryPDFURL(for: identifier))
        try? FileManager.default.removeItem(at: metadataURL(for: identifier))
        reservedIdentifiers.remove(identifier)
    }

    /// Records waiting to be restored, newest first, without claiming any of them.
    func pendingRecords() -> [TemporaryRecoveryRecord] {
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: nil
        ) else { return [] }
        let decoder = JSONDecoder()
        return urls
            .filter { $0.pathExtension == "json" }
            .compactMap { url -> TemporaryRecoveryRecord? in
                guard let data = try? Data(contentsOf: url),
                      let record = try? decoder.decode(TemporaryRecoveryRecord.self, from: data),
                      !reservedIdentifiers.contains(record.identifier),
                      FileManager.default.fileExists(atPath: recoveryPDFURL(for: record.identifier).path)
                else { return nil }
                return record
            }
            .sorted { $0.savedAt > $1.savedAt }
    }

    func claimLatest() -> (TemporaryRecoveryRecord, PDFDocument)? {
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: nil
        ) else { return nil }

        let decoder = JSONDecoder()
        let records = urls
            .filter { $0.pathExtension == "json" }
            .compactMap { url -> TemporaryRecoveryRecord? in
                guard let data = try? Data(contentsOf: url),
                      let record = try? decoder.decode(TemporaryRecoveryRecord.self, from: data),
                      !reservedIdentifiers.contains(record.identifier),
                      FileManager.default.fileExists(atPath: recoveryPDFURL(for: record.identifier).path)
                else { return nil }
                return record
            }
            .sorted { $0.savedAt > $1.savedAt }

        for record in records {
            guard let document = PDFDocument(url: recoveryPDFURL(for: record.identifier)) else {
                discard(record.identifier)
                continue
            }
            reservedIdentifiers.insert(record.identifier)
            return (record, document)
        }
        return nil
    }

    private func recoveryPDFURL(for identifier: UUID) -> URL {
        directoryURL.appendingPathComponent(identifier.uuidString).appendingPathExtension("pdf")
    }

    private func metadataURL(for identifier: UUID) -> URL {
        directoryURL.appendingPathComponent(identifier.uuidString).appendingPathExtension("json")
    }

    private func removeExpiredRecoveries() {
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: nil
        ) else { return }
        let cutoff = Date().addingTimeInterval(-30 * 24 * 60 * 60)
        let decoder = JSONDecoder()
        for url in urls where url.pathExtension == "json" {
            guard let data = try? Data(contentsOf: url),
                  let record = try? decoder.decode(TemporaryRecoveryRecord.self, from: data),
                  record.savedAt < cutoff,
                  !reservedIdentifiers.contains(record.identifier)
            else { continue }
            discard(record.identifier)
        }
    }

    private static func migrateLegacyRecoveryIfNeeded(from legacyURL: URL, to destinationURL: URL) {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: legacyURL.path),
              !fileManager.fileExists(atPath: destinationURL.path)
        else { return }
        try? fileManager.createDirectory(
            at: destinationURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? fileManager.moveItem(at: legacyURL, to: destinationURL)
    }
}
