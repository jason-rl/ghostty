import Foundation
import Testing
@testable import Ghostty

struct ForkReleaseTests {
    private let old = String(repeating: "a", count: 40)
    private let new = String(repeating: "b", count: 40)

    @Test func sameVersionUsesCommitIdentity() throws {
        let release = ForkRelease(tag_name: "v1.3.1", target_commitish: new, assets: [])
        #expect(try release.shouldUpdate(version: "1.3.1", commit: old, stagedCommit: nil))
        #expect(try !release.shouldUpdate(version: "1.3.1", commit: new, stagedCommit: nil))
        #expect(try !release.shouldUpdate(version: "1.3.1", commit: old, stagedCommit: new))
        #expect(try !release.shouldUpdate(version: "1.3.1", commit: nil, stagedCommit: nil))
        #expect(try !release.shouldUpdate(version: "1.4.0", commit: old, stagedCommit: nil))
        #expect(try release.shouldUpdate(version: "1.2.0", commit: nil, stagedCommit: nil))
    }

    @Test func versionAndReleaseValidation() throws {
        #expect(ForkRelease.components("1.3.1") == [1, 3, 1])
        #expect(ForkRelease.components("1.3") == nil)
        #expect(ForkRelease.components("1.3.1-dev") == nil)
        let release = ForkRelease(tag_name: "v1.3.1", target_commitish: new, assets: [])
        try release.validate(.init(version: "1.3.1", commit: new, build: "100", sha256: String(repeating: "a", count: 64)))
        #expect(throws: ForkRelease.Failure.self) {
            try release.validate(.init(version: "1.3.1", commit: old, build: "100", sha256: String(repeating: "a", count: 64)))
        }
    }

    @Test func rejectsForeignAssets() {
        let release = ForkRelease(tag_name: "v1.3.1", target_commitish: new, assets: [
            .init(name: ForkRelease.assetName, browser_download_url: URL(string: "https://github.com/other/repo/releases/download/v1.3.1/Ghostty-aarch64.dmg")!)
        ])
        #expect(throws: ForkRelease.Failure.self) { try release.asset(ForkRelease.assetName) }
    }
}
