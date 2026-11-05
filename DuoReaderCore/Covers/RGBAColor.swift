import CoreGraphics
import Foundation

/// A colour that can be saved in a cover design. Components are sRGB, 0 to 1.
public struct RGBAColor: Codable, Hashable, Sendable {
    public var red: Double
    public var green: Double
    public var blue: Double
    public var alpha: Double

    public init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = Self.clamp(red)
        self.green = Self.clamp(green)
        self.blue = Self.clamp(blue)
        self.alpha = Self.clamp(alpha)
    }

    /// Parses `#RRGGBB` or `#RRGGBBAA`, with or without the `#`.
    public init?(hex: String) {
        var string = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if string.hasPrefix("#") { string.removeFirst() }
        guard string.count == 6 || string.count == 8, let value = UInt64(string, radix: 16) else {
            return nil
        }
        if string.count == 6 {
            self.init(
                red: Double((value >> 16) & 0xFF) / 255,
                green: Double((value >> 8) & 0xFF) / 255,
                blue: Double(value & 0xFF) / 255
            )
        } else {
            self.init(
                red: Double((value >> 24) & 0xFF) / 255,
                green: Double((value >> 16) & 0xFF) / 255,
                blue: Double((value >> 8) & 0xFF) / 255,
                alpha: Double(value & 0xFF) / 255
            )
        }
    }

    /// `#RRGGBB`, or `#RRGGBBAA` when the colour isn't opaque.
    public var hex: String {
        func byte(_ value: Double) -> String {
            String(format: "%02X", Int((value * 255).rounded()))
        }
        let rgb = "#" + byte(red) + byte(green) + byte(blue)
        return alpha < 1 ? rgb + byte(alpha) : rgb
    }

    /// WCAG relative luminance, 0 (black) to 1 (white).
    public var luminance: Double {
        func linear(_ c: Double) -> Double {
            c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }

    /// WCAG contrast ratio between two colours, 1 to 21.
    public func contrastRatio(with other: RGBAColor) -> Double {
        let a = luminance + 0.05
        let b = other.luminance + 0.05
        return max(a, b) / min(a, b)
    }

    /// Near-black or near-white, whichever reads better on this colour.
    public var contrastingText: RGBAColor {
        contrastRatio(with: .ink) >= contrastRatio(with: .paper) ? .ink : .paper
    }

    /// Blends towards `other` by `amount` (0 keeps this colour, 1 gives `other`).
    public func mixed(with other: RGBAColor, amount: Double) -> RGBAColor {
        let t = Self.clamp(amount)
        return RGBAColor(
            red: red + (other.red - red) * t,
            green: green + (other.green - green) * t,
            blue: blue + (other.blue - blue) * t,
            alpha: alpha + (other.alpha - alpha) * t
        )
    }

    public func darkened(_ amount: Double) -> RGBAColor { mixed(with: .black, amount: amount) }
    public func lightened(_ amount: Double) -> RGBAColor { mixed(with: .white, amount: amount) }

    public var cgColor: CGColor {
        CGColor(srgbRed: red, green: green, blue: blue, alpha: alpha)
    }

    public static let white = RGBAColor(red: 1, green: 1, blue: 1)
    public static let black = RGBAColor(red: 0, green: 0, blue: 0)
    /// The text colour used on light covers.
    public static let ink = RGBAColor(red: 0.08, green: 0.08, blue: 0.09)
    /// The text colour used on dark covers.
    public static let paper = RGBAColor(red: 0.98, green: 0.97, blue: 0.94)
    /// Off-white for page edges and minimal spines.
    public static let cream = RGBAColor(red: 0.95, green: 0.92, blue: 0.85)
    /// Antique gold for cloth-bound lettering.
    public static let gold = RGBAColor(red: 0.83, green: 0.69, blue: 0.38)

    private static func clamp(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return min(max(value, 0), 1)
    }
}

extension RGBAColor {
    /// A pleasant, deterministic colour for a book with no artwork, picked
    /// from its title so the same book always gets the same colour.
    public static func generated(for seed: String) -> RGBAColor {
        let palette: [RGBAColor] = [
            RGBAColor(red: 0.16, green: 0.25, blue: 0.40), // navy
            RGBAColor(red: 0.45, green: 0.13, blue: 0.16), // oxblood
            RGBAColor(red: 0.13, green: 0.33, blue: 0.27), // forest
            RGBAColor(red: 0.55, green: 0.38, blue: 0.16), // ochre
            RGBAColor(red: 0.30, green: 0.20, blue: 0.40), // plum
            RGBAColor(red: 0.18, green: 0.40, blue: 0.45), // teal
            RGBAColor(red: 0.62, green: 0.30, blue: 0.22), // terracotta
            RGBAColor(red: 0.22, green: 0.22, blue: 0.24), // charcoal
            RGBAColor(red: 0.74, green: 0.62, blue: 0.45), // sand
            RGBAColor(red: 0.36, green: 0.42, blue: 0.24), // olive
        ]
        // FNV-1a, so the choice is stable across launches (hashValue isn't).
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in seed.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return palette[Int(hash % UInt64(palette.count))]
    }
}
