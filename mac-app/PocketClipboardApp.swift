import Cocoa
import UserNotifications

private struct SessionResponse: Decodable { let code: String }
private struct ImagePayload: Decodable { let mime: String; let data: String; let size: Int; let at: Int64; let hostedStatus: String?; let hostedUrl: String?; let hostedError: String? }
private struct LatestResponse: Decodable { let image: ImagePayload? }

final class AppDelegate: NSObject, NSApplicationDelegate {
    let origin = "https://hw.emptydust.com/pocket"
    var code = ""
    var currentStatus = "正在创建配对码…"
    var latestHostedUrl: String?
    private var latestHostedStatus: String?
    private var statusItem: NSStatusItem!
    private var window: NSWindow?
    private var timer: Timer?
    private var lastImageAt: Int64 = 0
    private var requestInFlight = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "PC"
        statusItem.menu = makeMenu()
        NSApp.mainMenu = makeApplicationMenu()
        requestNotificationPermission()
        createSession()
        enableLaunchAtLogin()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showWindow()
        return true
    }

    func applicationWillTerminate(_ notification: Notification) { timer?.invalidate() }

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()
        let codeItem = NSMenuItem(title: "配对码：生成中…", action: nil, keyEquivalent: "")
        codeItem.tag = 1; menu.addItem(codeItem)
        let statusItem = NSMenuItem(title: currentStatus, action: nil, keyEquivalent: "")
        statusItem.tag = 2; menu.addItem(statusItem)
        menu.addItem(.separator())
        let openItem = NSMenuItem(title: "打开接收窗口", action: #selector(showWindow), keyEquivalent: "o")
        openItem.target = self; menu.addItem(openItem)
        let newItem = NSMenuItem(title: "刷新配对码", action: #selector(refreshCode), keyEquivalent: "n")
        newItem.target = self; menu.addItem(newItem)
        let copyLinkItem = NSMenuItem(title: "复制最近图床链接", action: #selector(copyHostedURL), keyEquivalent: "l")
        copyLinkItem.target = self; menu.addItem(copyLinkItem)
        menu.addItem(.separator())
        let quitItem = NSMenuItem(title: "退出", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self; menu.addItem(quitItem)
        return menu
    }

    private func makeApplicationMenu() -> NSMenu {
        let mainMenu = NSMenu()
        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()
        let refreshItem = NSMenuItem(title: "刷新配对码", action: #selector(refreshCode), keyEquivalent: "n")
        refreshItem.target = self; appMenu.addItem(refreshItem)
        let openItem = NSMenuItem(title: "打开接收窗口", action: #selector(showWindow), keyEquivalent: "o")
        openItem.target = self; appMenu.addItem(openItem)
        appMenu.addItem(.separator())
        let quitItem = NSMenuItem(title: "退出 Pocket Clipboard", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self; appMenu.addItem(quitItem)
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)
        return mainMenu
    }

    private func updateMenu() {
        guard let items = statusItem.menu?.items else { return }
        items.first(where: { $0.tag == 1 })?.title = code.isEmpty ? "配对码：生成中…" : "配对码：\(code)"
        items.first(where: { $0.tag == 2 })?.title = currentStatus
    }

    @objc private func showWindow() {
        if window == nil {
            let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 430, height: 300), styleMask: [.titled, .closable], backing: .buffered, defer: false)
            panel.title = "Pocket Clipboard"
            panel.contentView = ReceiverView(delegate: self)
            panel.center(); window = panel
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc func refreshCode() { createSession() }
    @objc func copyHostedURL() {
        guard let latestHostedUrl else { currentStatus = "还没有可复制的图床链接"; updateMenu(); return }
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(latestHostedUrl, forType: .string)
        currentStatus = "已复制图床链接"; updateMenu()
    }
    @objc private func quit() { NSApp.terminate(nil) }

    private func createSession() {
        timer?.invalidate()
        code = ""
        lastImageAt = 0
        latestHostedUrl = nil
        latestHostedStatus = nil
        currentStatus = "正在创建配对码…"; updateMenu()
        var request = URLRequest(url: URL(string: "\(origin)/api/session")!)
        request.httpMethod = "POST"
        URLSession.shared.dataTask(with: request) { [weak self] data, _, error in
            DispatchQueue.main.async {
                guard let self else { return }
                guard let data, error == nil, let response = try? JSONDecoder().decode(SessionResponse.self, from: data) else {
                    self.currentStatus = "服务连接失败"; self.updateMenu(); return
                }
                self.code = response.code; self.currentStatus = "等待手机发送"; self.updateMenu(); self.showWindow()
                self.timer?.invalidate()
                self.timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.poll() }
                self.poll()
            }
        }.resume()
    }

    private func poll() {
        guard !code.isEmpty, !requestInFlight else { return }
        requestInFlight = true
        let url = URL(string: "\(origin)/api/room/\(code)/latest")!
        URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
            DispatchQueue.main.async {
                guard let self else { return }; self.requestInFlight = false
                guard let data, let response = try? JSONDecoder().decode(LatestResponse.self, from: data), let image = response.image else { return }
                if image.at > self.lastImageAt {
                    self.lastImageAt = image.at; self.copy(image)
                } else if image.hostedStatus != self.latestHostedStatus {
                    self.latestHostedStatus = image.hostedStatus
                    self.latestHostedUrl = image.hostedUrl
                    self.currentStatus = image.hostedStatus == "completed" ? "已复制 · 图床归档完成" : (image.hostedStatus == "failed" ? "已复制 · 图床归档失败" : "已复制 · 图床归档中…")
                    self.updateMenu()
                }
            }
        }.resume()
    }

    private func copy(_ image: ImagePayload) {
        guard let raw = Data(base64Encoded: image.data), let nsImage = NSImage(data: raw) else { currentStatus = "图片解析失败"; updateMenu(); return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents(); pasteboard.writeObjects([nsImage])
        latestHostedUrl = image.hostedUrl
        latestHostedStatus = image.hostedStatus
        currentStatus = statusText(for: image); updateMenu()
        sendNotification(size: image.size)
    }

    private func statusText(for image: ImagePayload) -> String {
        switch image.hostedStatus {
        case "completed": return "已自动复制 · 图床归档完成"
        case "pending": return "已自动复制 · 图床归档中…"
        case "failed": return "已自动复制 · 图床归档失败"
        default: return "已自动复制 · \(formatSize(image.size))"
        }
    }

    private func requestNotificationPermission() {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { [weak self] granted, error in
            guard granted, error == nil else {
                DispatchQueue.main.async { self?.currentStatus = "等待手机发送（通知未授权）"; self?.updateMenu() }
                return
            }
            self?.sendTestNotification()
        }
    }

    private func sendTestNotification() {
        let content = UNMutableNotificationContent()
        content.title = "Pocket Clipboard"
        content.body = "通知已开启，收到图片后会自动提示"
        content.sound = .default
        let request = UNNotificationRequest(identifier: "pocket-clipboard-ready", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    private func sendNotification(size: Int) {
        let content = UNMutableNotificationContent()
        content.title = "Pocket Clipboard"
        content.body = "已接收图片并写入剪贴板 · \(formatSize(size))"
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    private func formatSize(_ bytes: Int) -> String { bytes > 1024 * 1024 ? String(format: "%.1f MB", Double(bytes) / 1048576) : "\(bytes / 1024) KB" }

    private func enableLaunchAtLogin() {
        let directory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let plist = directory.appendingPathComponent("com.emptydust.pocketclipboard.plist")
        guard let executable = Bundle.main.executablePath else { return }
        let content = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict><key>Label</key><string>com.emptydust.pocketclipboard</string><key>ProgramArguments</key><array><string>\(executable)</string></array><key>RunAtLoad</key><true/><key>KeepAlive</key><true/></dict></plist>
        """
        try? content.write(to: plist, atomically: true, encoding: .utf8)
    }
}

final class ReceiverView: NSView {
    weak var delegate: AppDelegate?
    private let codeLabel = NSTextField(labelWithString: "生成中…")
    private let statusLabel = NSTextField(labelWithString: "正在连接服务")
    private let refreshCodeButton = NSButton(title: "刷新配对码", target: nil, action: nil)
    private let linkLabel = NSTextField(labelWithString: "图床链接将在归档完成后出现")
    private let copyLinkButton = NSButton(title: "复制图床链接", target: nil, action: nil)

    init(delegate: AppDelegate) {
        self.delegate = delegate; super.init(frame: .zero); wantsLayer = true
        codeLabel.font = .systemFont(ofSize: 42, weight: .bold); codeLabel.alignment = .center; codeLabel.textColor = .systemOrange
        statusLabel.alignment = .center; statusLabel.textColor = .secondaryLabelColor
        refreshCodeButton.target = delegate; refreshCodeButton.action = #selector(AppDelegate.refreshCode)
        linkLabel.alignment = .center; linkLabel.textColor = .secondaryLabelColor; linkLabel.lineBreakMode = .byTruncatingMiddle
        copyLinkButton.target = delegate; copyLinkButton.action = #selector(AppDelegate.copyHostedURL); copyLinkButton.isEnabled = false
        let title = NSTextField(labelWithString: "Pocket Clipboard"); title.font = .systemFont(ofSize: 20, weight: .semibold); title.alignment = .center
        let stack = NSStackView(views: [title, codeLabel, statusLabel, refreshCodeButton, linkLabel, copyLinkButton]); stack.orientation = .vertical; stack.spacing = 10; stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack); NSLayoutConstraint.activate([stack.centerXAnchor.constraint(equalTo: centerXAnchor), stack.centerYAnchor.constraint(equalTo: centerYAnchor), stack.widthAnchor.constraint(equalTo: widthAnchor, constant: -40)])
        Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.refresh() }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    private func refresh() {
        guard let delegate else { return }
        codeLabel.stringValue = delegate.code.isEmpty ? "生成中…" : delegate.code
        statusLabel.stringValue = delegate.currentStatus
        linkLabel.stringValue = delegate.latestHostedUrl ?? "图床链接将在归档完成后出现"
        copyLinkButton.isEnabled = delegate.latestHostedUrl != nil
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
