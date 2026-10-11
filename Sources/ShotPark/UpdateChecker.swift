import AppKit

/// Lightweight update check against GitHub Releases (no Sparkle, no background daemon).
/// Checks at most once a day automatically; the menu item forces a check.
final class UpdateChecker {
    static let shared = UpdateChecker()
    static let releasesURL = URL(string: "https://github.com/chiyodad/shotpark/releases/latest")!
    private static let apiURL = URL(string: "https://api.github.com/repos/chiyodad/shotpark/releases/latest")!
    private static let lastCheckKey = "updateLastCheck"
    private static let latestKey = "updateLatestVersion"

    /// Newest version seen on GitHub that is newer than the running one, or nil.
    private(set) var availableVersion: String? {
        didSet { NotificationCenter.default.post(name: .updateAvailabilityChanged, object: nil) }
    }

    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    /// Automatic daily check (silent). Also re-surfaces a previously found version right away.
    func checkDailyIfNeeded() {
        if let v = UserDefaults.standard.string(forKey: Self.latestKey), Self.isNewer(v, than: Self.currentVersion) {
            availableVersion = v
        }
        let last = UserDefaults.standard.double(forKey: Self.lastCheckKey)
        if Date().timeIntervalSince1970 - last > 24 * 3600 { check(userInitiated: false) }
    }

    func check(userInitiated: Bool) {
        var req = URLRequest(url: Self.apiURL)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("ShotPark/\(Self.currentVersion)", forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 10
        URLSession.shared.dataTask(with: req) { data, _, error in
            var found: String? = nil
            if let data, let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let tag = obj["tag_name"] as? String {
                found = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
            }
            DispatchQueue.main.async {
                UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: Self.lastCheckKey)
                if let v = found {
                    UserDefaults.standard.set(v, forKey: Self.latestKey)
                    self.availableVersion = Self.isNewer(v, than: Self.currentVersion) ? v : nil
                }
                guard userInitiated else { return }
                let alert = NSAlert()
                if let v = found, Self.isNewer(v, than: Self.currentVersion) {
                    alert.messageText = L("ShotPark \(v) 업데이트가 있습니다", "ShotPark \(v) is available")
                    alert.informativeText = L("현재 버전은 \(Self.currentVersion)입니다. 릴리즈 페이지에서 받아 설치하거나, Homebrew라면 brew upgrade --cask shotpark 를 실행하세요.",
                                              "You're on \(Self.currentVersion). Download it from the releases page, or run brew upgrade --cask shotpark if you installed with Homebrew.")
                    alert.addButton(withTitle: L("릴리즈 페이지 열기", "Open Releases"))
                    alert.addButton(withTitle: L("나중에", "Later"))
                    NSApp.activate(ignoringOtherApps: true)
                    if alert.runModal() == .alertFirstButtonReturn { NSWorkspace.shared.open(Self.releasesURL) }
                } else if found != nil {
                    alert.messageText = L("최신 버전입니다", "You're up to date")
                    alert.informativeText = L("ShotPark \(Self.currentVersion)이 최신 버전입니다.", "ShotPark \(Self.currentVersion) is the latest version.")
                    alert.addButton(withTitle: L("확인", "OK"))
                    NSApp.activate(ignoringOtherApps: true); alert.runModal()
                } else {
                    alert.messageText = L("업데이트를 확인할 수 없습니다", "Couldn't check for updates")
                    alert.informativeText = error?.localizedDescription ?? L("네트워크 연결을 확인하고 다시 시도해 주세요.", "Check your network connection and try again.")
                    alert.addButton(withTitle: L("확인", "OK"))
                    NSApp.activate(ignoringOtherApps: true); alert.runModal()
                }
            }
        }.resume()
    }

    /// Numeric dotted-version compare: "1.10.0" > "1.9.2".
    static func isNewer(_ a: String, than b: String) -> Bool {
        let pa = a.split(separator: ".").map { Int($0) ?? 0 }, pb = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0, y = i < pb.count ? pb[i] : 0
            if x != y { return x > y }
        }
        return false
    }
}

extension Notification.Name {
    static let updateAvailabilityChanged = Notification.Name("ShotPark.updateAvailabilityChanged")
}
