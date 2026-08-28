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

/// Which open/close animation a panel plays.
///
/// On Linux these come from the compositor. end-4's Hyprland config sets them in
/// hyprland/general.lua, and they are what this reproduces exactly:
///
///     layersIn       speed 2.7   emphasizedDecel   popin 93%
///     layersOut      speed 2.4   menu_accel        popin 94%
///     fadeLayersIn   speed 0.5   menu_decel
///     fadeLayersOut  speed 2.7   stall
///
/// Note the style is `popin`, not `slide`: a layer surface scales up from 93% of
/// its size rather than travelling in from an edge, and the fade is a separate
/// animation with its own curve and duration. macOS has no compositor doing any
/// of this, so without it the panels blink in and out.
enum class PanelAnimation : quint8 {
	/// Appear and disappear with no transition.
	None = 0,
	/// Scale up from a fraction of full size while fading, and back down on
	/// close. Hyprland's `popin`, which end-4 applies to every layer surface.
	Popin = 1,
};

/// Play @p animation on the window backing @p view.
///
/// @p opening selects the direction: the rendered content scales up onto full
/// size, or down off it. The window's own frame never moves -- the scale is a
/// transform on the content view's layer, so Qt Quick is not asked to re-lay-out
/// the panel on every tick the way a frame animation would. The caller is
/// responsible for showing the window before an opening animation and hiding it
/// @p durationMs after a closing one.
void animatePanel(WId view, PanelAnimation animation, bool opening, int durationMs);

/// Stop any animation on @p view and restore full opacity.
///
/// An animation that never got a chance to run would otherwise leave the window
/// stuck at zero alpha, which reads as a panel that simply never appeared.
void settlePanel(WId view);

/// Register a window for native panel treatment and apply it immediately.
///
/// The NSWindow backing @p view is configured with the appropriate level,
/// collection behavior and transparency. Qt's cocoa plugin resets these on app
/// activation and window recreation, so every registered window is re-applied
/// whenever the application's active state changes.
void registerPanel(WId view, PanelLayer layer, bool focusable);

/// True once this process has registered at least one panel, i.e. it is a shell
/// rather than a plain application window (settings, the welcome screen).
bool processOwnsPanels();

/// Hide a window's titlebar and its close/minimise/zoom buttons, keeping the
/// window itself ordinary.
///
/// Deliberately not Qt::FramelessWindowHint: on macOS that produces a borderless
/// window, which loses the rounded corners, the shadow and the resize border, and
/// borderless windows have their own rules about taking keyboard focus. Making
/// the titlebar transparent and extending the content into it is what a native
/// application does for this look, and it stays a normal, focusable, resizable
/// window.
void applyUndecoratedChrome(WId view);

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
