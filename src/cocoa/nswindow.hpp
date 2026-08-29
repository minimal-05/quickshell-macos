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

/// Turn this process into a shell: accessory activation policy, no cmd-Q.
///
/// Called as soon as a PanelWindow exists, visible or not. Waiting for the
/// first panel to show is too late: Qt activates a regular application as it
/// starts, so a config whose panels all begin hidden -- every probe under
/// tests/, the shell while its bar is still loading -- took the keyboard away
/// from whatever the user was typing into. Idempotent.
void becomeShellProcess();

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

/// Clear the native background of a transparent popup window.
///
/// registerPanel() does this for panels, but a PopupWindow is not a panel and
/// never goes through it, so nothing ever cleared NSWindow.opaque for one. Qt
/// gives the surface an alpha channel when `color` is translucent but leaves
/// the NSWindow opaque, and the window then paints its default background --
/// which is why a `color: "transparent"` popup showed up as a slab of dark
/// grey the size of the whole popup window, not the card drawn inside it.
///
/// Applies to popups only. A transparent popup draws its own rounded card and
/// its own shadow, so the native shadow goes too; it would otherwise outline
/// the invisible window rectangle.
void applyPopupChrome(WId view);

/// Make the panel backing @p view the key window.
///
/// Qt backs these with a plain QNSWindow rather than an NSPanel, so the
/// non-activating panel style registerPanel wants never applies, and
/// -makeKeyWindow does nothing while the process is inactive. A shell is an
/// accessory with no dock icon or menu bar, so activating it is invisible apart
/// from the keyboard going where the user just asked it to go.
void focusPanel(WId view);

/// Hand activation back to the application that was frontmost before
/// focusPanel() ran. No-op if nothing was recorded.
void unfocusPanel();

/// Stop tracking a window previously passed to registerPanel.
void unregisterPanel(WId view);

/// Re-apply native state to every registered window.
void reapplyPanels();

/// True while an interactive screen capture is waiting on the user.
///
/// The panel and popup pointer pollers synthesise mouse moves into Qt from the
/// cursor position, because AppKit only routes pointer events to the frontmost
/// application and a shell is an accessory that never is. That deliberately
/// bypasses event routing entirely -- which also means nothing in front of the
/// panels can take the pointer away from them. Under `screencapture -i`, the
/// crosshair the whole screen is supposed to be frozen behind, the bar and dock
/// went on hovering: dropdowns opened under the crosshair and the shot caught
/// them. The pollers hold still while this is true.
bool interactiveScreenCaptureActive();

/// Bring native hit-testing in step with the capture state, and report it.
///
/// Guarding the pointer pollers is not enough on its own. registerPanel installs
/// an NSTrackingArea with NSTrackingActiveAlways -- hover must not depend on
/// being the active application, because a shell never is -- and AppKit delivers
/// to it on real pointer movement no matter which application owns the screen.
/// Synthetic moves never exercise that path (see bin/qs-probe), which is exactly
/// why guarding the pollers alone looked like a complete fix and was not.
bool syncCaptureInertness();

/// True while any mouse button is down anywhere on the desktop.
///
/// Asked of the window server, not of QGuiApplication::mouseButtons(): that
/// only knows about presses Qt itself processed, and a shell's panels sit under
/// other applications' windows, so a press Qt never saw still holds the button.
bool anyMouseButtonHeld();

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
