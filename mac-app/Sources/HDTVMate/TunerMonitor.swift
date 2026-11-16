import Foundation
import IOKit
import IOKit.usb

/// Watches the USB bus for the HDTV Mate (23e2:2b02) using IOKit notifications,
/// so the app knows the moment the stick is plugged in or pulled out.
final class TunerMonitor {
    static let vendorID = 0x23e2
    static let productID = 0x2b02

    /// (connected, isInitialState). Always called on the main queue.
    var onChange: ((Bool, Bool) -> Void)?

    private var port: IONotificationPortRef?
    private var addedIter: io_iterator_t = 0
    private var removedIter: io_iterator_t = 0
    private var count = 0
    private var reported: Bool?
    private var pendingRemoval: DispatchWorkItem?

    func start() {
        guard port == nil, let p = IONotificationPortCreate(kIOMainPortDefault) else { return }
        port = p
        IONotificationPortSetDispatchQueue(p, DispatchQueue.main)
        let ctx = Unmanaged.passUnretained(self).toOpaque()

        let added: IOServiceMatchingCallback = { (ctx: UnsafeMutableRawPointer?, iter: io_iterator_t) in
            guard let ctx = ctx else { return }
            Unmanaged<TunerMonitor>.fromOpaque(ctx).takeUnretainedValue().handle(iter, added: true)
        }
        let removed: IOServiceMatchingCallback = { (ctx: UnsafeMutableRawPointer?, iter: io_iterator_t) in
            guard let ctx = ctx else { return }
            Unmanaged<TunerMonitor>.fromOpaque(ctx).takeUnretainedValue().handle(iter, added: false)
        }
        IOServiceAddMatchingNotification(p, kIOFirstMatchNotification, TunerMonitor.matching(), added, ctx, &addedIter)
        IOServiceAddMatchingNotification(p, kIOTerminatedNotification, TunerMonitor.matching(), removed, ctx, &removedIter)

        // Draining the iterators arms the notifications and gives the current state.
        count = TunerMonitor.drain(addedIter)
        _ = TunerMonitor.drain(removedIter)
        report(count > 0, initial: true)
    }

    private static func matching() -> CFMutableDictionary {
        let d: NSMutableDictionary = IOServiceMatching("IOUSBHostDevice") as NSMutableDictionary
        d["idVendor"] = vendorID
        d["idProduct"] = productID
        return d as CFMutableDictionary
    }

    private static func drain(_ iter: io_iterator_t) -> Int {
        var n = 0
        while true {
            let s: io_object_t = IOIteratorNext(iter)
            if s == 0 { break }
            n += 1
            IOObjectRelease(s)
        }
        return n
    }

    private func handle(_ iter: io_iterator_t, added: Bool) {
        let n = TunerMonitor.drain(iter)
        guard n > 0 else { return }
        count = max(0, count + (added ? n : -n))
        if count > 0 {
            pendingRemoval?.cancel()
            pendingRemoval = nil
            report(true, initial: false)
        } else {
            // Wait a moment before announcing a removal, in case the stick re-enumerates.
            pendingRemoval?.cancel()
            let work = DispatchWorkItem { [weak self] in
                guard let self = self, self.count == 0 else { return }
                self.report(false, initial: false)
            }
            pendingRemoval = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: work)
        }
    }

    private func report(_ connected: Bool, initial: Bool) {
        if !initial && reported == connected { return }
        reported = connected
        onChange?(connected, initial)
    }
}
