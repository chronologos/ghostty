#if os(macOS)
import Foundation

/// A pane's display alias lives daemon-side as the zmx session label `ghostty_name=<v>`,
/// so it travels with the session (any fork instance attaching to that host sees the same
/// name) instead of being trapped in this machine's fork.json — `paneLabels` is now the
/// write-through cache of it (`AliasSync`). zmx label values are restricted to
/// `[A-Za-z0-9._-]` (label.zig `assertLabel` — the CLI round-trips labels as
/// space-separated `k=v` argv), so free-form names are escaped: `_` is the escape prefix
/// (`%` isn't in the charset), every disallowed UTF-8 byte and `_` itself become `_HH`.
/// Decoding is lenient — a `_` not followed by two hex digits stays literal — so a label
/// hand-set with `zmx set . ghostty_name=my_thing` still reads as `my_thing`.
enum AliasCodec {
    static let key = "ghostty_name"
    /// `ZmxAdapter.parse` keys its token dict on `Substring` — one shared instance instead
    /// of a fresh conversion per parsed line.
    static let keySub = Substring(key)
    /// Display cap. Also applied *before* encoding so a pasted wall of text can't become
    /// an arbitrarily long argv token on the `zmx set` command line (an escaped byte is
    /// 3× a plain one, and a scalar can be several bytes — the cap bounds it at ≤768 B).
    static let cap = 64

    private static func passthrough(_ b: UInt8) -> Bool {
        (UInt8(ascii: "a")...UInt8(ascii: "z")).contains(b)
            || (UInt8(ascii: "A")...UInt8(ascii: "Z")).contains(b)
            || (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(b)
            || b == UInt8(ascii: ".") || b == UInt8(ascii: "-")
    }

    /// Wire form. Every byte of the result is inside zmx's label charset.
    static func encode(_ s: String) -> String {
        var out = ""
        for b in String(s.prefix(cap)).utf8 {
            if passthrough(b) { out.unicodeScalars.append(Unicode.Scalar(b)) }
            else { out += String(format: "_%02X", b) }
        }
        return out
    }

    static func decode(_ s: Substring) -> String {
        let a = Array(s.utf8)
        var bytes: [UInt8] = []
        var i = 0
        while i < a.count {
            if a[i] == UInt8(ascii: "_"), i + 2 < a.count, let hi = hex(a[i + 1]), let lo = hex(a[i + 2]) {
                bytes.append(hi << 4 | lo)
                i += 3
            } else {
                bytes.append(a[i])
                i += 1
            }
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    /// Daemon label (raw `zmx list` field) → display string. This is a trust boundary: the
    /// label is settable by anyone who can reach the session's socket, and zmx enforces the
    /// value charset only in its *CLI* — the daemon stores IPC-set bytes verbatim, tab and
    /// newline included, which is enough to forge whole `zmx list` rows. So a raw value
    /// with any byte outside the codec's own output charset didn't come from a legitimate
    /// `zmx set` and is rejected outright rather than leniently decoded.
    static func alias(from raw: Substring?) -> String? {
        guard let raw, !raw.isEmpty,
              raw.utf8.allSatisfy({ passthrough($0) || $0 == UInt8(ascii: "_") })
        else { return nil }
        return sanitize(decode(raw))
    }

    /// The one display sanitizer for aliases from *any* source — decoded daemon labels and
    /// user-typed renames alike, so the value the cache holds and the value the daemon will
    /// echo back are byte-identical (the pending-write mask compares them). Strips C0/C1
    /// controls and Unicode format scalars (bidi overrides, zero-width, isolates — an alias
    /// is a pane's *primary* identity in the sidebar, so it must not visually reorder or
    /// hide the id shown beside it), trims, caps at `cap`, and folds empty to nil so a blank
    /// name falls back to the session id instead of an empty row.
    static func sanitize(_ s: String) -> String? {
        var out = ""
        for u in stripControl(s, max: .max).unicodeScalars
        where u.properties.generalCategory != .format {
            out.unicodeScalars.append(u)
        }
        let clean = String(out.trimmingCharacters(in: .whitespaces).prefix(cap))
        return clean.isEmpty ? nil : clean
    }

    private static func hex(_ b: UInt8) -> UInt8? {
        switch b {
        case UInt8(ascii: "0")...UInt8(ascii: "9"): b - UInt8(ascii: "0")
        case UInt8(ascii: "A")...UInt8(ascii: "F"): b - UInt8(ascii: "A") + 10
        case UInt8(ascii: "a")...UInt8(ascii: "f"): b - UInt8(ascii: "a") + 10
        default: nil
        }
    }
}
#endif
