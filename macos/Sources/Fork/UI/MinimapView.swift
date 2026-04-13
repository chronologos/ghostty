#if os(macOS)
import SwiftUI

/// Read-only split-tree visualizer shown under the active sidebar tab (SPEC §9).
/// Renders `PersistedTree` topology with session names; equal-weight slabs (ratio
/// is ignored — imperceptible at this scale and avoids nested GeometryReader).
struct MinimapView: View {
    let tree: PersistedTree
    var surfaceFor: (SessionRef) -> Ghostty.SurfaceView? = { _ in nil }

    var body: some View {
        MinimapNode(node: tree, surfaceFor: surfaceFor).frame(height: height)
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
    let surfaceFor: (SessionRef) -> Ghostty.SurfaceView?

    var body: some View {
        switch node {
        case .empty:
            Color.clear
        case .leaf(let ref):
            MinimapLeaf(ref: ref, surface: ref.flatMap(surfaceFor))
        case .split(let horizontal, _, let a, let b):
            if horizontal {
                HStack(spacing: 1) {
                    MinimapNode(node: a, surfaceFor: surfaceFor)
                    MinimapNode(node: b, surfaceFor: surfaceFor)
                }
            } else {
                VStack(spacing: 1) {
                    MinimapNode(node: a, surfaceFor: surfaceFor)
                    MinimapNode(node: b, surfaceFor: surfaceFor)
                }
            }
        }
    }
}

private struct MinimapLeaf: View {
    let ref: SessionRef?
    let surface: Ghostty.SurfaceView?

    var body: some View {
        if let surface {
            ObservingLeaf(surface: surface, fallback: ref?.name)
        } else {
            slab(ref?.name ?? "—")
        }
    }

    /// Label is always the session name; live OSC 2 title goes to the tooltip only
    /// (shell-integration sets it to cwd, which is a poor pane discriminator).
    private struct ObservingLeaf: View {
        let surface: Ghostty.SurfaceView
        let fallback: String?
        @State private var title = ""
        var body: some View {
            slab(fallback ?? "—", help: title.isEmpty || title == "👻" ? nil : title)
                .onReceive(surface.$title.removeDuplicates()) { title = $0 }
        }
    }
}

private func slab(_ label: String, help: String? = nil) -> some View {
    Text(label.replacingOccurrences(of: "-", with: "-\u{200B}"))
        .font(.system(size: 9, design: .monospaced))
        .foregroundStyle(.secondary)
        .lineLimit(2)
        .truncationMode(.head)
        .multilineTextAlignment(.leading)
        .padding(.horizontal, 4)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 2))
        .help(help ?? label)
}
#endif
