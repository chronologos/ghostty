#if os(macOS)
/// POSIX single-quote escaping. Only `'` is special inside single quotes; close, escape, reopen.
func shq(_ s: String) -> String {
    "'" + s.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
}

func shq(_ argv: [String]) -> String {
    argv.map(shq).joined(separator: " ")
}
#endif
