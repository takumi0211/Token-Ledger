import AppKit
import LedgerCore
import SwiftUI

@MainActor final class LedgerDelegate: NSObject, NSApplicationDelegate {
    let model = LedgerModel()
    var item: NSStatusItem!
    let popover = NSPopover()
    func applicationDidFinishLaunching(_: Notification) {
        NSApp.setActivationPolicy(.accessory)
        // A changing status-item width moves the popover anchor during period switches.
        item = NSStatusBar.system.statusItem(withLength: 44)
        item.button?.imagePosition = .noImage
        item.button?.alignment = .center
        item.button?.target = self
        item.button?.action = #selector(toggle)
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(rootView: LedgerView(model: model))
        model.changed = { [weak self] in self?.update() }
        update()
        model.start()
    }

    func update() {
        item?.button?.title = model.total.compactMoney
        item?.button?.toolTip = "\(model.period.rawValue) · \(model.total.money) · API equivalent (USD)"
    }

    func show() {
        guard !popover.isShown, let button = item.button else { return }
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc func toggle() {
        if NSApp.currentEvent?.type == .rightMouseUp {
            let menu = NSMenu()
            let entries: [(String, Selector)] = [
                ("About CodexBar", #selector(attribution)),
                ("Quit Token Ledger", #selector(quit)),
            ]
            for (title, action) in entries {
                let entry = NSMenuItem(title: title, action: action, keyEquivalent: "")
                entry.target = self
                menu.addItem(entry)
            }
            item.menu = menu
            item.button?.performClick(nil)
            item.menu = nil
            return
        }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            show()
        }
    }

    func applicationShouldHandleReopen(_: NSApplication, hasVisibleWindows _: Bool) -> Bool {
        show()
        return true
    }

    @objc func quit() {
        NSApp.terminate(nil)
    }

    @objc func attribution() {
        NSWorkspace.shared.open(Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/NOTICE.txt"))
    }
}

@main struct TokenLedgerApplication {
    @MainActor static func main() {
        let app = NSApplication.shared
        let delegate = LedgerDelegate()
        app.delegate = delegate
        app.run()
    }
}
