import Foundation
import IOKit.pwr_mgt

final class PowerObserver {
    private var rootPort: io_connect_t = 0
    private var notifier: io_object_t = 0
    private var port: IONotificationPortRef?
    private let willSleep: (@escaping () -> Void) -> Void

    init(willSleep: @escaping (@escaping () -> Void) -> Void) {
        self.willSleep = willSleep
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        rootPort = IORegisterForSystemPower(refcon, &port, { refcon, _, type, arg in
            guard let refcon else { return }
            Unmanaged<PowerObserver>.fromOpaque(refcon).takeUnretainedValue().handle(type, arg)
        }, &notifier)
        if rootPort == 0 { log.error("IORegisterForSystemPower failed"); return }
        CFRunLoopAddSource(CFRunLoopGetMain(), IONotificationPortGetRunLoopSource(port).takeUnretainedValue(), .commonModes)
    }

    private func handle(_ type: natural_t, _ arg: UnsafeMutableRawPointer?) {
        let id = Int(bitPattern: arg)
        switch type {
        case 0xE000_0270: // kIOMessageCanSystemSleep
            IOAllowPowerChange(rootPort, id)
        case 0xE000_0280: // kIOMessageSystemWillSleep
            log.info("system will sleep")
            willSleep { [rootPort] in IOAllowPowerChange(rootPort, id) }
        default:
            break
        }
    }
}
