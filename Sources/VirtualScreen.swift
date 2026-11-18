import AppKit
import IOKit.pwr_mgt

// Virtual screens exist only in software (CGVirtualDisplay.h), and macOS treats them as external
// monitors. WellAwake makes two kinds (see ScreenPlan in DisplaySleep.swift):
// - "Virtual Screen" in the menu: 1920x1080, there while it's ticked, to run things such as Claude in
//   Chrome or record demos on, out of the way. A replacement for BetterDisplay's virtual screens.
// - The lid screen: the built-in screen's size, there while WellAwake keeps a closed Mac awake with no
//   other monitor on.
// With either there and the lid closed, WellAwake switches the built-in screen off, so macOS moves its
// windows onto WellAwake's screen, where they keep drawing.
let virtualScreenKey = "VirtualScreen"
// The built-in screen's size in points, remembered for when it's already off by the time the lid closes.
let builtInScreenSizeKey = "BuiltInScreenSize"
// The display WellAwake switched off, so it's switched back on even after a crash or restart.
let switchedOffScreenKey = "SwitchedOffScreen"

// What macOS refused just now; each refusal is reported once.
struct ScreenRefusals {
    var virtualScreen = false
    var lidScreen = false
    var builtInOff = false
}

final class VirtualScreens {
    private(set) var virtualScreen: CGVirtualDisplay?
    private(set) var lidScreen: CGVirtualDisplay?
    // macOS refused for this closing of the lid, so don't ask again every 2 seconds.
    private var lidScreenRefused = false
    private var builtInOffRefused = false
    private var displaySleepAssertion: IOPMAssertionID?

    var hasScreen: Bool { virtualScreen != nil || lidScreen != nil }

    // Brings the screens and the display sleep assertion in line with the plan. `displays` are the
    // screens online before this call.
    func apply(_ plan: ScreenPlan, displays: [DisplayState], lidScreenSize: () -> CGSize) -> ScreenRefusals {
        var refused = ScreenRefusals()
        // The built-in screen comes back first and the lid screen goes on the next check, so the
        // windows have somewhere to go back to.
        let builtInComingBack = !plan.builtInOff && UserDefaults.standard.integer(forKey: switchedOffScreenKey) != 0
        if builtInComingBack { switchBuiltInScreenBackOn() }
        if !plan.builtInOff { builtInOffRefused = false }
        if !plan.virtualScreen {
            virtualScreen = nil
        } else if virtualScreen == nil {
            virtualScreen = makeVirtualDisplay(name: "WellAwake", size: CGSize(width: 1920, height: 1080), serial: 1)
            refused.virtualScreen = virtualScreen == nil
        }
        if !plan.lidScreen {
            if !builtInComingBack { lidScreen = nil }
            lidScreenRefused = false
        } else if lidScreen == nil, !lidScreenRefused {
            lidScreen = makeVirtualDisplay(name: "WellAwake (lid closed)", size: lidScreenSize(), serial: 2)
            lidScreenRefused = lidScreen == nil
            refused.lidScreen = lidScreenRefused
        }
        // Only once WellAwake's screen is online, so the windows have somewhere to go.
        if plan.builtInOff, !builtInOffRefused, displays.contains(where: { $0.wellAwake }), let builtIn = displays.first(where: { $0.builtIn }) {
            if setDisplayEnabled(builtIn.id, false) {
                UserDefaults.standard.set(Int(builtIn.id), forKey: switchedOffScreenKey)
            } else {
                builtInOffRefused = true
                refused.builtInOff = true
            }
        }
        let holdDisplayAwake = plan.holdDisplayAwake && hasScreen
        if holdDisplayAwake, displaySleepAssertion == nil {
            var assertion: IOPMAssertionID = 0
            if IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                           "WellAwake is keeping its virtual screen awake" as CFString, &assertion) == kIOReturnSuccess {
                displaySleepAssertion = assertion
            } else {
                NSLog("WellAwake: couldn't hold off display sleep for the virtual screen")
            }
        } else if !holdDisplayAwake, let assertion = displaySleepAssertion {
            IOPMAssertionRelease(assertion)
            displaySleepAssertion = nil
        }
        return refused
    }
}

