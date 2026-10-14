import AppKit

/// First-launch guide: hotkey, Screen Recording permission, relaunch. Shown once (menu → "시작 안내" re-opens it).
final class WelcomeWindowController: NSWindowController {
    static let shared = WelcomeWindowController()
    private static let shownKey = "welcomeShown"

    static func showIfFirstLaunch() {
        guard !UserDefaults.standard.bool(forKey: shownKey) else { return }
        UserDefaults.standard.set(true, forKey: shownKey)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { shared.show() }
    }

    private init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 400),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = L("ShotPark 시작하기", "Welcome to ShotPark")
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)
        buildUI()
    }
    required init?(coder: NSCoder) { fatalError() }

    func show() {
        refresh()
        NSApp.activate(ignoringOtherApps: true)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
    }

    private let hotkeyLabel = NSTextField(labelWithString: "")
    private let permState = NSTextField(labelWithString: "")

    private func buildUI() {
        guard let content = window?.contentView else { return }
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)

        let icon = NSImageView(image: NSApp.applicationIconImage)
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.widthAnchor.constraint(equalToConstant: 64).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 64).isActive = true
        let title = NSTextField(labelWithString: L("3단계면 바로 쓸 수 있습니다", "Three steps and you're set"))
        title.font = .systemFont(ofSize: 20, weight: .bold)
        let head = NSStackView(views: [icon, title]); head.spacing = 14
        stack.addArrangedSubview(head)

        func step(_ n: String, _ text: String, _ detail: NSView? = nil) -> NSView {
            let badge = NSTextField(labelWithString: n)
            badge.font = .systemFont(ofSize: 13, weight: .bold)
            badge.alignment = .center
            badge.textColor = .white
            badge.wantsLayer = true
            badge.layer?.backgroundColor = NSColor(srgbRed: 0.36, green: 0.30, blue: 0.86, alpha: 1).cgColor
            badge.layer?.cornerRadius = 13
            badge.widthAnchor.constraint(equalToConstant: 26).isActive = true
            badge.heightAnchor.constraint(equalToConstant: 26).isActive = true
            let label = NSTextField(wrappingLabelWithString: text)
            label.font = .systemFont(ofSize: 14)
            label.preferredMaxLayoutWidth = 330
            let col = NSStackView(views: [label] + (detail.map { [$0] } ?? []))
            col.orientation = .vertical; col.alignment = .leading; col.spacing = 8
            let row = NSStackView(views: [badge, col]); row.alignment = .top; row.spacing = 12
            return row
        }

        hotkeyLabel.font = .monospacedSystemFont(ofSize: 15, weight: .semibold)
        stack.addArrangedSubview(step("1", L("메뉴 막대의 카메라 아이콘이 ShotPark입니다. 어디서든 아래 단축키를 누르면 화면이 어두워지고, 드래그로 영역을 고를 수 있습니다. (설정에서 변경 가능)", "The camera icon in your menu bar is ShotPark. Press the hotkey below anywhere: the screen dims and you drag to select. (Changeable in Settings)"), hotkeyLabel))

        let permBtn = NSButton(title: L("화면 기록 권한 열기", "Open Screen Recording settings"), target: self, action: #selector(openPermission))
        permBtn.bezelStyle = .rounded
        permState.font = .systemFont(ofSize: 12)
        permState.textColor = .secondaryLabelColor
        let permRow = NSStackView(views: [permBtn, permState]); permRow.spacing = 10
        stack.addArrangedSubview(step("2", L("처음 실행하면 macOS가 화면 기록 권한을 묻습니다. 시스템 설정 목록에서 ShotPark을 켜 주세요. 캡처 내용은 어디에도 업로드되지 않습니다.", "On first launch macOS asks for Screen Recording permission. Turn ShotPark on in the System Settings list. Nothing is ever uploaded."), permRow))

        let relaunchBtn = NSButton(title: L("지금 다시 실행", "Relaunch now"), target: self, action: #selector(relaunch))
        relaunchBtn.bezelStyle = .rounded
        stack.addArrangedSubview(step("3", L("권한을 켠 뒤 앱을 한 번 다시 실행하면 그때부터 바로 캡처됩니다.", "After enabling it, relaunch the app once and captures work right away."), relaunchBtn))

        let done = NSButton(title: L("시작하기", "Get started"), target: self, action: #selector(dismiss))
        done.bezelStyle = .rounded
        done.keyEquivalent = "\r"
        let footer = NSStackView(views: [NSView(), done]); footer.distribution = .fill
        footer.widthAnchor.constraint(equalToConstant: 392).isActive = true
        stack.addArrangedSubview(footer)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 22),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -24),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -20),
        ])
    }

    private func refresh() {
        hotkeyLabel.stringValue = Settings.hotKey.display
        let ok = ScreenCapture.hasPermission()
        permState.stringValue = ok ? L("✓ 권한 있음", "✓ Granted") : L("아직 꺼져 있음", "Not granted yet")
        permState.textColor = ok ? .systemGreen : .secondaryLabelColor
    }

    @objc private func openPermission() {
        ScreenCapture.requestPermission()
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.refresh() }
    }

    @objc private func relaunch() {
        // `open -n` after a short delay, with the path passed as an argument (no shell quoting).
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "sleep 0.6; exec /usr/bin/open -n \"$0\"", Bundle.main.bundleURL.path]
        try? task.run()
        NSApp.terminate(nil)
    }

    @objc private func dismiss() { window?.close() }
}
