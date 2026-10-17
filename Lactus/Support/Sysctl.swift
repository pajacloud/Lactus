import Darwin
import Foundation

/// Tenký obal nad `sysctlbyname`. Všechny klíče, které čteme, jsou veřejné a bez oprávnění.
enum Sysctl {
    static func string(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return CStrings.string(buffer)
    }

    /// Vrátí celé číslo bez ohledu na to, zda je klíč 32- nebo 64bitový.
    static func integer(_ name: String) -> Int64? {
        var value: Int64 = 0
        var size = MemoryLayout<Int64>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        if size == MemoryLayout<Int32>.size {
            return Int64(Int32(truncatingIfNeeded: value))
        }
        return value
    }

    static func bootTime() -> Date? {
        var tv = timeval()
        var size = MemoryLayout<timeval>.size
        guard sysctlbyname("kern.boottime", &tv, &size, nil, 0) == 0, tv.tv_sec > 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(tv.tv_sec) + TimeInterval(tv.tv_usec) / 1_000_000)
    }
}

enum CStrings {
    /// Převod C bufferu na String bez zastaralého `String(cString: [CChar])`.
    static func string(_ buffer: [CChar]) -> String {
        let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self)
    }
}
