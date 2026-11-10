//
//  GlobalHotKeyController.swift
//  Ejectify
//
//  Created by Codex on 17/03/2026.
//

import AppKit
import Carbon
import Foundation

/// Purely event-driven Fn key hold listener.
/// 0.0% CPU at idle: Uses passive OS hardware interrupts via CGEventTap (.flagsChanged only).
/// Zero polling loops or timers running in the background.
final class GlobalHotKeyController: NSObject {

    /// C callback for the Quartz EventTap detecting Fn modifier changes.
    private static let eventTapCallback: CGEventTapCallBack = { proxy, type, event, refcon in
        guard let refcon else {
            return Unmanaged.passUnretained(event)
        }

        let controller = Unmanaged<GlobalHotKeyController>.fromOpaque(refcon).takeUnretainedValue()
        return controller.handleEventTap(proxy: proxy, type: type, event: event)
    }

    /// Action invoked when Fn hold triggers.
    private let onAllVolumesAction: @MainActor () -> Void

    /// Registered Quartz EventTap for detecting Fn modifier.
    private var eventTap: CFMachPort?

    /// Run loop source for the Quartz EventTap.
    private var runLoopSource: CFRunLoopSource?

    /// One-shot work item tracking Fn hold duration.
    private var holdTimer: DispatchWorkItem?

    /// State for Fn key hold.
    private var isFnHeld = false

    /// Indicates whether the Fn key event tap is active.
    var isRegistered: Bool {
        eventTap != nil
    }

    /// Creates the controller and installs the event-driven listener.
    init(onAllVolumesAction: @escaping @MainActor () -> Void) {
        self.onAllVolumesAction = onAllVolumesAction
        super.init()
        installEventTapIfNeeded()
    }

    deinit {
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        removeEventTap()
    }

    // MARK: - Event-Driven Fn Key Hold (Passive OS Interrupt, Zero Polling)

    /// Installs a Quartz EventTap listening ONLY to modifier flag changes.
    /// Does not intercept normal typing or letter keys.
    func installEventTapIfNeeded() {
        guard eventTap == nil else { return }

        guard AXIsProcessTrusted() else {
            Log.hotKey.log("Accessibility not yet granted. Prompting user once...")
            let options = ["AXTrustedCheckOptionPrompt" as CFString: kCFBooleanTrue] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
            listenForAppSwitchOnce()
            return
        }

        // Only listen for flagsChanged (Fn, Shift, Ctrl, etc.) - NEVER normal typing/keystrokes
        let mask = 1 << CGEventType.flagsChanged.rawValue

        let tap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(mask),
            callback: Self.eventTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        )

        guard let tap else {
            Log.hotKey.error("Failed to create EventTap for Fn key detection")
            return
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)

        self.eventTap = tap
        self.runLoopSource = source
        CGEvent.tapEnable(tap: tap, enable: true)
        Log.hotKey.log("Event-driven Fn key detector active (passive OS interrupt, zero polling)")
    }

    /// Event-driven notification listener: checks once whenever user switches apps (e.g. from System Settings).
    /// Zero timer polling.
    private func listenForAppSwitchOnce() {
        NSWorkspace.shared.notificationCenter.removeObserver(self, name: NSWorkspace.didActivateApplicationNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(activeAppDidChange),
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil
        )
    }

    @objc private func activeAppDidChange() {
        if AXIsProcessTrusted() {
            NSWorkspace.shared.notificationCenter.removeObserver(self, name: NSWorkspace.didActivateApplicationNotification, object: nil)
            installEventTapIfNeeded()
        }
    }

    /// Removes the Quartz EventTap.
    private func removeEventTap() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            eventTap = nil
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            runLoopSource = nil
        }
    }

    /// Handles modifier changes delivered directly by macOS.
    private func handleEventTap(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return nil
        }

        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        let hasFnFlag = event.flags.contains(.maskSecondaryFn)

        // Only react if Fn key is pressed down or released
        if keyCode == 63 || hasFnFlag {
            if hasFnFlag && !isFnHeld {
                // Fn key pressed down: arm a single one-shot timer
                isFnHeld = true
                startHoldTimer()
            } else if !hasFnFlag && isFnHeld {
                // Fn key released before threshold: cancel timer immediately
                cancelHoldTimer()
                isFnHeld = false
            }
        }

        return Unmanaged.passUnretained(event)
    }

    /// Arms a one-shot work item to fire after 0.75s of holding Fn.
    private func startHoldTimer() {
        cancelHoldTimer()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self, self.isFnHeld else { return }
            Log.hotKey.log("Fn key held for 0.75s: triggering safe disk eject")
            NSSound.beep()
            Task { @MainActor [onAllVolumesAction = self.onAllVolumesAction] in
                onAllVolumesAction()
            }
        }
        self.holdTimer = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.75, execute: workItem)
    }

    /// Cancels any active hold timer immediately on key release.
    private func cancelHoldTimer() {
        holdTimer?.cancel()
        holdTimer = nil
    }
}
