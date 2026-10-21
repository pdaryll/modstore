import Foundation

struct CatalogResponse: Codable, Equatable {
    let modStore: ModStoreMeta
    let apps: [ModApp]
}

struct ModStoreMeta: Codable, Equatable {
    let version: String
    let updatedAt: String
    let sizeBytes: Int64
    let changelog: String
    let manifestURL: String
}

struct ModApp: Codable, Identifiable, Hashable, Equatable {
    let id: String
    let name: String
    let bundleIdentifier: String
    let version: String
    let urlScheme: String
    let urlSchemes: [String]?
    let sizeBytes: Int64
    let updatedAt: String
    let iconURL: String
    let description: String
    let changelog: String
    let manifestURL: String

    var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .file)
    }
}

struct ProgressResponse: Codable {
    let status: String
    let progress: Double
}

enum InstallState: Equatable {
    case notInstalled
    case updateAvailable
    case awaitingConfirmation
    case downloading(progress: Double)
    case installed
}

struct ProgressResponse: Codable {
    let status: String
    let progress: Double
    let completedAgo: Double?
}