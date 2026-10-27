import Foundation
import IOKit.hid

/// Control IDs from HID++ feature 0x1B04 (REPROG_CONTROLS_V4).
enum CID {
    static let gestureButton: UInt16 = 0x00C3 // Logitech: "App Switch Gesture"
    static let sensePanel: UInt16 = 0x01A0 // MX Master 4 haptic thumb panel
}

/// Owns the HID++ connections and turns diverted button presses into actions.
final class Driver {
    private static let holdDelay: TimeInterval = 0.4
    private let config: Config
    private let manager: IOHIDManager
    private var transports: [IOHIDDevice: HIDPPTransport] = [:]
    private var mice: [ObjectIdentifier: [UInt8: Mouse]] = [:] // transport -> device index -> mouse
    private var gestureSlots: [ObjectIdentifier: Set<UInt8>] = [:] // slots known to have a gesture button
    private var recoveryPending = false
    private var pendingConfigures: Set<Slot> = []

    private struct Slot: Hashable {
        let transport: ObjectIdentifier
        let index: UInt8
    }

    /// A configured mouse and its gesture-button state.
    final class Mouse {
        let device: HIDPPDevice
        let name: String
        let reprogIndex: UInt8
        let wirelessStatusIndex: UInt8?
        let diverted: [UInt16]
        var pressed: Set<UInt16> = []
        var dx = 0
        var dy = 0
        var gestureFired = false
        var skipNextMove = false
        var panelPresses = 0 // identifies the current Sense Panel press for the hold timer
        var panelHoldFired = false

        init(device: HIDPPDevice, name: String, reprogIndex: UInt8, wirelessStatusIndex: UInt8?, diverted: [UInt16]) {
            self.device = device
            self.name = name
            self.reprogIndex = reprogIndex
            self.wirelessStatusIndex = wirelessStatusIndex
            self.diverted = diverted
        }
    }

    init(config: Config) {
        self.config = config
        manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
    }

