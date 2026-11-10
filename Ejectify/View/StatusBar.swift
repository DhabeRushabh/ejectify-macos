//
//  StatusBar.swift
//  Ejectify
//
//  Created by Niels Mouthaan on 21/11/2020.
//

import AppKit

/// Creates and configures the app's menu bar status item with dynamic visibility and 1-tap ejection.
@MainActor
final class StatusBar: NSObject {

    /// Backing status item shown in the macOS menu bar.
    private let statusItem: NSStatusItem

    /// Dedicated status bar menu for right-click / options.
    private let statusMenu: StatusBarMenu

    /// Builds the status item, sets up dynamic visibility, and observes disk changes.
    override init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusMenu = StatusBarMenu()
        super.init()

        if let statusBarButton = statusItem.button {
            statusBarButton.target = self
            statusBarButton.action = #selector(statusBarButtonClicked(_:))
            statusBarButton.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        listenForVolumeNotifications()
        updateVisibility()
    }

    deinit {
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    /// Observes mount and unmount events so the menu bar button appears/disappears dynamically.
    private func listenForVolumeNotifications() {
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(self, selector: #selector(volumeStateChanged), name: NSWorkspace.didMountNotification, object: nil)
        center.addObserver(self, selector: #selector(volumeStateChanged), name: NSWorkspace.didUnmountNotification, object: nil)
        center.addObserver(self, selector: #selector(volumeStateChanged), name: NSWorkspace.didRenameVolumeNotification, object: nil)
    }

    @objc private func volumeStateChanged() {
        Task { @MainActor in
            self.updateVisibility()
        }
    }

    /// Automatically shows button when external disks are connected, hides when none are connected.
    func updateVisibility() {
        let externalVolumes = Volume.mountedExternalVolumes()
        let hasExternal = !externalVolumes.isEmpty

        // Show button in menu bar as soon as a new disk/HDD is added; hide when none
        statusItem.isVisible = hasExternal

        guard hasExternal, let button = statusItem.button else { return }

        if let ejectSymbol = NSImage(systemSymbolName: "eject.circle.fill", accessibilityDescription: "Eject") {
            let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .semibold)
            button.image = ejectSymbol.withSymbolConfiguration(config)
        } else if let icon = NSImage(named: "StatusBarIcon") {
            icon.size = NSSize(width: 16.0, height: 16.0)
            icon.isTemplate = true
            button.image = icon
        }
        button.imagePosition = .imageLeading

        if externalVolumes.count == 1 {
            button.title = " \(externalVolumes[0].name)"
            button.toolTip = "Click to safely eject \(externalVolumes[0].name) without prompting\nRight-click for options"
        } else {
            button.title = " (\(externalVolumes.count))"
            let names = externalVolumes.map(\.name).joined(separator: ", ")
            button.toolTip = "Click to safely eject all: \(names)\nRight-click for options"
        }
    }

    /// Handles clicks on the menu bar button. Left-click ejects immediately without prompting.
    @objc private func statusBarButtonClicked(_ sender: NSStatusBarButton) {
        guard let event = NSApp.currentEvent else { return }

        // Attempt event tap installation if permission was recently granted
        AppDelegate.shared.globalHotKeyController?.installEventTapIfNeeded()

        if event.type == .rightMouseUp || event.modifierFlags.contains(.control) {
            // Right-click or Control-click: show menu options
            statusMenu.updateMenu()
            statusItem.menu = statusMenu
            sender.performClick(nil)
            DispatchQueue.main.async { [weak self] in
                self?.statusItem.menu = nil
            }
        } else {
            // Left-click: 1-tap instant eject with ZERO confirmation prompts
            triggerEjectAll()
        }
    }

    /// Triggers immediate ejection of all external drives and provides instant button feedback.
    func triggerEjectAll() {
        guard let button = statusItem.button else { return }
        button.title = " Ejecting…"
        AppDelegate.shared.performManualUnmountAll()
    }
}
