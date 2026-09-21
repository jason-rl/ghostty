import Cocoa
import CryptoKit

/// Unsigned fork releases deliberately do not use Sparkle's installation machinery.
final class ForkUpdater {
    let viewModel: UpdateViewModel
    var automaticallyChecksForUpdates = true
    var automaticallyDownloadsUpdates = false
    private var task: Task<Void, Never>?
    private var timer: Timer?
    private var staged: URL?
    private var stagedCommit: String?
    private var relaunch = false
    private var generation = 0

    init(viewModel: UpdateViewModel) { self.viewModel = viewModel }
    deinit { task?.cancel(); timer?.invalidate() }
    var canCheck: Bool { task == nil }

    func start() {
        guard timer == nil else { return }
        cleanupInstallation()
        timer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
            guard let self, self.automaticallyChecksForUpdates, self.canCheck else { return }
            self.check(manual: false)
        }
        if automaticallyChecksForUpdates { check(manual: false) }
    }

    func cancel() {
        generation += 1
        task?.cancel()
        task = nil
        viewModel.state = .idle
    }

    private func fail(_ error: Error) {
        viewModel.state = .error(.init(error: error, retry: { [weak self] in self?.check() },
                                      dismiss: { [weak self] in self?.viewModel.state = .idle }))
    }

    func check(manual: Bool = true) {
        cancel()
        let current = generation
        viewModel.state = .checking(.init(cancel: { [weak self] in self?.cancel() }))
        task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { if self.generation == current { self.task = nil } }
            do {
                #if !arch(arm64)
                throw ForkRelease.Failure.unsupported
                #endif
                let data = try await Self.fetch(ForkRelease.endpoint)
                let release = try JSONDecoder().decode(ForkRelease.self, from: data)
                let info = Bundle.main.infoDictionary ?? [:]
                let needed = try release.shouldUpdate(
                    version: info["CFBundleShortVersionString"] as? String ?? "",
                    commit: info["GhosttyCommit"] as? String, stagedCommit: stagedCommit)
                try Task.checkCancellation()
                guard generation == current else { return }
                guard needed else {
                    viewModel.state = manual ? .notFound(.init(acknowledgement: { [weak self] in
                        self?.viewModel.state = .idle
                    })) : .idle
                    return
                }
                let manifestData = try await Self.fetch(release.asset("fork-release.json"))
                let manifest = try JSONDecoder().decode(ForkRelease.Manifest.self, from: manifestData)
                try release.validate(manifest)
                _ = try release.asset(ForkRelease.assetName)
                try Task.checkCancellation()
                guard generation == current else { return }
                if !manual && automaticallyDownloadsUpdates {
                    download(release, manifest: manifest)
                } else {
                    viewModel.state = .updateAvailable(.init(
                        forkVersion: release.version,
                        reply: { [weak self] choice in
                            DispatchQueue.main.async {
                                if choice == .install { self?.download(release, manifest: manifest) } else { self?.viewModel.state = .idle }
                            }
                        }))
                }
            } catch is CancellationError { } catch {
                if generation == current { fail(error) }
            }
        }
    }

    private static func fetch(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.timeoutInterval = 45
        request.setValue("Ghostty-Fork-Updater", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse, response.statusCode == 200,
              data.count <= 4 * 1024 * 1024 else { throw ForkRelease.Failure.invalidRelease }
        return data
    }

    private func download(_ release: ForkRelease, manifest: ForkRelease.Manifest) {
        cancel()
        let current = generation
        viewModel.state = .downloading(.init(cancel: { [weak self] in self?.cancel() },
                                             expectedLength: nil, progress: 0))
        task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { if generation == current { task = nil } }
            do {
                let url = try release.asset(ForkRelease.assetName)
                let progress = ForkDownloadProgress { [weak self] received, expected in
                    DispatchQueue.main.async {
                        guard let self, self.generation == current else { return }
                        self.viewModel.state = .downloading(.init(cancel: { [weak self] in self?.cancel() },
                            expectedLength: expected > 0 ? UInt64(expected) : nil,
                            progress: UInt64(max(0, received))))
                    }
                }
                let configuration = URLSessionConfiguration.ephemeral
                configuration.timeoutIntervalForRequest = 45
                configuration.timeoutIntervalForResource = 1800
                let session = URLSession(configuration: configuration)
                defer { session.invalidateAndCancel() }
                let (temporary, response) = try await session.download(from: url, delegate: progress)
                defer { try? FileManager.default.removeItem(at: temporary) }
                guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                    throw ForkRelease.Failure.invalidDownload
                }
                try Task.checkCancellation()
                guard generation == current else { return }
                viewModel.state = .extracting(.init(progress: 0))
                let app = Bundle.main.bundleURL
                let bundleID = Bundle.main.bundleIdentifier
                let preparation = Task.detached(priority: .utility) {
                    try Self.prepare(temporary, manifest: manifest, destination: app, bundleID: bundleID)
                }
                let prepared = try await preparation.value
                if Task.isCancelled || generation != current {
                    try? FileManager.default.removeItem(at: prepared)
                    return
                }
                if let old = staged { try? FileManager.default.removeItem(at: old) }
                staged = prepared
                stagedCommit = manifest.commit
                viewModel.state = .installing(.init(isAutoUpdate: true,
                    retryTerminatingApplication: { [weak self] in self?.install() },
                    dismiss: { [weak self] in self?.viewModel.state = .idle }))
            } catch is CancellationError { } catch {
                if generation == current { fail(error) }
            }
        }
    }

    func install() {
        guard staged != nil else { viewModel.state.confirm(); return }
        relaunch = true
        NSApp.invalidateRestorableState()
        NSApp.windows.forEach { $0.invalidateRestorableState() }
        NSApp.terminate(nil)
    }

    /// Called from applicationWillTerminate, after any terminal-session quit confirmation.
    func willTerminate() {
        guard let staged, let helper = Bundle.main.url(forResource: "fork-update", withExtension: "sh") else { return }
        let destination = Bundle.main.bundleURL
        let backup = destination.deletingLastPathComponent()
            .appendingPathComponent(".Ghostty-backup-\(UUID().uuidString).app")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [helper.path, String(ProcessInfo.processInfo.processIdentifier),
                             staged.path, destination.path, backup.path, relaunch ? "yes" : "no"]
        do {
            UserDefaults.standard.set(["destination": destination.path, "backup": backup.path,
                                       "staged": staged.path, "commit": stagedCommit ?? ""],
                                      forKey: "GhosttyForkPendingInstallation")
            try process.run()
        } catch {
            UserDefaults.standard.removeObject(forKey: "GhosttyForkPendingInstallation")
            NSLog("Unable to start fork update installer: %@", error.localizedDescription)
        }
    }

    private func cleanupInstallation() {
        let defaults = UserDefaults.standard
        guard let receipt = defaults.dictionary(forKey: "GhosttyForkPendingInstallation") as? [String: String],
              receipt["destination"] == Bundle.main.bundleURL.path else { return }
        defaults.removeObject(forKey: "GhosttyForkPendingInstallation")
        let parent = Bundle.main.bundleURL.deletingLastPathComponent().standardizedFileURL
        let installed = Bundle.main.infoDictionary?["GhosttyCommit"] as? String == receipt["commit"]
        for key in installed ? ["backup", "staged"] : ["staged"] {
            guard let path = receipt[key] else { continue }
            let url = URL(fileURLWithPath: path).standardizedFileURL
            let prefix = key == "backup" ? ".Ghostty-backup-" : ".Ghostty-update-"
            guard url.deletingLastPathComponent() == parent, url.lastPathComponent.hasPrefix(prefix),
                  url.pathExtension == "app" else { continue }
            try? FileManager.default.removeItem(at: url)
        }
        if !installed {
            DispatchQueue.main.async { [weak self] in self?.fail(ForkRelease.Failure.installationFailed) }
        }
    }

    private static func command(_ executable: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        let deadline = Date().addingTimeInterval(120)
        while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
            process.waitUntilExit()
            throw ForkRelease.Failure.commandFailed(executable)
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw ForkRelease.Failure.commandFailed(executable) }
    }

    private static func prepare(_ download: URL, manifest: ForkRelease.Manifest,
                                destination: URL, bundleID: String?) throws -> URL {
        let manager = FileManager.default
        let parent = destination.deletingLastPathComponent()
        guard manager.isWritableFile(atPath: parent.path), manager.isWritableFile(atPath: destination.path) else {
            throw ForkRelease.Failure.notWritable
        }
        let handle = try FileHandle(forReadingFrom: download)
        defer { try? handle.close() }
        var hash = SHA256()
        while let chunk = try handle.read(upToCount: 1024 * 1024), !chunk.isEmpty { hash.update(data: chunk) }
        guard hash.finalize().map({ String(format: "%02x", $0) }).joined() == manifest.sha256 else {
            throw ForkRelease.Failure.invalidDownload
        }
        let mount = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try manager.createDirectory(at: mount, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: mount) }
        try command("/usr/bin/hdiutil", ["attach", "-readonly", "-nobrowse", "-mountpoint", mount.path, download.path])
        defer { try? command("/usr/bin/hdiutil", ["detach", mount.path]) }
        let source = mount.appendingPathComponent("Ghostty.app")
        guard let bundle = Bundle(url: source), bundle.bundleIdentifier == bundleID,
              bundle.infoDictionary?["GhosttyCommit"] as? String == manifest.commit,
              bundle.infoDictionary?["CFBundleShortVersionString"] as? String == manifest.version,
              bundle.infoDictionary?["CFBundleVersion"] as? String == manifest.build else {
            throw ForkRelease.Failure.invalidDownload
        }
        try command("/usr/bin/lipo", ["-verify_arch", "arm64", source.appendingPathComponent("Contents/MacOS/ghostty").path])
        try command("/usr/bin/codesign", ["--verify", "--deep", "--strict", source.path])
        let staged = parent.appendingPathComponent(".Ghostty-update-\(UUID().uuidString).app")
        do {
            try command("/usr/bin/ditto", [source.path, staged.path])
            return staged
        } catch {
            try? manager.removeItem(at: staged)
            throw error
        }
    }
}

private final class ForkDownloadProgress: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let progress: @Sendable (Int64, Int64) -> Void
    init(_ progress: @escaping @Sendable (Int64, Int64) -> Void) { self.progress = progress }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        progress(totalBytesWritten, totalBytesExpectedToWrite)
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {}
}
