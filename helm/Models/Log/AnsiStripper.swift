import Foundation

/// Strips ANSI/VT escape sequences from raw PTY bytes so a `pipe-pane` capture is
/// readable in a SwiftUI `Text` (M6 — raw bytes incl. CSI/OSC/SGR are garbage).
/// Pure, no I/O. Handles the common families:
///   - CSI:  ESC [ … <final 0x40–0x7E>
///   - OSC:  ESC ] … (BEL | ESC \)
///   - other 2-byte escapes: ESC <single byte>
/// plus stray control chars (keeps \n, \t).
enum AnsiStripper {
    static func strip(_ input: String) -> String {
        var out = String()
        out.reserveCapacity(input.count)
        let scalars = Array(input.unicodeScalars)
        var i = 0
        let esc: Unicode.Scalar = "\u{1B}"
        let bel: Unicode.Scalar = "\u{07}"

        while i < scalars.count {
            let s = scalars[i]
            if s == esc {
                let next = i + 1 < scalars.count ? scalars[i + 1] : nil
                if next == "[" {
                    // CSI: skip until a final byte in 0x40–0x7E.
                    i += 2
                    while i < scalars.count {
                        let c = scalars[i]
                        i += 1
                        if c.value >= 0x40 && c.value <= 0x7E { break }
                    }
                    continue
                } else if next == "]" {
                    // OSC: skip until BEL or ESC \ (ST).
                    i += 2
                    while i < scalars.count {
                        let c = scalars[i]
                        if c == bel { i += 1; break }
                        if c == esc && i + 1 < scalars.count && scalars[i + 1] == "\\" {
                            i += 2; break
                        }
                        i += 1
                    }
                    continue
                } else {
                    // Other escape: skip ESC + one byte.
                    i += 2
                    continue
                }
            }
            // Drop other C0 control chars except tab/newline/carriage-return.
            if s.value < 0x20 && s != "\n" && s != "\t" && s != "\r" {
                i += 1
                continue
            }
            out.unicodeScalars.append(s)
            i += 1
        }
        return out
    }
}
