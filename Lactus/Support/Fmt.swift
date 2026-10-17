import Foundation

/// Formátování hodnot. Vše v českém locale zařízení, bez vlastního zaokrouhlování navíc.
enum Fmt {
    static func num(_ v: Double, _ digits: Int = 2) -> String {
        v.formatted(.number.precision(.fractionLength(digits)))
    }

    static func signed(_ v: Double, _ digits: Int = 1) -> String {
        v.formatted(.number.precision(.fractionLength(digits)).sign(strategy: .always()))
    }

    static func percent(_ v: Double, _ digits: Int = 0) -> String {
        num(v, digits) + " %"
    }

    static func bytes(_ b: Int64, memory: Bool = false) -> String {
        ByteCountFormatter.string(fromByteCount: b, countStyle: memory ? .memory : .file)
    }

    static func duration(_ s: TimeInterval) -> String {
        let f = DateComponentsFormatter()
        f.allowedUnits = s >= 86_400 ? [.day, .hour, .minute] : [.hour, .minute, .second]
        f.unitsStyle = .abbreviated
        return f.string(from: max(0, s)) ?? "—"
    }

    static func date(_ d: Date) -> String {
        d.formatted(date: .abbreviated, time: .standard)
    }

    static func xyz(_ x: Double, _ y: Double, _ z: Double, _ digits: Int = 2) -> String {
        "x \(num(x, digits))  y \(num(y, digits))  z \(num(z, digits))"
    }

    static func degrees(_ radians: Double) -> Double {
        radians * 180 / .pi
    }

    static func plusMinus(_ v: Double, _ digits: Int = 0, unit: String) -> String {
        "± \(num(v, digits)) \(unit)"
    }
}
