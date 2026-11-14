import AppKit
import Core
import Sparkle

@MainActor
final class UpdatesController: NSObject, SPUUpdaterDelegate {
    private let checker: ReleaseChecker
    private lazy var updates = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self, userDriverDelegate: nil)
    var beforeInstall: (() async -> Bool)?
    private(set) var installsOnQuit = false
    private var pendingInstall: (() -> Void)?
    private var attemptingInstall = false
    private let panel: NSWindow
    private let status = NSTextField(wrappingLabelWithString: "Henüz kontrol edilmedi.")
    private let engine = NSTextField(wrappingLabelWithString: "Üretim motoru yükleniyor…")
    private let notes = NSTextField(wrappingLabelWithString: "")
    private let timestamp = NSTextField(labelWithString: "")
    private let install = NSButton(title: "Güncelle", target: nil, action: nil)
    private let automatic = NSButton(checkboxWithTitle: "Günlük güncellemeleri otomatik denetle", target: nil, action: nil)
    private var timer: Timer?
    private var checking = false
    private let configured: Bool

    override init() {
        let cache = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AssetFurnace/update-check.json")
        checker = ReleaseChecker(cacheURL: cache)
        configured = (Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String)?.isEmpty == false
            && (Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String)?.hasPrefix("https://") == true
        panel = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 440),
                         styleMask: [.titled, .closable], backing: .buffered, defer: false)
        super.init()
        panel.title = "Güncellemeler"
        panel.isReleasedWhenClosed = false
        panel.center()
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "geliştirme"
        let app = NSTextField(labelWithString: "Uygulama — Yüklü sürüm: \(version)")
        app.font = .boldSystemFont(ofSize: 14)
        engine.font = .boldSystemFont(ofSize: 14)
        notes.maximumNumberOfLines = 3
        status.maximumNumberOfLines = 3
        status.textColor = .secondaryLabelColor
        timestamp.textColor = .secondaryLabelColor
        automatic.state = UserDefaults.standard.object(forKey: "dailyUpdates") as? Bool == false ? .off : .on
        automatic.target = self
        automatic.action = #selector(changeAutomatic)
        let checkButton = NSButton(title: "Şimdi Kontrol Et", target: self, action: #selector(manualCheck))
        let close = NSButton(title: "Daha Sonra", target: self, action: #selector(closePanel))
        install.target = self
        install.action = #selector(installUpdate)
        install.isEnabled = configured
        let buttons = NSStackView(views: [checkButton, close, install])
        buttons.distribution = .fillEqually
        let stack = NSStackView(views: [app, engine, notes, status, automatic, timestamp, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        guard let content = panel.contentView else { return }
        content.addSubview(stack)
        NSLayoutConstraint.activate([engine, notes, status, timestamp].map {
            $0.widthAnchor.constraint(equalTo: stack.widthAnchor)
        })
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 24),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -24),
            buttons.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
        if configured {
            updates.updater.automaticallyDownloadsUpdates = false
            updates.updater.automaticallyChecksForUpdates = automatic.state == .on
            updates.updater.updateCheckInterval = 86_400
            updates.startUpdater()
        }
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.check(manual: false) }
        }
        Task { await check(manual: false) }
    }

    @objc func showUpdates() {
        panel.makeKeyAndOrderFront(nil)
        Task { await check(manual: true) }
    }
    @objc private func closePanel() { panel.close() }
    @objc private func manualCheck() {
        Task {
            await check(manual: true)
            if configured { updates.checkForUpdates(nil) }
        }
    }
    @objc private func changeAutomatic() {
        UserDefaults.standard.set(automatic.state == .on, forKey: "dailyUpdates")
        if configured { updates.updater.automaticallyChecksForUpdates = automatic.state == .on }
    }
    func setProgress(_ message: String) {
        status.stringValue = message
    }

    @objc private func installUpdate() {
        guard configured else {
            setProgress("Güncelleme kaynağı bu pakette yapılandırılmamış.")
            return
        }
        if pendingInstall != nil { Task { await finishPendingInstall() } }
        else { updates.checkForUpdates(nil) }
    }

    func updater(_ updater: SPUUpdater, shouldPostponeRelaunchForUpdate item: SUAppcastItem,
                 untilInvokingBlock installHandler: @escaping () -> Void) -> Bool {
        pendingInstall = installHandler
        Task { await finishPendingInstall() }
        return true
    }

    func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem,
                 immediateInstallationBlock immediateInstallHandler: @escaping () -> Void) -> Bool {
        installsOnQuit = true
        return false
    }

    private func finishPendingInstall() async {
        guard !attemptingInstall, let handler = pendingInstall else { return }
        attemptingInstall = true
        defer { attemptingInstall = false }
        guard let beforeInstall, await beforeInstall() else {
            panel.makeKeyAndOrderFront(nil)
            return
        }
        pendingInstall = nil
        handler()
    }
    private func check(manual: Bool) async {
        guard ProcessInfo.processInfo.environment["I3D_NO_UPDATE_CHECK"] != "1" else {
            status.stringValue = "Güncelleme kontrolü ortam ayarıyla kapatılmış."
            return
        }
        guard !checking, manual || automatic.state == .on else { return }
        let lastAttempt = UserDefaults.standard.object(forKey: "lastOfficialUpdateCheck") as? Double
        guard UpdateSchedule.isDue(lastCheck: lastAttempt, now: Date().timeIntervalSince1970, manual: manual) else { return }
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "lastOfficialUpdateCheck")
        checking = true
        defer { checking = false }
        do {
            let release = try await checker.check(manual: manual)
            if let release {
                notes.stringValue = String((release.body ?? "Sürüm notu bulunamadı.").prefix(650))
                status.stringValue = "Resmi sürüm: \(release.tagName). Uyumlu masaüstü paketi ayrı yayımlanır."
            }
            timestamp.stringValue = "Son kontrol: \(Date().formatted(date: .abbreviated, time: .shortened))"
        } catch {
            status.stringValue = "Kontrol başarısız. Bağlantınızı kontrol edip yeniden deneyebilirsiniz."
        }
        if let url = URL(string: "http://127.0.0.1:8777/api/update-check"),
           let (data, response) = try? await URLSession.shared.data(from: url),
           (response as? HTTPURLResponse)?.statusCode == 200,
           let state = try? JSONDecoder().decode(EngineVersion.self, from: data) {
            engine.stringValue = "Üretim motoru — Yüklü sürüm: \(state.current)"
        } else { engine.stringValue = "Üretim motoru — Sürüm okunamadı" }
    }
    private struct EngineVersion: Decodable { let current: String }
}
