import Foundation

/// The immutable identity used throughout a check, download, and installation.
struct ForkRelease: Decodable {
    struct Asset: Decodable {
        let name: String
        let browser_download_url: URL
    }
    let tag_name: String
    let target_commitish: String
    let assets: [Asset]

    struct Manifest: Codable {
        let version: String
        let commit: String
        let build: String
        let sha256: String
    }

    static let repository = "jason-rl/ghostty"
    static let endpoint = URL(string: "https://api.github.com/repos/\(repository)/releases/latest")!
    static let assetName = "Ghostty-aarch64.dmg"

    var version: String { String(tag_name.dropFirst()) }

    static func components(_ value: String) -> [Int]? {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3, parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy({ $0.isASCII && $0.isNumber }) }) else {
            return nil
        }
        let numbers = parts.compactMap { Int($0) }
        return numbers.count == 3 ? numbers : nil
    }

    static func validCommit(_ value: String) -> Bool {
        value.count == 40 && value.allSatisfy { $0.isASCII && $0.isHexDigit }
    }

    func shouldUpdate(version installed: String, commit: String?, stagedCommit: String?) throws -> Bool {
        guard tag_name.hasPrefix("v"), let remote = Self.components(version),
              let local = Self.components(installed) else { throw Failure.invalidRelease }
        if remote.lexicographicallyPrecedes(local) { return false }
        if remote != local { return target_commitish != stagedCommit }
        guard let commit, Self.validCommit(commit), Self.validCommit(target_commitish) else { return false }
        return commit.lowercased() != target_commitish.lowercased()
            && stagedCommit?.lowercased() != target_commitish.lowercased()
    }

    func asset(_ name: String) throws -> URL {
        guard let url = assets.first(where: { $0.name == name })?.browser_download_url,
              url.scheme == "https", url.host == "github.com",
              url.path.hasPrefix("/\(Self.repository)/releases/download/") else {
            throw Failure.invalidRelease
        }
        return url
    }

    func validate(_ manifest: Manifest) throws {
        guard manifest.version == version, Self.validCommit(manifest.commit),
              manifest.commit == target_commitish, manifest.sha256.count == 64,
              manifest.sha256.allSatisfy({ $0.isASCII && $0.isHexDigit }),
              UInt64(manifest.build) != nil else { throw Failure.invalidRelease }
    }

    enum Failure: LocalizedError {
        case invalidRelease, invalidDownload, unsupported, notWritable, installationFailed, commandFailed(String)
        var errorDescription: String? {
            switch self {
            case .invalidRelease: return "The fork release metadata is invalid or incomplete."
            case .installationFailed: return "The update could not be installed. Your previous Ghostty application has been retained. Try the update again."
            case .invalidDownload: return "The downloaded update did not pass verification."
            case .unsupported: return "Fork updates require an Apple Silicon release build."
            case .notWritable: return "Move Ghostty to a writable Applications folder before updating."
            case .commandFailed(let command): return "Update preparation failed: \(command)."
            }
        }
    }
}
