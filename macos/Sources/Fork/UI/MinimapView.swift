#if os(macOS)
import SwiftUI

/// Read-only split-tree visualizer shown under the active sidebar tab (SPEC §9).
/// Renders `PersistedTree` topology with session names; equal-weight slabs (ratio
/// is ignored — imperceptible at this scale and avoids nested GeometryReader).
struct MinimapView: View {
    let tree: PersistedTree

    var body: some View {
        MinimapNode(node: tree).frame(height: height)
    }

    private var height: CGFloat {
        switch tree.paneCount {
        case ...2: 28
        case ...4: 44
        default: 60
        }
    }
}

private struct MinimapNode: View {
    let node: PersistedTree

    var body: some View {
        switch node {
        case .empty:
            Color.clear
        case .leaf(let ref):
            Text((ref?.name ?? "—").replacingOccurrences(of: "-", with: "-\u{200B}"))
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .truncationMode(.head)
                .multilineTextAlignment(.leading)
                .padding(.horizontal, 4)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 2))
                .help(ref?.name ?? "")
        case .split(let horizontal, _, let a, let b):
            if horizontal {
                HStack(spacing: 1) { MinimapNode(node: a); MinimapNode(node: b) }
            } else {
                VStack(spacing: 1) { MinimapNode(node: a); MinimapNode(node: b) }
            }
        }
    }
}
#endif
