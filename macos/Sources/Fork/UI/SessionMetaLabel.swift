#if os(macOS)
import SwiftUI

/// Leading name for a zmx session row (⌘T picker, Manage Hosts): the alias (daemon-side
/// `ghostty_name`) leads and the session id demotes to a dim mono line under it; with no
/// alias the id is the name. The dual of `SessionMetaLabel` — both lists share the pair so
/// their typography can't drift.
struct SessionNameLabel: View {
    @Environment(\.forkTokens) private var tokens

    let entry: ZmxAdapter.ListEntry

    var body: some View {
        // A seeded session is labeled with its own id — one line, not "proj" over a dim
        // "proj". Capped alias (64) still can't take the row: single-line, and the parent
        // HStack's trailing `SessionMetaLabel` keeps its width.
        if let alias = entry.alias, alias != entry.name {
            Text(alias).font(.system(size: 12))
                .lineLimit(1).truncationMode(.middle)
            Text(entry.name).font(.system(size: 10, design: .monospaced))
                .lineLimit(1).truncationMode(.middle)
                .foregroundStyle(tokens.textSecondary)
        } else {
            Text(entry.name).font(.system(size: 12, design: .monospaced))
                .lineLimit(1).truncationMode(.middle)
        }
        // Where it is (and, for a session that was created to run something, what): with
        // twenty `shell-xxx` rows on a host the name alone doesn't say which one is sitting
        // in the repo you want — or which one the Kill button beside it would take out.
        // The daemon reports both in the same `zmx list` row. `.head` truncation: the leaf
        // of a path is the part that identifies it.
        if let where_ = Self.whereLine(entry) {
            Text(where_).font(.system(size: 10, design: .monospaced))
                .lineLimit(1).truncationMode(.head)
                .foregroundStyle(tokens.textTertiary)
        }
    }

    /// `~/work/api  ·  $ zig build` — cwd with the home prefix folded, plus the creating
    /// command unless it's one of the fork's own wrappers (`restoreCmd`/`smartJumpCmd` both
    /// start `sh -c`, which says nothing to the user). Pure, for tests.
    static func whereLine(_ e: ZmxAdapter.ListEntry) -> String? {
        let cwd = e.cwd.map { $0.replacingOccurrences(
            of: #"^/(Users|home)/[^/]+"#, with: "~", options: .regularExpression) }
        let cmd = e.cmd.flatMap { $0.hasPrefix("sh -c") || $0.hasPrefix("'sh' '-c'") ? nil : "$ \($0)" }
        let parts = [cwd, cmd].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: "  ·  ")
    }
}

/// Row for a session whose daemon didn't answer `zmx list` (`ZmxAdapter.Unresponsive`):
/// the name, dimmed, and why. It has no pid/clients/age to show — the point is that it is
/// *there*, so it can be attached or killed and isn't mistaken for gone.
struct UnresponsiveSessionLabel: View {
    @Environment(\.forkTokens) private var tokens

    let entry: ZmxAdapter.Unresponsive

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(entry.name).font(.system(size: 12, design: .monospaced))
                .lineLimit(1).truncationMode(.middle)
                .foregroundStyle(tokens.textSecondary)
            HStack(spacing: 3) {
                Image(systemName: "exclamationmark.circle").font(.system(size: 8))
                Text("not responding (\(entry.err)) — probably busy, still running")
            }
            .font(.system(size: 10)).foregroundStyle(tokens.textTertiary)
        }
        .help("The zmx daemon for this session didn't answer within 1s. zmx treats that as "
              + "\"may just be busy\" and so does the fork: the session and anything in it are very likely alive.")
    }
}

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
            if let ended = entry.ended {
                // A `zmx run` task that has finished: how it ended beats how old it is —
                // "0 clients · 3h old" otherwise reads exactly like an abandoned live shell.
                let ok = (entry.exitCode ?? 0) == 0
                Text("\(ok ? "✓" : "✗") exit \(entry.exitCode ?? 0) · \(ended.shortAge) ago")
                    .foregroundStyle(ok ? tokens.textSecondary : Theme.error)
                    .help("Task finished \(ended.shortAge) ago; session created \(entry.created.shortAge) ago")
            } else {
                Text("\(entry.created.shortAge) old").foregroundStyle(tokens.textSecondary)
                    .help("Created \(entry.created.shortAge) ago")
            }
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
