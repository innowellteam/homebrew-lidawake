import AppKit
import ScreenCaptureKit

// "Watch Virtual Screen" in the menu: a window on a real screen showing the menu's virtual screen
// live, to see what an agent is doing there. View only: it draws the picture and passes nothing on,
// so clicks and keys in it never reach the virtual screen. Reading a screen's picture needs macOS's
// Screen Recording permission.

// The menu's virtual screen if it's online, found by the numbers VirtualScreen.swift gives it.
func virtualScreenDisplay() -> CGDirectDisplayID? {
    onlineDisplayStates()?.first { $0.wellAwake && CGDisplaySerialNumber($0.id) == virtualScreenSerial }?.id
}

@MainActor
final class ScreenWatcher: NSObject, NSWindowDelegate, SCStreamOutput, SCStreamDelegate {
    private var window: NSWindow?
    private var stream: SCStream?
    // The screen being shown, from the menu click until the window closes.
    private var watching: CGDirectDisplayID?
    // Counts the clicks that started a stream, so a start still in flight from a window closed and
    // reopened meanwhile knows it's stale. Display ids alone can't tell: reopening reuses the id.
    private var starts = 0
    // Screen Recording permission is missing.
    var onDenied: () -> Void = {}

    func show(_ display: CGDirectDisplayID) {
        let window = self.window ?? makeWindow(for: display)
        self.window = window
        if !window.isVisible { centre(window) }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        guard watching == nil else { return }
        watching = display
        starts += 1
        let attempt = starts
        Task { await start(display, attempt: attempt) }
    }

    // Every 2 seconds, and when the screens change: the virtual screen went away, or the window is on it.
    func check(virtualScreen: CGDirectDisplayID?) {
        guard let window, window.isVisible else { return }
        if virtualScreen != watching { window.close() } else { keepOffVirtualScreen() }
    }

    private func makeWindow(for display: CGDirectDisplayID) -> NSWindow {
        let size = NSSize(width: CGDisplayPixelsWide(display), height: CGDisplayPixelsHigh(display))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 640 * size.height / size.width),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "Virtual Screen"
        window.isReleasedWhenClosed = false
        window.contentAspectRatio = size
        window.contentMinSize = NSSize(width: 320, height: 320 * size.height / size.width)
        let view = NSView()
        view.wantsLayer = true
        view.layer!.backgroundColor = NSColor.black.cgColor
        view.layer!.contentsGravity = .resizeAspect
        window.contentView = view
        window.delegate = self
        return window
    }

    // Still the window's stream: not closed, or closed and opened again, while macOS was answering.
    private func isCurrent(_ attempt: Int) -> Bool { watching != nil && starts == attempt }

    private func start(_ display: CGDirectDisplayID, attempt: Int) async {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard isCurrent(attempt) else { return }
            guard let screen = content.displays.first(where: { $0.displayID == display }) else { return window!.close() }
            // WellAwake's own windows are left out, so the picture can never contain itself.
            let filter = SCContentFilter(display: screen, excludingApplications: content.applications.filter { $0.processID == getpid() }, exceptingWindows: [])
            let configuration = SCStreamConfiguration()
            configuration.width = screen.width
            configuration.height = screen.height
            // macOS only sends a frame when the picture changes, and no more often than this.
            configuration.minimumFrameInterval = CMTime(value: 1, timescale: 15)
            configuration.queueDepth = 3
            let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
            try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: .main)
            try await stream.startCapture()
            guard isCurrent(attempt) else {
                try? await stream.stopCapture()
                return
            }
            self.stream = stream
        } catch {
            guard isCurrent(attempt) else { return }
            window!.close()
            if (error as? SCStreamError)?.code == .userDeclined {
                onDenied()
            } else {
                NSLog("WellAwake: couldn't show the virtual screen: \(error)")
            }
        }
    }

    // On the main queue, as asked for in `start`. A frame with nothing new has no picture.
    nonisolated func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        MainActor.assumeIsolated {
            guard let surface = sampleBuffer.imageBuffer.flatMap(CVPixelBufferGetIOSurface)?.takeUnretainedValue() else { return }
            window?.contentView?.layer?.contents = surface
        }
    }

    // Not on the main thread. The virtual screen went away, or macOS stopped the capture.
    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        let stopped = ObjectIdentifier(stream)
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                guard self.stream.map(ObjectIdentifier.init) == stopped else { return }
                self.stream = nil
                self.window?.close()
            }
        }
    }

    func windowWillClose(_ notification: Notification) {
        watching = nil
        window?.contentView?.layer?.contents = nil
        guard let stream else { return }
        self.stream = nil
        Task { try? await stream.stopCapture() }
    }

    func windowDidChangeScreen(_ notification: Notification) { keepOffVirtualScreen() }
    func windowDidMove(_ notification: Notification) { keepOffVirtualScreen() }

    // Dragged there, or moved there by macOS when the built-in screen is switched off with the lid closed.
    // With no real screen left, there's nowhere to show it.
    private func keepOffVirtualScreen() {
        guard let window, screens(wellAwake: true).contains(where: { $0.frame.intersects(window.frame) }) else { return }
        if screens(wellAwake: false).isEmpty { window.close() } else { centre(window) }
    }

    private func screens(wellAwake: Bool) -> [NSScreen] {
        NSScreen.screens.filter {
            (CGDisplayVendorNumber($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as! CGDirectDisplayID) == wellAwakeDisplayVendor) == wellAwake
        }
    }

    // In the middle of a real screen: the one in use if that's real.
    private func centre(_ window: NSWindow) {
        let real = screens(wellAwake: false)
        guard let visible = (real.first { $0 == NSScreen.main } ?? real.first)?.visibleFrame else { return }
        window.setFrameOrigin(NSPoint(x: visible.midX - window.frame.width / 2, y: visible.midY - window.frame.height / 2))
    }
}

extension AppDelegate: NSMenuItemValidation {
    @objc func watchVirtualScreen() {
        guard let display = virtualScreenDisplay() else { return }
        screenWatcher.onDenied = { [unowned self] in askForScreenRecording() }
        screenWatcher.show(display)
    }

    // Greyed out while the virtual screen is off.
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        menuItem !== watchScreenItem || virtualScreenDisplay() != nil
    }

    func askForScreenRecording() {
        // Puts WellAwake in the Screen Recording list and has macOS ask. Returns straight away.
        CGRequestScreenCaptureAccess()
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "WellAwake needs permission to show the virtual screen"
        alert.informativeText = "Turn on WellAwake under Screen Recording in System Settings > Privacy & Security, then choose Watch Virtual Screen again. macOS may ask you to quit and reopen WellAwake."
        alert.addButton(withTitle: "Open Settings")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
    }
}
