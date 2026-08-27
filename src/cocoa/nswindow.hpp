#pragma once

#include <qtypes.h>
#include <qwindowdefs.h>

namespace qs::cocoa {

/// Which native window level a panel sits at.
enum class PanelLayer : quint8 {
	/// Behind desktop icons - wallpaper replacements.
	Desktop = 0,
	/// Below normal windows but above the desktop.
	Bottom = 1,
	/// Above normal windows, at the level menu bar extras use.
	Top = 2,
	/// Above nearly everything, including full screen spaces.
	Overlay = 3,
};

/// Register a window for native panel treatment and apply it immediately.
///
/// The NSWindow backing @p view is configured with the appropriate level,
/// collection behavior and transparency. Qt's cocoa plugin resets these on app
/// activation and window recreation, so every registered window is re-applied
/// whenever the application's active state changes.
void registerPanel(WId view, PanelLayer layer, bool focusable);

/// Stop tracking a window previously passed to registerPanel.
void unregisterPanel(WId view);

/// Re-apply native state to every registered window.
void reapplyPanels();

/// Run without a dock icon or application menu bar.
void setAccessoryActivationPolicy();

/// Unbind cmd-Q from the Quit item Qt installs by default.
///
/// A shell is not an app you quit by reflex. Qt's cocoa plugin always builds an
/// application menu whose Quit item is wired to cmd-Q, so a stray cmd-Q aimed at
/// whatever happened to hold key status could tear the whole shell down. Quit
/// stays available through the CLI and IPC.
void stripQuitKeyEquivalent();

/// Top inset of the screen containing @p view, in points. Zero when the display
/// has no camera housing.
qreal screenTopSafeAreaInset(WId view);

} // namespace qs::cocoa
