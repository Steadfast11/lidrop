import AppKit
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate {
    let loginItem = NSMenuItem(title: "Launch at login", action: nil, keyEquivalent: "")
    var statusItem: NSStatusItem!
    var stateItem = NSMenuItem(title: "Disconnected", action: nil, keyEquivalent: "")
    let overlay = OverlayController()
    var server: Server!
    var macDrag: MacDrag!

    func applicationDidFinishLaunching(_ n: Notification) {
        if moveToApplications() { return }
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let ip = localIP()
        let menu = NSMenu()
        stateItem.isEnabled = false
        menu.addItem(stateItem)
        let ipItem = NSMenuItem(title: "\(ip):7777", action: nil, keyEquivalent: "")
        ipItem.isEnabled = false
        menu.addItem(ipItem)
        menu.addItem(withTitle: "Copy pairing code", action: #selector(copyPairingCode), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Open Downloads/lidrop", action: #selector(openFolder), keyEquivalent: "").target = self
        loginItem.target = self
        loginItem.action = #selector(toggleLogin)
        loginItem.isEnabled = Bundle.main.bundleURL.pathExtension == "app"   // SMAppService needs the bundle
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(loginItem)
        let lookItem = NSMenuItem(title: "Light look", action: nil, keyEquivalent: "")
        let looks = NSMenu()
        for n in LightLook.names {
            let it = NSMenuItem(title: LightLook.titles[n]!, action: #selector(pickLook(_:)), keyEquivalent: "")
            it.target = self
            it.representedObject = n
            it.state = n == LightLook.currentName ? .on : .off
            it.isEnabled = LightLook.envName == nil
            looks.addItem(it)
        }
        looks.autoenablesItems = false
        looks.addItem(.separator())
        looks.addItem(withTitle: "Preview light", action: #selector(previewLight), keyEquivalent: "").target = self
        lookItem.submenu = looks
        menu.addItem(lookItem)
        menu.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        statusItem.menu = menu
        setConnected(false)

        server = Server(overlay: overlay) { [weak self] names in self?.setPhones(names) }
        server.shelf = Shelf()
        server.start()
        macDrag = MacDrag(server: server)
        macDrag.start()
        print("lidrop listening on \(ip):7777")
        firstLaunch()
    }

    /// A freshly downloaded copy puts itself in Applications and restarts there, so nobody has to drag it anywhere.
    /// Only a downloaded copy: a build run from dist/ stays where it is.
    private func moveToApplications() -> Bool {
        let here = Bundle.main.bundleURL
        let testDir = ProcessInfo.processInfo.environment["LIDROP_APPLICATIONS"]   // test hook: macOS kills a quarantined build run by hand
        let apps = URL(fileURLWithPath: testDir ?? "/Applications")
        guard here.pathExtension == "app", here.deletingLastPathComponent().path != apps.path,
              testDir != nil || here.path.contains("/AppTranslocation/") || getxattr(here.path, "com.apple.quarantine", nil, 0, 0, 0) >= 0 else { return false }
        for a in NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "") where a != .current {
            a.terminate()
            let until = Date().addingTimeInterval(3)
            while !a.isTerminated && Date() < until { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
        }
        let dest = apps.appendingPathComponent("lidrop.app")
        do {
            if FileManager.default.fileExists(atPath: dest.path) { try FileManager.default.removeItem(at: dest) }
            try FileManager.default.copyItem(at: here, to: dest)
        } catch { print("move to Applications:", error); return false }
        let strip = Process()
        strip.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
        strip.arguments = ["-dr", "com.apple.quarantine", dest.path]   // the user has already opened it once
        try? strip.run()
        strip.waitUntilExit()
        let open = NSWorkspace.OpenConfiguration()
        open.createsNewApplicationInstance = true   // or macOS may hand back the old copy it has just been told to quit
        NSWorkspace.shared.openApplication(at: dest, configuration: open) { _, error in
            if let error { print("restart from Applications:", error) }
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
        return true
    }

    /// Starts with the Mac from now on, and says once where it went: a menu-bar app shows no window of its own.
    private func firstLaunch() {
        guard loginItem.isEnabled, !UserDefaults.standard.bool(forKey: "settled") else { return }
        UserDefaults.standard.set(true, forKey: "settled")
        if SMAppService.mainApp.status != .enabled { toggleLogin() }
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
            let a = NSAlert()
            a.messageText = "lidrop is ready"
            a.informativeText = "It stays in the menu bar and starts with your Mac. Now open lidrop on your phone."
            a.runModal()
        }
    }

    func setConnected(_ on: Bool, name: String? = nil) { setPhones(on ? [name ?? "phone"] : []) }

    /// Menu: one disabled line per connected phone (by hello name), status dot reflects "any phone".
    func setPhones(_ names: [String]) {
        statusItem.button?.title = names.first.map { "● lidrop \($0)" } ?? "○ lidrop"
        stateItem.title = names.isEmpty ? "Disconnected" : "Connected phones: \(names.count)"
        guard let menu = statusItem.menu else { return }
        for it in menu.items where it.tag == 100 { menu.removeItem(it) }
        let at = (menu.index(of: stateItem)) + 1
        for (i, n) in names.enumerated() {
            let it = NSMenuItem(title: "   📱 \(n)", action: nil, keyEquivalent: "")
            it.isEnabled = false
            it.tag = 100
            menu.insertItem(it, at: at + i)
        }
    }

    @objc func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            else { try SMAppService.mainApp.register() }
        } catch { print("launch at login:", error) }
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
    }

    @objc func pickLook(_ sender: NSMenuItem) {
        guard let n = sender.representedObject as? String else { return }
        LightLook.currentName = n
        for it in sender.menu?.items ?? [] where it.representedObject != nil { it.state = it === sender ? .on : .off }
        overlay.preview()
    }

    @objc func previewLight() { overlay.preview() }

    func applicationWillTerminate(_ n: Notification) { server?.tunnel.stop() }

    @objc func copyPairingCode() {
        guard let t = server.tunnel.ticket else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(t, forType: .string)
    }

    @objc func openFolder() {
        NSWorkspace.shared.open(Server.saveDir)
    }
}

func localIP() -> String {
    var result = "0.0.0.0"
    var ifa: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&ifa) == 0, let first = ifa else { return result }
    defer { freeifaddrs(ifa) }
    var p: UnsafeMutablePointer<ifaddrs>? = first
    while let c = p {
        let i = c.pointee
        if i.ifa_addr.pointee.sa_family == UInt8(AF_INET), String(cString: i.ifa_name).hasPrefix("en") {
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            getnameinfo(i.ifa_addr, socklen_t(i.ifa_addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
            let s = String(cString: host)
            if !s.hasPrefix("169.254") { result = s; break }
        }
        p = i.ifa_next
    }
    return result
}
