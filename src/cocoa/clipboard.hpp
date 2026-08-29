#pragma once

namespace qs::cocoa {

/// Start watching the general pasteboard for changes made by other processes.
///
/// Qt's cocoa clipboard only re-reads the pasteboard when the application is
/// activated, so a shell that never takes focus never sees a copy made in
/// another app and `Quickshell.clipboardTextChanged` stays silent. This polls
/// NSPasteboard.changeCount four times a second (a local counter read, no
/// subprocess), records each new entry to the clipboard-history store bin/cliphist
/// reads (see clipboard.mm for the store), and then emits QClipboard::changed
/// so the existing QuickshellGlobal plumbing fires the QML signal.
///
/// Idempotent; the cocoa plugin calls it once at init.
void startClipboardWatch();

} // namespace qs::cocoa
