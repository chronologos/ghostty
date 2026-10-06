#if os(macOS)
import AppKit

/// The borderless child window every fork `Panel` floats in (`presentSheet`). Handles
/// ⌘V/C/X/A/Z directly: Ghostty's MainMenu Paste item
/// (action `paste:`, target First Responder) walks the chain past the panel to
/// `mainWindow.firstResponder` — the parent window's `SurfaceView`, which implements
/// `paste:` (`SurfaceView_AppKit.swift:1550`) and swallows it. Intercepting here at
/// `performKeyEquivalent` reaches the field editor before the menu does.
final class ForkSheetPanel: NSWindow {
    // Borderless windows refuse key by default, and every panel needs the keyboard: a query
    // field, or a confirm's ⏎ / K / Esc.
    override var canBecomeKey: Bool { true }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard let tv = firstResponder as? NSTextView else {
            return super.performKeyEquivalent(with: event)
        }
        let mods = event.modifierFlags.intersection([.command, .shift, .option, .control])
        let key = event.charactersIgnoringModifiers?.lowercased()
        switch (mods, key) {
        case (.command, "v"): tv.paste(nil)
        case (.command, "c"): tv.copy(nil)
        case (.command, "x"): tv.cut(nil)
        case (.command, "a"): tv.selectAll(nil)
        case (.command, "z"): tv.undoManager?.undo()
        case ([.command, .shift], "z"): tv.undoManager?.redo()
        default: return super.performKeyEquivalent(with: event)
        }
        return true
    }
}
#endif