// Switching a screen off and on is a private SkyLight call (what Displays settings uses), looked up at
// run time so a macOS that drops it gets a refusal rather than a crash.
private typealias ConfigureDisplayEnabled = @convention(c) (CGDisplayConfigRef?, CGDirectDisplayID, Bool) -> CGError
private let configureDisplayEnabled: ConfigureDisplayEnabled? = {
    guard let skyLight = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY),
          let symbol = dlsym(skyLight, "CGSConfigureDisplayEnabled") else { return nil }
    return unsafeBitCast(symbol, to: ConfigureDisplayEnabled.self)
}()

// Until switched back on or logging out. Quitting doesn't switch it back on by itself, hence
// `switchBuiltInScreenBackOn`.
func setDisplayEnabled(_ display: CGDirectDisplayID, _ enabled: Bool) -> Bool {
    guard let configureDisplayEnabled else { return false }
    var config: CGDisplayConfigRef?
    guard CGBeginDisplayConfiguration(&config) == .success else { return false }
    guard configureDisplayEnabled(config, display, enabled) == .success else {
        CGCancelDisplayConfiguration(config)
        return false
    }
    return CGCompleteDisplayConfiguration(config, .forSession) == .success
}

// When the lid opens, at launch and quit, and from the sleep recovery worker when WellAwake stops,
// so the Mac is never left without its screen. On failure it's tried again at the next check.
func switchBuiltInScreenBackOn() {
    let display = UserDefaults.standard.integer(forKey: switchedOffScreenKey)
    guard display != 0 else { return }
    if setDisplayEnabled(CGDirectDisplayID(display), true) {
        UserDefaults.standard.removeObject(forKey: switchedOffScreenKey)
    } else {
        NSLog("WellAwake: couldn't switch the built-in screen back on")
    }
}

// Nil if macOS refused it. 1x, at the given size in points. The vendor, product and serial numbers are
// made up but fixed, so macOS remembers where you put each screen in Displays settings.
func makeVirtualDisplay(name: String, size: CGSize, serial: UInt32) -> CGVirtualDisplay? {
    let width = Int(size.width.rounded()), height = Int(size.height.rounded())
    let descriptor = CGVirtualDisplayDescriptor()
    descriptor.setDispatchQueue(DispatchQueue.main)
    descriptor.name = name
    descriptor.maxPixelsWide = UInt32(width)
    descriptor.maxPixelsHigh = UInt32(height)
    // About 92 pixels per inch, like a 24-inch 1080p monitor.
    descriptor.sizeInMillimeters = CGSize(width: Double(width) * 0.2745, height: Double(height) * 0.2745)
    descriptor.vendorID = wellAwakeDisplayVendor
    descriptor.productID = 1
    descriptor.serialNum = serial
    guard let display = CGVirtualDisplay(descriptor: descriptor) else { return nil }
    let settings = CGVirtualDisplaySettings()
    settings.hiDPI = 0
    settings.modes = [CGVirtualDisplayMode(width: UInt(width), height: UInt(height), refreshRate: 60)]
    return display.apply(settings) ? display : nil
}

// The built-in screen's size in points: as it is now if it's on, otherwise as last seen, otherwise 1080p.
func builtInScreenSize() -> CGSize {
    if let screen = NSScreen.screens.first(where: { CGDisplayIsBuiltin($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as! CGDirectDisplayID) != 0 }) {
        let size = [Double(screen.frame.width), Double(screen.frame.height)]
        if UserDefaults.standard.array(forKey: builtInScreenSizeKey) as? [Double] != size {
            UserDefaults.standard.set(size, forKey: builtInScreenSizeKey)
        }
        return screen.frame.size
    }
    if let saved = UserDefaults.standard.array(forKey: builtInScreenSizeKey) as? [Double], saved.count == 2 {
        return CGSize(width: saved[0], height: saved[1])
    }
    return CGSize(width: 1920, height: 1080)
}
