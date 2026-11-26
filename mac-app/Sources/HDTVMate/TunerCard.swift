import Foundation
import IOKit
import DiskArbitration

/// Finds the SD card in the HDTV Mate's own card reader.
///
/// The stick holds two USB hubs on one plug: a USB 2 hub with the tuner and a
/// USB 3 hub with a Genesys card reader. macOS records on the tuner's USB 2 root
/// port which USB 3 port is its partner on the same connector ("UsbCompanionSS"),
/// so a volume whose device sits under that USB 3 port is the stick's own card,
/// not some other card reader. Works when the stick is plugged straight into the
/// Mac; behind an external hub this returns nil and the user can pick a folder.
enum TunerCard {
    struct Port: Equatable {
        let controller: String
        let number: Data
    }

    /// Mount point of the SD card in the tuner, if one is inserted and mounted.
    static func mountedVolume() -> URL? {
        guard let port = tunerCompanionPort() else { return nil }
        guard let session = DASessionCreate(kCFAllocatorDefault),
              let volumes = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: nil,
                                                                  options: [.skipHiddenVolumes]) else { return nil }
        for url in volumes where url.path.hasPrefix("/Volumes/") {
            guard let disk = DADiskCreateFromVolumePath(kCFAllocatorDefault, session, url as CFURL) else { continue }
            let media: io_service_t = DADiskCopyIOMedia(disk)
            guard media != 0 else { continue }
            let match: Bool = isUnder(port, media)
            IOObjectRelease(media)
            if match { return url }
        }
        return nil
    }

    /// The USB 3 root port paired with the tuner's USB 2 root port.
    static func tunerCompanionPort() -> Port? {
        let matching: NSMutableDictionary = IOServiceMatching("IOUSBHostDevice") as NSMutableDictionary
        matching["idVendor"] = TunerMonitor.vendorID
        matching["idProduct"] = TunerMonitor.productID
        var entry: io_registry_entry_t = IOServiceGetMatchingService(kIOMainPortDefault, matching as CFDictionary)
        guard entry != 0 else { return nil }
        for _ in 0..<16 {
            for key in ["UsbCompanionSS", "UsbCompanionSSP"] {
                if let d = property(entry, key) as? [String: Any],
                   let controller = d["UsbCompanionControllerName"] as? String,
                   let number = d["UsbCompanionPortNumber"] as? Data {
                    IOObjectRelease(entry)
                    return Port(controller: controller, number: number)
                }
            }
            guard let parent = parent(of: entry) else { break }
            IOObjectRelease(entry)
            entry = parent
        }
        IOObjectRelease(entry)
        return nil
    }

    /// True if `service` hangs below the given root port (port number + controller name match).
    private static func isUnder(_ port: Port, _ service: io_registry_entry_t) -> Bool {
        IOObjectRetain(service)
        var entry: io_registry_entry_t = service
        defer { IOObjectRelease(entry) }
        for _ in 0..<48 {
            guard let up = parent(of: entry) else { return false }
            if let n = property(entry, "port") as? Data, n == port.number, name(of: up) == port.controller {
                IOObjectRelease(up)
                return true
            }
            IOObjectRelease(entry)
            entry = up
        }
        return false
    }

    private static func property(_ entry: io_registry_entry_t, _ key: String) -> Any? {
        IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    }

    private static func parent(of entry: io_registry_entry_t) -> io_registry_entry_t? {
        var p: io_registry_entry_t = 0
        guard IORegistryEntryGetParentEntry(entry, kIOServicePlane, &p) == KERN_SUCCESS, p != 0 else { return nil }
        return p
    }

    private static func name(of entry: io_registry_entry_t) -> String {
        var buf = [CChar](repeating: 0, count: 128)
        guard IORegistryEntryGetName(entry, &buf) == KERN_SUCCESS else { return "" }
        return String(cString: buf)
    }

    /// Free space on the volume holding `url`, in bytes.
    static func freeBytes(at url: URL) -> Int64? {
        let v = try? url.resourceValues(forKeys: [.volumeAvailableCapacityKey])
        return v?.volumeAvailableCapacity.map(Int64.init)
    }
}
