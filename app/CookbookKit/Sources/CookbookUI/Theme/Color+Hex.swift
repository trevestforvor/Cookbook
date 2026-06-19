import SwiftUI

public extension Color {
    /// Creates a `Color` from a hex string in sRGB space.
    ///
    /// Accepts the following formats (a leading `#`, `0x`, spaces, and other
    /// non-hex-digit characters are stripped before parsing):
    /// - `RGB`   (3 digits, 12-bit, each nibble expanded ×17 to a full byte)
    /// - `RRGGBB` (6 digits, 24-bit, opaque)
    /// - `AARRGGBB` (8 digits, 32-bit, with alpha)
    ///
    /// Any unrecognised length falls back to opaque black so the initializer is
    /// non-failable and safe to use inline in token definitions.
    ///
    /// ## The precedence fix
    /// The original `design.md` draft expanded the 3-digit form with
    /// `int >> 8 * 4`. Because multiplicative `*` binds tighter than the shift
    /// `>>`, that parses as `int >> (8 * 4)` — i.e. `int >> 32` — which is a
    /// no-op/garbage shift for a 12-bit value and silently produced the wrong
    /// red channel. The correct intent is to take the high nibble
    /// (`int >> 8`, bits 8–11) and expand it to a byte by multiplying by 17
    /// (`0x11`), which maps `0x0…0xF` onto `0x00…0xFF`. The 6- and 8-digit
    /// paths were always fine and are unchanged.
    init(hex: String) {
        let cleaned = hex
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "#", with: "")
            .replacingOccurrences(of: "0x", with: "")
            .replacingOccurrences(of: "0X", with: "")

        var int: UInt64 = 0
        Scanner(string: cleaned).scanHexInt64(&int)

        let a, r, g, b: UInt64
        switch cleaned.count {
        case 3: // RGB (12-bit) — expand each 4-bit nibble to 8 bits via ×17 (0x11).
            // FIX: parenthesize the shift so it is NOT swallowed by `* 17`'s
            // higher precedence (the design.md `>> 8 * 4` bug). Each channel
            // nibble (0x0…0xF) maps to a full byte (0x00…0xFF).
            (a, r, g, b) = (
                255,
                (int >> 8 & 0xF) * 17,
                (int >> 4 & 0xF) * 17,
                (int & 0xF) * 17
            )
        case 6: // RRGGBB (24-bit), opaque.
            (a, r, g, b) = (
                255,
                int >> 16 & 0xFF,
                int >> 8 & 0xFF,
                int & 0xFF
            )
        case 8: // AARRGGBB (32-bit), with alpha.
            (a, r, g, b) = (
                int >> 24 & 0xFF,
                int >> 16 & 0xFF,
                int >> 8 & 0xFF,
                int & 0xFF
            )
        default: // Unrecognised — opaque black.
            (a, r, g, b) = (255, 0, 0, 0)
        }

        self.init(
            .sRGB,
            red: Double(r) / 255.0,
            green: Double(g) / 255.0,
            blue: Double(b) / 255.0,
            opacity: Double(a) / 255.0
        )
    }
}
