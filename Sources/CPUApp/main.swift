import AppKit
import CPUCore

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var controller: AssistantController!
    private var statusItem: NSStatusItem!
    private let config = Config.load()

    func applicationDidFinishLaunching(_ notification: Notification) {
        Config.writeTemplateIfMissing()
        controller = AssistantController(config: config)
        let hotKeyOK = controller.registerHotKey()
        installStatusItem(hotKeyOK: hotKeyOK)
        controller.onRunningChanged = { [weak self] running in
            self?.statusItem.button?.image = NSImage(
                systemSymbolName: running ? "cursorarrow.motionlines" : "cursorarrow.rays",
                accessibilityDescription: "CPU"
            )
        }
        if CommandLine.arguments.contains("--show") {
            // Development: open the panel for typing right away (no prompts, no voice).
            controller.toggleFromMenu()
        } else {
            // First launch or a missing permission: the card lists what CPU needs.
            controller.showOnboardingIfNeeded()
        }
        if !hotKeyOK {
            let alert = NSAlert()
            alert.messageText = "快捷键 \(config.hotkey) 被占用"
            alert.informativeText = "在 \(Config.fileURL.path) 中修改 \"hotkey\"（例如 \"fn fn\" 或 \"ctrl+alt+space\"）后重启 CPU。也可以从菜单栏图标唤起。"
            alert.runModal()
        }
    }

    private func installStatusItem(hotKeyOK: Bool) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "cursorarrow.rays", accessibilityDescription: "CPU")
        let menu = NSMenu()
        let show = NSMenuItem(title: hotKeyOK ? "唤起（\(controller.hotKeyName)）" : "唤起", action: #selector(showPanel), keyEquivalent: "")
        show.target = self
        menu.addItem(show)
        let teach = NSMenuItem(title: "示范一个任务…", action: #selector(teach), keyEquivalent: "")
        teach.target = self
        menu.addItem(teach)
        let recent = NSMenuItem(title: "最近任务", action: nil, keyEquivalent: "")
        recent.submenu = NSMenu(title: "最近任务")
        recent.submenu?.delegate = self
        menu.addItem(recent)
        menu.addItem(.separator())
        let permissions = NSMenuItem(title: "权限设置…", action: #selector(openPermissions), keyEquivalent: "")
        permissions.target = self
        menu.addItem(permissions)
        let settings = NSMenuItem(title: "打开配置文件", action: #selector(openConfig), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "退出 CPU", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu
    }

    /// Rebuilt each time it opens: shortcuts first, then the latest tasks.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        for shortcut in TaskStore.shared.shortcuts.prefix(8) {
            let item = NSMenuItem(title: "⚡︎ \(shortcut.name)", action: #selector(runFromMenu(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = shortcut.request
            item.toolTip = shortcut.request
            menu.addItem(item)
        }
        for skill in TaskStore.shared.skills.prefix(8) {
            let item = NSMenuItem(title: "🎓 \(skill.name)", action: #selector(runFromMenu(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = skill.name
            item.toolTip = skill.summary
            menu.addItem(item)
        }
        if !TaskStore.shared.shortcuts.isEmpty || !TaskStore.shared.skills.isEmpty {
            menu.addItem(.separator())
        }
        for record in TaskStore.shared.history.prefix(10) {
            let item = NSMenuItem(title: record.title.isEmpty ? record.request : record.title, action: #selector(runFromMenu(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = record.request
            item.toolTip = record.result
            menu.addItem(item)
        }
        if menu.items.isEmpty {
            menu.addItem(NSMenuItem(title: "还没有任务", action: nil, keyEquivalent: ""))
        }
    }

    @objc private func runFromMenu(_ sender: NSMenuItem) {
        if let request = sender.representedObject as? String {
            controller.run(request: request)
        }
    }

    @objc private func teach() {
        controller.teach()
    }

    @objc private func showPanel() {
        controller.toggleFromMenu()
    }

    @objc private func openPermissions() {
        UserDefaults.standard.set(false, forKey: "onboarded")
        controller.showOnboardingIfNeeded()
    }

    @objc private func openConfig() {
        Config.writeTemplateIfMissing()
        NSWorkspace.shared.open(Config.fileURL)
    }
}

if CommandLine.arguments.count > 1, CommandLine.arguments[1] == "--cpu-helper" {
    // `cpu …` inside the code tool's scripts.
    exit(CPUHelper.main(Array(CommandLine.arguments.dropFirst(2))))
}
setvbuf(stdout, nil, _IOLBF, 0)
if isatty(STDERR_FILENO) == 0 {
    // Launched from Finder/open: keep diagnostics in ~/Library/Logs/CPU/cpu.log.
    let directory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/CPU")
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let descriptor = open(directory.appendingPathComponent("cpu.log").path, O_WRONLY | O_CREAT | O_APPEND, 0o600)
    if descriptor >= 0 {
        dup2(descriptor, STDERR_FILENO)
        close(descriptor)
    }
}
let application = NSApplication.shared
if CardPreview.runIfRequested() {
    exit(0)
}
let delegate = AppDelegate()
application.delegate = delegate
application.setActivationPolicy(.accessory)
application.run()
