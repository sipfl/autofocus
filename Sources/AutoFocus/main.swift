import AppKit
import ServiceManagement

enum Key: String, CaseIterable {
    case enabled, offOnSleep, offOnLock, overrideOthers, onShortcut, offShortcut
}

final class App: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let defaults = UserDefaults.standard
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let worker = DispatchQueue(label: "autofocus.worker")
    private var power: PowerObserver?
    private var state: FocusState = .noAccess
    private var lastMtime: Date?
    private var lastAction = "–"
    private var pendingActivate: DispatchWorkItem?
    private var userAwake = false

    private func flag(_ k: Key) -> Bool { defaults.bool(forKey: k.rawValue) }
    private func string(_ k: Key) -> String { defaults.string(forKey: k.rawValue) ?? "" }

    func applicationDidFinishLaunching(_: Notification) {
        defaults.register(defaults: [
            Key.enabled.rawValue: true, Key.offOnSleep.rawValue: true, Key.offOnLock.rawValue: false,
            Key.overrideOthers.rawValue: false,
            Key.onShortcut.rawValue: "AutoFocus Work On", Key.offShortcut.rawValue: "AutoFocus Work Off",
        ])
        item.menu = NSMenu()
        item.menu?.delegate = self
        refresh(force: true)
        Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.refresh() }

        let ws = NSWorkspace.shared.notificationCenter
        ws.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { [weak self] _ in self?.userWake("screens woke") }
        ws.addObserver(forName: NSWorkspace.sessionDidBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in self?.userWake("session active") }
        let dnc = DistributedNotificationCenter.default()
        dnc.addObserver(forName: .init("com.apple.screenIsUnlocked"), object: nil, queue: .main) { [weak self] _ in self?.userWake("unlocked") }
        dnc.addObserver(forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
            guard let self, self.flag(.offOnLock) else { return }
            self.pendingActivate?.cancel()
            self.deactivate(reason: "locked") {}
        }
        power = PowerObserver { [weak self] allow in
            guard let self, self.flag(.offOnSleep) else { return allow() }
            guard self.userAwake else {
                log.info("sleep after dark wake, focus untouched")
                return allow()
            }
            self.userAwake = false
            self.pendingActivate?.cancel()
            self.deactivate(reason: "sleep") {
                Thread.sleep(forTimeInterval: 2)
                allow()
            }
        }
        userWake("launch", delay: 0)
    }

    private func userWake(_ reason: String, delay: TimeInterval = 3) {
        userAwake = true
        activate(reason: reason, delay: delay)
    }

    private func activate(reason: String, delay: TimeInterval = 3) {
        guard flag(.enabled) else { return }
        pendingActivate?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let s = FocusReader.read()
            if s.isWork { return }
            if case .active = s, !self.flag(.overrideOthers) {
                log.info("skip activate (\(reason, privacy: .public)): \(s.label, privacy: .public) active")
                return
            }
            log.info("activate: \(reason, privacy: .public)")
            let ok = Shortcuts.run(self.string(.onShortcut))
            DispatchQueue.main.async { self.note("Work an (\(reason))", ok) }
        }
        pendingActivate = work
        worker.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func deactivate(reason: String, force: Bool = false, then: @escaping () -> Void) {
        worker.async { [weak self] in
            guard let self else { return then() }
            let s = FocusReader.read()
            guard force || (self.flag(.enabled) && (s.isWork || s == .noAccess)) else { return then() }
            log.info("deactivate: \(reason, privacy: .public)")
            let ok = Shortcuts.run(self.string(.offShortcut))
            DispatchQueue.main.async { self.note("Work aus (\(reason))", ok) }
            then()
        }
    }

    private func note(_ text: String, _ ok: Bool) {
        let t = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .short)
        lastAction = "\(t) \(text)\(ok ? "" : " FEHLER")"
        refresh(force: true)
    }

    private func refresh(force: Bool = false) {
        let m = FocusReader.mtime()
        guard force || m != lastMtime else { return }
        lastMtime = m
        let new = FocusReader.read()
        if new != state { log.info("focus state: \(new.label, privacy: .public)") }
        state = new
        let symbol: String
        switch state {
        case .noAccess: symbol = "exclamationmark.triangle"
        case .off: symbol = "circle.dashed"
        case let .active(_, _, s): symbol = s
        }
        let img = NSImage(systemSymbolName: symbol, accessibilityDescription: state.label)
            ?? NSImage(systemSymbolName: "moon.fill", accessibilityDescription: state.label)
        img?.isTemplate = true
        item.button?.image = img
        item.button?.appearsDisabled = !flag(.enabled)
        item.button?.toolTip = "Focus: \(state.label)"
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        refresh(force: true)
        menu.removeAllItems()
        let header = NSMenuItem(title: "Focus: \(state.label)", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        let last = NSMenuItem(title: "Letzte Aktion: \(lastAction)", action: nil, keyEquivalent: "")
        last.isEnabled = false
        menu.addItem(last)
        menu.addItem(.separator())
        for (k, title) in [(Key.enabled, "Automatik aktiv"), (.offOnSleep, "Bei Ruhezustand ausschalten"),
                           (.offOnLock, "Bei Bildschirmsperre ausschalten"), (.overrideOthers, "Andere Focus Modes überschreiben")] {
            let mi = NSMenuItem(title: title, action: #selector(toggle(_:)), keyEquivalent: "")
            mi.representedObject = k.rawValue
            mi.state = flag(k) ? .on : .off
            menu.addItem(mi)
        }
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Work jetzt einschalten", action: #selector(manualOn), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Work jetzt ausschalten", action: #selector(manualOff), keyEquivalent: ""))
        menu.addItem(.separator())
        let login = NSMenuItem(title: "Beim Login starten", action: #selector(toggleLogin), keyEquivalent: "")
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)
        if state == .noAccess {
            menu.addItem(NSMenuItem(title: "Festplattenvollzugriff erteilen…", action: #selector(openFDA), keyEquivalent: ""))
        }
        menu.addItem(NSMenuItem(title: "Beenden", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        menu.items.forEach { if $0.action != nil && $0.target == nil && $0.action != #selector(NSApplication.terminate(_:)) { $0.target = self } }
    }

    @objc private func toggle(_ sender: NSMenuItem) {
        guard let k = sender.representedObject as? String else { return }
        defaults.set(!defaults.bool(forKey: k), forKey: k)
        refresh(force: true)
        if k == Key.enabled.rawValue || k == Key.overrideOthers.rawValue { activate(reason: "setting", delay: 0) }
    }

    @objc private func manualOn() {
        worker.async { [weak self] in
            guard let self else { return }
            let ok = Shortcuts.run(self.string(.onShortcut))
            DispatchQueue.main.async { self.note("Work an (manuell)", ok) }
        }
    }

    @objc private func manualOff() { deactivate(reason: "manuell", force: true) {} }

    @objc private func toggleLogin() {
        let svc = SMAppService.mainApp
        do { svc.status == .enabled ? try svc.unregister() : try svc.register() } catch {
            log.error("login item: \(error.localizedDescription, privacy: .public)")
            if svc.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
        }
    }

    @objc private func openFDA() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!)
    }
}

let app = NSApplication.shared
let delegate = App()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
