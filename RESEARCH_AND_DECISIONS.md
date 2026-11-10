# Research, Findings & Architectural Decisions: Ejectify macOS Customization

## Context & Objectives
- **Target**: Safe, prompt-free, single-tap and long-press ejection of all external disks (HDD, SSD, USB thumb drives) on macOS.
- **Critical Requirements**:
  1. Menu bar button that appears dynamically when external drives are connected, and automatically hides when none are attached.
  2. Direct 1-tap left-click ejection without confirmation dialogs or menu dropdowns.
  3. Global long-press trigger: **ONLY Fn key** held for ~0.75s anywhere on the system.
  4. Zero polling in background: Purely event-driven OS hardware interrupt via `CGEventTap` (.flagsChanged only). 0.0% CPU at idle.
  5. Never touch internal APFS volumes, system containers, recovery partitions, or connected iOS devices (iPhone/iPad).
  6. Zero annoying modal popups or interruptive success dialogs.

## Architecture & Zero-Polling Design
1. **Passive OS Interrupt vs Polling**:
   - Polling loops or continuous timers were completely eliminated.
   - The app uses `CGEventTap` with mask restricted strictly to `1 << CGEventType.flagsChanged.rawValue`.
   - Normal alphanumeric typing is never intercepted or observed.
   - When the user presses the `Fn` key, macOS delivers an OS interrupt to the run loop. A single one-shot work item arms for 0.75s.
   - If `Fn` is released before 0.75s, the work item cancels immediately.
   - If held for 0.75s, it triggers whole-disk safe ejection.
   - When no keys are pressed, the thread sleeps in `CFRunLoop` consuming 0.0% CPU.
2. **Accessibility Permission Discovery**:
   - `CGEventTap` requires Accessibility permission (`kTCCServiceAccessibility`).
   - If not granted, the app requests it once natively via `AXIsProcessTrustedWithOptions` and listens passively to `NSWorkspace.didActivateApplicationNotification` (no background polling loops) to initialize the event tap the moment the user returns from System Settings.

## Implementation Details
- `Ejectify/Model/Volume.swift`: Added `isIPhoneOrIOSDevice` filter and `mountedExternalVolumes()`.
- `Ejectify/Model/Preference.swift`: Defaulted `ejectInsteadOfUnmount = true`, `forceUnmount = true`, `hasSeenOnboarding = true`.
- `Ejectify/View/StatusBar.swift`: Dynamic visibility (`statusItem.isVisible = !externalVolumes.isEmpty`), 1-tap left-click ejection with visual `⏏ Ejecting...` feedback, right-click menu.
- `Ejectify/Controller/GlobalHotKeyController.swift`: Pure event-driven Fn-only modifier hold detector (0.0% CPU).
- `Ejectify/AppDelegate.swift`: Streamlined startup (no onboarding modal), safe whole-disk eject targeting only external drives with `/usr/sbin/diskutil eject` fallback.
- Installed Release binary to `/Applications/Ejectify.app`.