    func start() {
        IOHIDManagerSetDeviceMatchingMultiple(manager, hidppMatching() as CFArray)
        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(manager, { context, _, _, device in
            let driver = Unmanaged<Driver>.fromOpaque(context!).takeUnretainedValue()
            DispatchQueue.main.async { driver.deviceAdded(device) }
        }, context)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, { context, _, _, device in
            let driver = Unmanaged<Driver>.fromOpaque(context!).takeUnretainedValue()
            driver.deviceRemoved(device)
        }, context)
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        let result = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        if result != kIOReturnSuccess {
            log(String(format: "IOHIDManagerOpen failed: 0x%08X", result))
        }
    }

    /// Hands the buttons back to the firmware so they behave natively after we exit.
    func stop() {
        for mouse in mice.values.flatMap(\.values) {
            for cid in mouse.diverted { mouse.device.undivert(cid) }
        }
        mice.removeAll()
    }

    // MARK: Device lifecycle

    private func deviceAdded(_ hidDevice: IOHIDDevice) {
        guard transports[hidDevice] == nil else { return }
        let transport = HIDPPTransport(device: hidDevice)
        transports[hidDevice] = transport
        transport.onNotification = { [weak self, weak transport] report in
            guard let self, let transport else { return }
            self.handleNotification(report, from: transport)
        }
        log("Found \(transport.productName) (\(transport.isReceiver ? "receiver" : "Bluetooth"))")
        if transport.isReceiver {
            enableConnectionNotifications(transport)
            for index: UInt8 in 1...6 { configure(transport, index: index) }
        } else {
            configure(transport, index: HIDPP.directIndex)
        }
    }

    private func deviceRemoved(_ hidDevice: IOHIDDevice) {
        guard let transport = transports.removeValue(forKey: hidDevice) else { return }
        mice[ObjectIdentifier(transport)] = nil
        gestureSlots[ObjectIdentifier(transport)] = nil
        log("Lost \(transport.productName)")
    }

    /// Ask the receiver to report device connect/disconnect (register 0x00, "wireless notifications").
    private func enableConnectionNotifications(_ transport: HIDPPTransport) {
        if !transport.setReceiverRegister(0x00, [0x00, 0x01, 0x00]) {
            log("Could not enable receiver connection notifications")
        }
    }

    private func configure(_ transport: HIDPPTransport, index: UInt8) {
        let key = ObjectIdentifier(transport)
        mice[key]?[index] = nil
        let device = HIDPPDevice(transport: transport, index: index)
        // A sleeping mouse answers once it wakes for its next radio poll, which can take ~1 s.
        guard device.ping(timeout: 2.0) != nil,
              let reprogIndex = device.featureIndex(HIDPP.featureReprogControlsV4) else { return }
        let controls = Dictionary(device.controls().map { ($0.cid, $0) }, uniquingKeysWith: { a, _ in a })
        if controls[CID.gestureButton] != nil { gestureSlots[key, default: []].insert(index) }
        var diverted: [UInt16] = []
        if let gesture = controls[CID.gestureButton], gesture.isDivertable {
            let rawXY = config.hasDirectionalGestures && gesture.supportsRawXY
            if device.divert(CID.gestureButton, rawXY: rawXY) { diverted.append(CID.gestureButton) }
        }
        if config.sensePanel != .none || config.sensePanelHold != .none, let panel = controls[CID.sensePanel], panel.isDivertable {
            if device.divert(CID.sensePanel) { diverted.append(CID.sensePanel) }
        }
        guard !diverted.isEmpty else { return }
        let name = device.name ?? "device \(index)"
        let mouse = Mouse(device: device, name: name, reprogIndex: reprogIndex,
                          wirelessStatusIndex: device.featureIndex(HIDPP.featureWirelessStatus), diverted: diverted)
        mice[key, default: [:]][index] = mouse
        log("Configured \(name) (slot \(index)): diverted " + diverted.map { String(format: "0x%04X", $0) }.joined(separator: ", "))
    }

    /// Reconnects usually produce both a receiver link-up and a device "reconfigure me" event;
    /// coalesce them into one configure pass.
    private func scheduleConfigure(_ transport: HIDPPTransport, index: UInt8, after delay: TimeInterval) {
        let slot = Slot(transport: ObjectIdentifier(transport), index: index)
        guard pendingConfigures.insert(slot).inserted else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self, weak transport] in
            guard let self else { return }
            self.pendingConfigures.remove(slot)
            guard let transport, self.transports.values.contains(where: { $0 === transport }) else { return }
            self.configure(transport, index: index)
        }
    }

    /// The gesture button arrived as plain mouse button 6, so a mouse lost its diversion without
    /// telling us (power cycle, deep sleep). Do the click action now and re-divert in the background.
    func nativeGestureButtonPressed() -> Bool {
        guard !transports.isEmpty else { return false }
        run(config.gestureClick, "gesture click (button not diverted)")
        guard !recoveryPending else { return true }
        recoveryPending = true
        DispatchQueue.main.async { [self] in
            recoveryPending = false
            for transport in transports.values {
                let known = gestureSlots[ObjectIdentifier(transport)] ?? []
                let slots: [UInt8] = !known.isEmpty ? Array(known) : transport.isReceiver ? Array(1...6) : [HIDPP.directIndex]
                for index in slots { configure(transport, index: index) }
            }
        }
        return true
    }

    // MARK: Notifications

    private func handleNotification(_ r: [UInt8], from transport: HIDPPTransport) {
        let index = r[1]
        // Receiver: device (re)connected. Diversion does not survive a power cycle, so re-apply it.
        if transport.isReceiver && r[2] == 0x41 && r.count >= 5 {
            let linkUp = r[4] & 0x40 == 0
            if config.verbose { log("slot \(index) link \(linkUp ? "up" : "down")") }
            if linkUp { scheduleConfigure(transport, index: index, after: 0.2) }
            return
        }
        guard let mouse = mice[ObjectIdentifier(transport)]?[index], r.count >= 8 else { return }
        let event = r[3] >> 4
        if r[2] == mouse.wirelessStatusIndex && event == 0 {
            // WIRELESS_DEVICE_STATUS: the device asks software to reconfigure it.
            if config.verbose { log("\(mouse.name) requested reconfiguration") }
            scheduleConfigure(transport, index: index, after: 0.2)
        } else if r[2] == mouse.reprogIndex && event == 0 {
            let cids = stride(from: 4, to: min(r.count, 12), by: 2).map { UInt16(r[$0]) << 8 | UInt16(r[$0 + 1]) }
            buttonsChanged(mouse, pressed: Set(cids.filter { $0 != 0 }))
        } else if r[2] == mouse.reprogIndex && event == 1 {
            let dx = Int(Int16(bitPattern: UInt16(r[4]) << 8 | UInt16(r[5])))
            let dy = Int(Int16(bitPattern: UInt16(r[6]) << 8 | UInt16(r[7])))
            gestureMoved(mouse, dx: dx, dy: dy)
        }
    }

    private func buttonsChanged(_ mouse: Mouse, pressed: Set<UInt16>) {
        let down = pressed.subtracting(mouse.pressed)
        let up = mouse.pressed.subtracting(pressed)
        mouse.pressed = pressed

        if down.contains(CID.gestureButton) {
            mouse.dx = 0
            mouse.dy = 0
            mouse.gestureFired = false
            mouse.skipNextMove = true
            if !config.hasDirectionalGestures { run(config.gestureClick, "gesture click") }
        }
        if up.contains(CID.gestureButton) && config.verbose { log("gesture released: travel dx=\(mouse.dx) dy=\(mouse.dy)") }
        if up.contains(CID.gestureButton) && config.hasDirectionalGestures && !mouse.gestureFired {
            run(config.gestureClick, "gesture click")
        }
        if down.contains(CID.sensePanel) {
            if config.sensePanelHold == .none {
                run(config.sensePanel, "sense panel")
            } else {
                // Tap fires on release; holding past the delay fires the hold action instead.
                mouse.panelPresses += 1
                mouse.panelHoldFired = false
                let press = mouse.panelPresses
                DispatchQueue.main.asyncAfter(deadline: .now() + Self.holdDelay) { [weak self, weak mouse] in
                    guard let self, let mouse, mouse.panelPresses == press, mouse.pressed.contains(CID.sensePanel) else { return }
                    mouse.panelHoldFired = true
                    self.run(self.config.sensePanelHold, "sense panel hold")
                }
            }
        }
        if up.contains(CID.sensePanel) && config.sensePanelHold != .none && !mouse.panelHoldFired {
            run(config.sensePanel, "sense panel tap")
        }
    }

    private func gestureMoved(_ mouse: Mouse, dx: Int, dy: Int) {
        guard mouse.pressed.contains(CID.gestureButton), !mouse.gestureFired else { return }
        // The first raw XY report after a press holds a large value that isn't movement while
        // held (it follows pointer movement between presses), so drop it.
        if mouse.skipNextMove {
            mouse.skipNextMove = false
            return
        }
        mouse.dx += dx
        mouse.dy += dy
        let threshold = config.gestureThreshold
        guard abs(mouse.dx) >= threshold || abs(mouse.dy) >= threshold else { return }
        mouse.gestureFired = true
        if abs(mouse.dx) > abs(mouse.dy) {
            mouse.dx < 0 ? run(config.gestureLeft, "gesture left") : run(config.gestureRight, "gesture right")
        } else {
            mouse.dy < 0 ? run(config.gestureUp, "gesture up") : run(config.gestureDown, "gesture down")
        }
    }

    private func run(_ action: Action, _ trigger: String) {
        if config.verbose { log("\(trigger) -> \(action)") }
        action.perform()
    }
}
