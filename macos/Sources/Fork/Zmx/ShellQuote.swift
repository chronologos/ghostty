#if os(macOS)
/// POSIX single-quote escaping. Only `'` is special inside single quotes; close, escape, reopen.
func shq(_ s: String) -> String {
    "'" + s.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
}

func shq(_ argv: [String]) -> String {
    argv.map(shq).joined(separator: " ")
}

/// Strip C0/C1/DEL + truncate. For remote-origin strings that reach the local pty via
/// `printf %s` — `shq` blocks shell injection but not terminal-escape injection.
func stripControl(_ s: String, max: Int) -> String {
    var out = ""
    for u in s.unicodeScalars.prefix(max) where
        u.value >= 0x20 && u.value != 0x7F && !(0x80...0x9F).contains(u.value) {
        out.unicodeScalars.append(u)
    }
    return out
}
#endif
