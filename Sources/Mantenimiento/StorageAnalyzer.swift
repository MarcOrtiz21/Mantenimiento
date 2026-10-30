import Foundation

struct StorageCategory: Identifiable, Equatable {
    enum Access: Equatable {
        case measured
        case partial
        case denied
        case missing
    }

    let id: String
    let title: String
    let detail: String
    let symbol: String
    let url: URL
    let sizeBytes: UInt64
    let access: Access
}

struct LargeFile: Identifiable, Equatable {
    var id: String { url.path }
    let url: URL
    let sizeBytes: UInt64
    let modified: Date?
}

struct StorageReport: Equatable {
    let date: Date
    let categories: [StorageCategory]
    let largeFiles: [LargeFile]
    let localSnapshotCount: Int?

    var measuredBytes: UInt64 {
        categories.filter { $0.access != .denied && $0.access != .missing }.reduce(0) { $0 + $1.sizeBytes }
    }
}

/// Solo lectura: mide carpetas que suelen acumular espacio recuperable. Nunca borra nada.
enum StorageAnalyzer {
    struct Target {
        let id: String
        let title: String
        let detail: String
        let symbol: String
        let relativePath: String
    }

    static let targets: [Target] = [
        Target(id: "caches", title: "Cachés de aplicaciones", detail: "Se regeneran solas; borrarlas libera espacio temporalmente.", symbol: "archivebox", relativePath: "Library/Caches"),
        Target(id: "downloads", title: "Descargas", detail: "Instaladores y archivos que suelen olvidarse.", symbol: "arrow.down.circle", relativePath: "Downloads"),
        Target(id: "trash", title: "Papelera", detail: "Se libera al vaciarla desde el Finder.", symbol: "trash", relativePath: ".Trash"),
        Target(id: "ios-backups", title: "Copias de iPhone y iPad", detail: "Copias locales hechas con el Finder.", symbol: "iphone", relativePath: "Library/Application Support/MobileSync/Backup"),
        Target(id: "xcode-derived", title: "Xcode: datos derivados", detail: "Compilaciones intermedias; Xcode las rehace.", symbol: "hammer", relativePath: "Library/Developer/Xcode/DerivedData"),
        Target(id: "xcode-devices", title: "Xcode: soporte de dispositivos", detail: "Símbolos de versiones antiguas de iOS.", symbol: "hammer", relativePath: "Library/Developer/Xcode/iOS DeviceSupport"),
        Target(id: "simulators", title: "Simuladores", detail: "Dispositivos del simulador de Xcode.", symbol: "ipad.and.iphone", relativePath: "Library/Developer/CoreSimulator"),
        Target(id: "logs", title: "Registros", detail: "Logs de apps y del sistema de tu usuario.", symbol: "doc.text", relativePath: "Library/Logs"),
        Target(id: "mail", title: "Adjuntos de Mail", detail: "Adjuntos abiertos desde Mail.", symbol: "envelope", relativePath: "Library/Containers/com.apple.mail/Data/Library/Mail Downloads")
    ]

    static let largeFileThreshold: UInt64 = 200 * 1_000_000

    static func analyze(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        timeLimitPerFolder: TimeInterval = 8
    ) -> StorageReport {
        let categories = targets.map { target in
            measure(target, at: home.appendingPathComponent(target.relativePath, isDirectory: true), timeLimit: timeLimitPerFolder)
        }
        let downloads = home.appendingPathComponent("Downloads", isDirectory: true)
        return StorageReport(
            date: Date(),
            categories: categories,
            largeFiles: largeFiles(in: downloads, timeLimit: timeLimitPerFolder),
            localSnapshotCount: localSnapshotCount()
        )
    }

    static func measure(_ target: Target, at url: URL, timeLimit: TimeInterval) -> StorageCategory {
        func category(_ size: UInt64, _ access: StorageCategory.Access) -> StorageCategory {
            StorageCategory(id: target.id, title: target.title, detail: target.detail, symbol: target.symbol, url: url, sizeBytes: size, access: access)
        }

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return category(0, .missing)
        }
        do {
            _ = try FileManager.default.contentsOfDirectory(atPath: url.path)
        } catch {
            return category(0, .denied)
        }

        let result = directorySize(url, timeLimit: timeLimit)
        return category(result.bytes, result.complete ? .measured : .partial)
    }

    static func directorySize(_ url: URL, timeLimit: TimeInterval) -> (bytes: UInt64, complete: Bool) {
        let keys: [URLResourceKey] = [.isRegularFileKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey]
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: keys,
            options: [],
            errorHandler: { _, _ in true }
        ) else {
            return (0, false)
        }

        let deadline = Date().addingTimeInterval(timeLimit)
        var total: UInt64 = 0
        var visited = 0
        for case let fileURL as URL in enumerator {
            visited += 1
            if visited.isMultiple(of: 500), Date() > deadline {
                return (total, false)
            }
            guard let values = try? fileURL.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else {
                continue
            }
            total += UInt64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
        }
        return (total, true)
    }

    static func largeFiles(in url: URL, timeLimit: TimeInterval, limit: Int = 8) -> [LargeFile] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .totalFileAllocatedSizeKey, .contentModificationDateKey]
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: keys,
            options: [.skipsPackageDescendants],
            errorHandler: { _, _ in true }
        ) else {
            return []
        }

        let deadline = Date().addingTimeInterval(timeLimit)
        var files: [LargeFile] = []
        var visited = 0
        for case let fileURL as URL in enumerator {
            visited += 1
            if visited.isMultiple(of: 500), Date() > deadline { break }
            guard let values = try? fileURL.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true,
                  let size = values.totalFileAllocatedSize,
                  UInt64(size) >= largeFileThreshold else {
                continue
            }
            files.append(LargeFile(url: fileURL, sizeBytes: UInt64(size), modified: values.contentModificationDate))
        }
        return Array(files.sorted { $0.sizeBytes > $1.sizeBytes }.prefix(limit))
    }

    static func localSnapshotCount() -> Int? {
        let output = ExternalCommandRunner.capture(executable: "/usr/bin/tmutil", arguments: ["listlocalsnapshots", "/"], timeout: 3)
        guard !output.isEmpty else { return nil }
        return parseSnapshotCount(output)
    }

    static func parseSnapshotCount(_ output: String) -> Int {
        output.split(separator: "\n").filter { $0.contains("com.apple.TimeMachine") }.count
    }
}
