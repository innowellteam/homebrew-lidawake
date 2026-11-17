import CoreGraphics
import Foundation
import IOKit.pwr_mgt

// Ticking "Virtual Screen" adds a 1920x1080 screen that exists only in software (CGVirtualDisplay.h).
// macOS treats it as an external monitor. Close the lid with the real monitor off, and windows move
// onto it and keep drawing, so browser automation such as Claude in Chrome keeps working. It's also a
// fixed-size screen to record demos on. It's there while WellAwake runs with the option ticked.
let virtualScreenKey = "VirtualScreen"

final class VirtualScreen {
    private var display: CGVirtualDisplay?
    private var displaySleepAssertion: IOPMAssertionID?

    var isConnected: Bool { display != nil }

    // Connects or disconnects the screen. While WellAwake is keeping the Mac awake, idle display sleep
    // is held off too: it would lock the Mac, and windows stop drawing behind the lock screen.
    func update(enabled: Bool, keepingAwake: Bool) {
        if enabled, display == nil {
            display = makeVirtualDisplay()
        } else if !enabled {
            display = nil
        }
        let holdDisplayAwake = display != nil && keepingAwake
        if holdDisplayAwake, displaySleepAssertion == nil {
            var assertion: IOPMAssertionID = 0
            if IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                           "WellAwake is keeping the virtual screen awake" as CFString, &assertion) == kIOReturnSuccess {
                displaySleepAssertion = assertion
            } else {
                NSLog("WellAwake: couldn't hold off display sleep for the virtual screen")
            }
        } else if !holdDisplayAwake, let assertion = displaySleepAssertion {
            IOPMAssertionRelease(assertion)
            displaySleepAssertion = nil
        }
    }
}

// Nil if macOS refused it. The vendor, product and serial numbers are made up but fixed, so macOS
// remembers where you put the screen in Displays settings.
func makeVirtualDisplay() -> CGVirtualDisplay? {
    let descriptor = CGVirtualDisplayDescriptor()
    descriptor.setDispatchQueue(DispatchQueue.main)
    descriptor.name = "WellAwake"
    descriptor.maxPixelsWide = 1920
    descriptor.maxPixelsHigh = 1080
    descriptor.sizeInMillimeters = CGSize(width: 527, height: 296) // a 24-inch 16:9 monitor
    descriptor.vendorID = 0x5741
    descriptor.productID = 0x0001
    descriptor.serialNum = 1
    guard let display = CGVirtualDisplay(descriptor: descriptor) else { return nil }
    let settings = CGVirtualDisplaySettings()
    settings.hiDPI = 0
    settings.modes = [CGVirtualDisplayMode(width: 1920, height: 1080, refreshRate: 60)]
    return display.apply(settings) ? display : nil
}
