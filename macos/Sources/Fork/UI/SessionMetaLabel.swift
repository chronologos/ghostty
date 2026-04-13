#if os(macOS)
import SwiftUI

/// Trailing metadata for a zmx session row. Client count is the actionable bit:
/// 0 → dim (orphaned, safe to take); ≥1 → accent (someone's attached).
struct SessionMetaLabel: View {
    let entry: ZmxAdapter.ListEntry

    var body: some View {
        HStack(spacing: 4) {
            HStack(spacing: 2) {
                Image(systemName: "person.fill").font(.system(size: 8))
                Text("\(entry.clients)")
            }
            .foregroundStyle(entry.clients > 0 ? Color.accentColor : Color.secondary)
            Text("·").foregroundStyle(.secondary)
            Text(entry.created.shortAge).foregroundStyle(.secondary)
            if entry.external {
                Text("ext").foregroundStyle(.secondary)
            }
        }
        .font(.system(size: 9))
    }
}

extension Date {
    var shortAge: String {
        let s = max(0, Int(Date().timeIntervalSince(self)))
        switch s {
        case ..<60:      return "\(s)s"
        case ..<3600:    return "\(s / 60)m"
        case ..<86400:   return "\(s / 3600)h"
        case ..<604800:  return "\(s / 86400)d"
        default:         return "\(s / 604800)w"
        }
    }
}
#endif
