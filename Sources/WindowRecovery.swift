import AppKit
import ApplicationServices

private let accessibilityPromptedKey = "AccessibilityPermissionPrompted"

struct WindowIdentity: Hashable {
    let processID: pid_t
    let windowNumber: CGWindowID
}

/// Moves standard app windows off WellAwake's menu virtual screen.
@MainActor
final class WindowRecovery {
    var onNeedsPermission: () -> Void = {}
    private var showedPermissionInstructions = false

    func windowsOnVirtualScreen() -> Set<WindowIdentity> {
        guard let virtualBounds = virtualScreenBounds() else { return [] }
        return Set(windowList().compactMap { info in
            guard let identity = identity(from: info), let bounds = bounds(from: info), isOnVirtualScreen(bounds, virtualBounds) else { return nil }
            return identity
        })
    }

    func bringAllWindowsBack() {
        moveWindows(excluding: [])
    }

    func bringNewWindowsBack(excluding existing: Set<WindowIdentity>) {
        moveWindows(excluding: existing)
    }

    private func moveWindows(excluding existing: Set<WindowIdentity>) {
        guard let virtualBounds = virtualScreenBounds(), let destination = realScreenBounds() else { return }
        guard hasAccessibilityPermission() else { return }
        let listedWindows = windowList()
        for app in NSWorkspace.shared.runningApplications where app.processIdentifier != getpid() {
            let application = AXUIElementCreateApplication(app.processIdentifier)
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(application, kAXWindowsAttribute as CFString, &value) == .success,
                  let windows = value as? [AXUIElement] else { continue }
            for window in windows where isStandardWindow(window) {
                guard let position = windowPosition(window), let size = windowSize(window),
                      isOnVirtualScreen(CGRect(origin: position, size: size), virtualBounds) else { continue }
                if !existing.isEmpty {
                    guard let identity = windowIdentity(window, position: position, size: size, in: listedWindows),
                          !existing.contains(identity) else { continue }
                }
                let x = min(max(destination.midX - size.width / 2, destination.minX), destination.maxX - size.width)
                let y = min(max(destination.midY - size.height / 2, destination.minY), destination.maxY - size.height)
                var point = CGPoint(x: x, y: y)
                guard let axPosition = AXValueCreate(.cgPoint, &point) else { continue }
                let error = AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, axPosition)
                if error != .success {
                    NSLog("WellAwake: couldn't move window at %@ from the virtual screen (AX error \(error.rawValue))", NSStringFromPoint(position))
                }
            }
        }
    }

    private func hasAccessibilityPermission() -> Bool {
        guard !AXIsProcessTrusted() else { return true }
        var options: [String: Any] = [:]
        if !UserDefaults.standard.bool(forKey: accessibilityPromptedKey) {
            options[kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String] = true
            UserDefaults.standard.set(true, forKey: accessibilityPromptedKey)
        }
        _ = AXIsProcessTrustedWithOptions(options as CFDictionary)
        if !showedPermissionInstructions {
            showedPermissionInstructions = true
            onNeedsPermission()
        }
        return false
    }

    private func isStandardWindow(_ window: AXUIElement) -> Bool {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXSubroleAttribute as CFString, &value) == .success,
              let subrole = value as? String else { return false }
        return subrole == kAXStandardWindowSubrole as String
    }

    private func windowIdentity(_ window: AXUIElement, position: CGPoint, size: CGSize, in listedWindows: [[String: Any]]) -> WindowIdentity? {
        var processID: pid_t = 0
        guard AXUIElementGetPid(window, &processID) == .success,
              processID != getpid() else { return nil }
        let frame = CGRect(origin: position, size: size)
        return listedWindows.first { info in
            guard let identity = identity(from: info), identity.processID == processID,
                  let bounds = bounds(from: info) else { return false }
            return abs(bounds.origin.x - frame.origin.x) <= 2 && abs(bounds.origin.y - frame.origin.y) <= 2 &&
                abs(bounds.width - frame.width) <= 2 && abs(bounds.height - frame.height) <= 2
        }.flatMap(identity(from:))
    }

    private func windowPosition(_ window: AXUIElement) -> CGPoint? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        return AXValueGetValue(value as! AXValue, .cgPoint, &point) ? point : nil
    }

    private func windowSize(_ window: AXUIElement) -> CGSize? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var size = CGSize.zero
        return AXValueGetValue(value as! AXValue, .cgSize, &size) ? size : nil
    }

    private func virtualScreenBounds() -> CGRect? {
        guard let display = virtualScreenDisplay() else { return nil }
        return CGDisplayBounds(display)
    }

    private func realScreenBounds() -> CGRect? {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return nil }
        var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &displays, &count) == .success else { return nil }
        let realDisplays = displays.prefix(Int(count)).filter { CGDisplayVendorNumber($0) != wellAwakeDisplayVendor }
        guard let display = realDisplays.first(where: { $0 == CGMainDisplayID() }) ?? realDisplays.first else { return nil }
        return CGDisplayBounds(display)
    }

    private func windowList() -> [[String: Any]] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return [] }
        return list.filter { ($0[kCGWindowLayer as String] as? Int) == 0 && ($0[kCGWindowOwnerPID as String] as? pid_t) != getpid() }
    }

    private func identity(from info: [String: Any]) -> WindowIdentity? {
        guard let processID = info[kCGWindowOwnerPID as String] as? pid_t,
              let number = info[kCGWindowNumber as String] as? NSNumber else { return nil }
        return WindowIdentity(processID: processID, windowNumber: number.uint32Value)
    }

    private func bounds(from info: [String: Any]) -> CGRect? {
        guard let description = info[kCGWindowBounds as String] as? NSDictionary else { return nil }
        var rect = CGRect.zero
        return CGRectMakeWithDictionaryRepresentation(description as CFDictionary, &rect) ? rect : nil
    }

    private func isOnVirtualScreen(_ window: CGRect, _ virtualScreen: CGRect) -> Bool {
        virtualScreen.contains(CGPoint(x: window.midX, y: window.midY))
    }
}
