#if os(macOS)
import SwiftUI

/// Trailing metadata for a zmx session row. The client count alone is a poor "in use"
/// signal — it counts attached *viewers* (live `zmx attach` clients), so a detached session
/// with a CC agent working inside, or one whose only presence is a cold-restored placeholder
/// pane in the sidebar, reads as an orphaned `0`. The sparkle and sidebar glyphs carry those
/// two signals so "0 people + old age" stops looking like "safe to kill". The age is the
/// session's *creation* age (`zmx list` has no activity field).
struct SessionMetaLabel: View {
    @Environment(\.forkTokens) private var tokens

    let entry: ZmxAdapter.ListEntry
    /// Session is already open as a pane in the sidebar (even a cold placeholder).
    var inSidebar: Bool = false
    /// Last-known CC session running inside it (attached or not), from the poll's `ccLive`.
    var ccInfo: CCProbe.Info? = nil

    var body: some View {
        HStack(spacing: 4) {
            if let ccInfo {
                // Busy outranks blocked, same as PaneMachine.dot — CC doesn't reliably
                // rewrite `tempo` after a reply, so a stale "needs input" must not paint
                // this red while the sidebar rail shows the same session working.
                let busy = ccInfo.status == "busy"
                Image(systemName: "sparkles")
                    .font(.system(size: 8))
                    .foregroundStyle(busy ? Theme.clay
                                     : ccInfo.isBlocked ? Theme.blocked : tokens.textSecondary)
                    .opacity(busy || ccInfo.isBlocked ? 1 : 0.6)
                    .help(ccHelp(ccInfo, busy: busy))
            }
            if inSidebar {
                Image(systemName: "sidebar.left")
                    .font(.system(size: 8))
                    .foregroundStyle(tokens.textSecondary)
                    .help("Already open as a pane in the sidebar")
            }
            HStack(spacing: 2) {
                Image(systemName: "person.fill").font(.system(size: 8))
                Text("\(entry.clients)")
            }
            .foregroundStyle(entry.clients > 0 ? Theme.clay : tokens.textSecondary)
            .help(entry.clients == 1 ? "1 attached client" : "\(entry.clients) attached clients")
            Text("·").foregroundStyle(tokens.textSecondary)
            // Creation age in plain secondary, not the recency ramp — an old-but-busy
            // session must not render faded as if abandoned.
            Text("\(entry.created.shortAge) old").foregroundStyle(tokens.textSecondary)
                .help("Created \(entry.created.shortAge) ago")
            if entry.external {
                Text("ext").foregroundStyle(tokens.textSecondary)
            }
        }
        // 10pt matches the sidebar's small-text scale (PR48 bumped that +1pt; sheets lagged).
        .font(.system(size: 10))
    }

    private func ccHelp(_ info: CCProbe.Info, busy: Bool) -> String {
        let state = busy ? "working" : info.isBlocked ? "needs input" : "idle"
        return ["CC \(state)", info.name, info.attention]
            .compactMap { $0 }.joined(separator: " — ")
    }
}

extension Date {
    var shortAge: String {
        let s = max(0, Int(Date().timeIntervalSince(self)))
        switch s {
        case ..<60:      return "\(s)s"
        // Exact minutes below 15m ("just touched this"); 15–60m floors to the nearest 5 so
        // a list of ages (host-sheet sessions, row hover peeks) doesn't increment a
        // different entry on every refresh tick.
        case ..<900:     return "\(s / 60)m"
        case ..<3600:    return "\(s / 300 * 5)m"
        case ..<86400:   return "\(s / 3600)h"
        case ..<604800:  return "\(s / 86400)d"
        default:         return "\(s / 604800)w"
        }
    }
}
#endif
