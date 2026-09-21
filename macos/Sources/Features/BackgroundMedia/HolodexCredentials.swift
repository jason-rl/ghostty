#if os(macOS)
import Cocoa
import Security
import GhosttyKit

/// Keychain operations run serially off the UI thread. No secret enters config or logs.
final class HolodexCredentials {
    private weak var app: Ghostty.App?
    private let queue = DispatchQueue(label: "ghostty.holodex-keychain", qos: .utility)
    private var revision = 0
    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "ghostty.background-media.holodex",
         kSecAttrAccount as String: "api-key"]
    }

    init(app: Ghostty.App) { self.app = app }

    func load() { perform(.load) }

    func present(remove: Bool) {
        let alert = NSAlert()
        alert.messageText = remove ? "Remove Holodex API Key?" : "Set Holodex API Key"
        alert.informativeText = remove
            ? "The stored key will be deleted. HOLODEX_API_KEY remains available as a fallback."
            : "The key is stored in your login Keychain and used only for Holodex requests."
        alert.addButton(withTitle: remove ? "Remove" : "Save")
        alert.addButton(withTitle: "Cancel")
        let entry = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 360, height: 24))
        if !remove { alert.accessoryView = entry }
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        if remove { perform(.remove); return }
        let key = entry.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        entry.stringValue = ""
        guard !key.isEmpty, key.utf8.count <= 4096,
              key.utf8.allSatisfy({ $0 >= 33 && $0 <= 126 }) else {
            showError("Enter a nonempty API key without spaces or control characters.")
            return
        }
        perform(.store(Data(key.utf8)))
    }

    private enum Operation { case load, store(Data), remove }

    private func perform(_ operation: Operation) {
        revision += 1
        let current = revision
        // A locked/failed keychain must never silently fall back to the environment.
        if let core = app?.app { ghostty_app_set_holodex_key(core, nil, true) }
        queue.async { [weak self] in
            var status = errSecSuccess
            switch operation {
            case .load: break
            case .store(let data):
                status = SecItemUpdate(Self.query as CFDictionary,
                                      [kSecValueData as String: data] as CFDictionary)
                if status == errSecItemNotFound {
                    var query = Self.query
                    query[kSecValueData as String] = data
                    query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
                    status = SecItemAdd(query as CFDictionary, nil)
                }
            case .remove:
                status = SecItemDelete(Self.query as CFDictionary)
                if status == errSecItemNotFound { status = errSecSuccess }
            }
            var key: String?
            if status == errSecSuccess {
                var query = Self.query
                query[kSecReturnData as String] = true
                query[kSecMatchLimit as String] = kSecMatchLimitOne
                var result: CFTypeRef?
                status = SecItemCopyMatching(query as CFDictionary, &result)
                if status == errSecSuccess {
                    key = (result as? Data).flatMap { String(data: $0, encoding: .utf8) }
                    if key == nil { status = errSecDecode }
                } else if status == errSecItemNotFound { status = errSecSuccess }
            }
            let resolvedKey = key
            let resolvedStatus = status
            DispatchQueue.main.async { [weak self] in
                guard let self, self.revision == current, let core = self.app?.app else { return }
                if let key = resolvedKey {
                    key.withCString { ghostty_app_set_holodex_key(core, $0, resolvedStatus != errSecSuccess) }
                } else {
                    ghostty_app_set_holodex_key(core, nil, resolvedStatus != errSecSuccess)
                }
                self.app?.reloadConfig(soft: true)
                if resolvedStatus != errSecSuccess {
                    switch operation {
                    case .load: Ghostty.logger.warning("Holodex Keychain unavailable (status \(resolvedStatus))")
                    default: self.showError("The Keychain operation failed (status \(resolvedStatus)). Unlock your login Keychain and try again.")
                    }
                }
            }
        }
    }

    private func showError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Holodex API Key"
        alert.informativeText = message
        alert.runModal()
    }
}
#endif
