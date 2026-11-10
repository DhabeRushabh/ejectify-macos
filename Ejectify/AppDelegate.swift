//
//  AppDelegate.swift
//  Ejectify
//
//  Created by Niels Mouthaan on 21/11/2020.
//

import Cocoa

@MainActor

/// Coordinates app startup and wires core menu/activity controllers.
final class AppDelegate: NSObject, NSApplicationDelegate {


    /// Shared delegate instance exposed for app-wide coordination.
    static let shared = NSApplication.shared.delegate as! AppDelegate

    /// Owns the menu bar status item and its menu lifecycle.
    var statusBar: StatusBar?

    /// Owns event observation and disk-operation orchestration.
    var activityController: ActivityController?

    /// Owns global hotkey registration and dispatch for the configured all-volumes action.
    var globalHotKeyController: GlobalHotKeyController?

    /// Owns Sparkle updater lifecycle and manual update actions.
    private var updateController: UpdateController?

    /// Owns diagnostics report generation and export UI.
    private let diagnosticsReportController = DiagnosticsReportController()

    /// Owns the onboarding window lifecycle while guidance is presented.
    private var onboardingWindowController: OnboardingWindowController?

    /// Returns whether the global all-volumes action hotkey is currently registered.
    var isUnmountAllHotKeyRegistered: Bool {
        globalHotKeyController?.isRegistered ?? false
    }

    /// Bootstraps routing mode, applies one-time first-run setup, and initializes primary app controllers.
    func applicationDidFinishLaunching(_ aNotification: Notification) {
        Preference.hasSeenOnboarding = true
        Preference.ejectInsteadOfUnmount = true
        Preference.forceUnmount = true

        VolumeOperationRouter.shared.configureExecutionMode()

        globalHotKeyController = GlobalHotKeyController { [weak self] in
            self?.performManualUnmountAll()
        }
        statusBar = StatusBar()
        activityController = ActivityController()
        let updateController = UpdateController()
        self.updateController = updateController
        updateController.start()
    }

    /// Starts a user-initiated Sparkle update check.
    func checkForUpdates() {
        updateController?.checkForUpdates()
    }

    /// Starts a user-initiated diagnostics report save flow.
    func saveDiagnosticsReport() {
        diagnosticsReportController.saveDiagnosticsReport()
    }

    /// Safely ejects all connected external disks without prompting or interruptions.
    func performManualUnmountAll() {
        let externalVolumes = Volume.mountedExternalVolumes()
        guard !externalVolumes.isEmpty else {
            Log.app.log("Manual eject-all triggered: no external volumes to eject")
            return
        }

        activityController?.clearRemountStateForEjectMode()
        let representatives = Volume.uniqueWholeDiskRepresentatives(from: externalVolumes)
        Log.app.log("Manual eject-all triggered: \(representatives.count) whole disk(s) for \(externalVolumes.count) external volume(s)")

        for volume in representatives {
            let wholeBSD = volume.wholeDiskBSDName
            let volName = volume.name

            VolumeOperationRouter.shared.eject(
                volumeUUID: volume.diskUUID.map { $0 as NSUUID },
                volumeName: volume.name,
                bsdName: volume.bsdName,
                forceUnmount: true
            ) { success, message, _ in
                Log.app.log("Eject result for \(volName) (\(wholeBSD)): success=\(success), message=\(message ?? "none")")
                if !success {
                    // Safe command-line fallback if DiskArbitration encountered a lock
                    let task = Process()
                    task.launchPath = "/usr/sbin/diskutil"
                    task.arguments = ["eject", wholeBSD]
                    try? task.run()
                }
            }
        }
    }

    /// Sends a best-effort helper shutdown request when the app is quitting.
    func applicationWillTerminate(_ notification: Notification) {
        VolumeOperationRouter.shared.requestHelperTermination()
    }

    /// Presents the onboarding window.
    private func showOnboarding() {
        onboardingWindowController = OnboardingWindowController { [weak self] in
            self?.onboardingWindowController = nil
        }
        onboardingWindowController?.showCentered()
    }
}
