#include "nswindow.hpp"

#import <AppKit/AppKit.h>
#import <QuartzCore/QuartzCore.h>

#include <sys/sysctl.h>

#include <cstring>
#include <vector>

#include <qelapsedtimer.h>
#include <qhash.h>
#include <qtypes.h>
#include <qwindowdefs.h>

namespace qs::cocoa {

namespace {

struct PanelConfig {
	PanelLayer layer = PanelLayer::Top;
	bool focusable = false;
};

QHash<WId, PanelConfig>& panelConfigs() {
	static QHash<WId, PanelConfig> configs;
	return configs;
}

/// Whether panels are currently held inert because a screen capture owns the
/// screen. See syncCaptureInertness.
bool& captureInert() {
	static auto inert = false;
	return inert;
}

NSView* viewFor(WId view) { return view == 0 ? nil : reinterpret_cast<NSView*>(view); }

NSWindow* windowFor(WId view) { return [viewFor(view) window]; }

CGWindowLevel levelFor(PanelLayer layer) {
	switch (layer) {
	case PanelLayer::Desktop: return CGWindowLevelForKey(kCGDesktopWindowLevelKey);
	case PanelLayer::Bottom: return CGWindowLevelForKey(kCGBackstopMenuLevelKey);
	case PanelLayer::Top: return CGWindowLevelForKey(kCGStatusWindowLevelKey);
	case PanelLayer::Overlay: return CGWindowLevelForKey(kCGScreenSaverWindowLevelKey);
	}

	return CGWindowLevelForKey(kCGStatusWindowLevelKey);
}

void applyConfig(WId view, const PanelConfig& config) {
	auto* window = windowFor(view);
	if (window == nil) return;

	// The costly writes below are skipped when they would change nothing. This
	// runs for every panel on every application activation change, and opening
	// the overlay activates the shell and closing it deactivates it -- so the
	// common case is a dozen panels reconfigured to exactly what they already
	// were. Reading a property is free; assigning level reorders the window
	// server's list and assigning styleMask rebuilds the window's frame view.
	auto level = levelFor(config.layer);
	if (window.level != level) window.level = level;

	// Sticky across spaces, unmoved by Mission Control, skipped by cmd-tab, and
	// allowed over other applications' full screen spaces.
	auto behavior = NSWindowCollectionBehaviorCanJoinAllSpaces
	              | NSWindowCollectionBehaviorStationary
	              | NSWindowCollectionBehaviorIgnoresCycle
	              | NSWindowCollectionBehaviorFullScreenAuxiliary;
	if (window.collectionBehavior != behavior) window.collectionBehavior = behavior;

	window.opaque = NO;
	window.backgroundColor = NSColor.clearColor;
	window.hasShadow = NO;
	window.movableByWindowBackground = NO;

	// Hover must not depend on being the active application. A shell process is
	// an accessory and never activates, and AppKit only delivers mouse-moved
	// events to a window whose application is active -- so without this, a bar's
	// hover popups open only while something else keeps handing focus to the
	// panel. Under a focus-follows-mouse window manager that is exactly what
	// happens, and because a non-activating panel cannot hold focus, the focus is
	// immediately returned and the hover is lost: the popup opens and closes
	// several times a second for as long as the pointer rests on the module.
	// Taking moved events directly makes hover independent of focus entirely.
	window.acceptsMouseMovedEvents = YES;

	// Nothing below reaches a panel while a screenshot is being composed. The
	// tracking area installed further down is NSTrackingActiveAlways, so real
	// pointer movement is delivered to it whatever is in front of the panel --
	// taking the window out of AppKit's hit-testing is what actually stops it.
	window.ignoresMouseEvents = captureInert();

	// acceptsMouseMovedEvents alone is not enough. Qt installs its own tracking
	// area with NSTrackingActiveInActiveApp, so hover only works once something
	// has made this process the active application -- which is why the bar had to
	// be clicked before its dropdowns would open on hover. A shell is an accessory
	// and never becomes active on its own, so it needs a tracking area that is
	// live regardless. The owner is Qt's own content view, so its existing
	// mouseEntered/mouseExited/mouseMoved handlers do the work and Qt sees exactly
	// the events it would see on any other platform.
	if (auto* view = window.contentView; view != nil) {
		auto alreadyInstalled = NO;
		for (NSTrackingArea* existing in view.trackingAreas) {
			if (existing.userInfo[@"quickshell"] != nil) {
				alreadyInstalled = YES;
				break;
			}
		}

		if (!alreadyInstalled) {
			auto options = NSTrackingMouseEnteredAndExited | NSTrackingMouseMoved
			             | NSTrackingActiveAlways | NSTrackingInVisibleRect;

			auto* area = [[NSTrackingArea alloc] initWithRect:NSZeroRect
			                                          options:options
			                                            owner:view
			                                         userInfo:@{@"quickshell": @YES}];
			[view addTrackingArea:area];
		}
	}

	if ([window isKindOfClass:[NSPanel class]]) {
		auto* panel = static_cast<NSPanel*>(window);

		// Qt preserves this bit across its own styleMask recomputation, so it only
		// needs to be set once. It lets the panel take keys without activating us.
		panel.styleMask |= NSWindowStyleMaskNonactivatingPanel;
		panel.hidesOnDeactivate = NO;
		panel.becomesKeyOnlyIfNeeded = !config.focusable;
	}

	// A panel that asked for no keyboard focus must be incapable of holding it,
	// not merely reluctant. AppKit returns NO from canBecomeKeyWindow for a
	// borderless window, and that is the only part of this AX-visible to a window
	// manager: under focus-follows-mouse, yabai focuses whatever sits under the
	// pointer, and a bar spanning the top edge is crossed constantly. Focusing it
	// leaves the user's focus nowhere -- a shell panel is not a place focus can
	// live -- so the next application does not autofocus until it is clicked.
	// becomesKeyOnlyIfNeeded does not cover this: it governs clicks, not a
	// programmatic focus request. Panels that do want keys (the overview's search
	// field, the sidebars) set keyboardFocus and are left alone.
	if (!config.focusable && window.styleMask != NSWindowStyleMaskBorderless) {
		window.styleMask = NSWindowStyleMaskBorderless;
	}
}

} // namespace

namespace {

/// end-4's Hyprland curves, verbatim from hyprland/general.lua. Hyprland beziers
/// carry the two control points of a cubic from (0,0) to (1,1), which is exactly
/// what CAMediaTimingFunction takes.
CAMediaTimingFunction* emphasizedDecelCurve() {
	return [CAMediaTimingFunction functionWithControlPoints:0.05f:0.7f:0.1f:1.0f];
}

CAMediaTimingFunction* menuAccelCurve() {
	return [CAMediaTimingFunction functionWithControlPoints:0.52f:0.03f:0.72f:0.08f];
}

CAMediaTimingFunction* menuDecelCurve() {
	return [CAMediaTimingFunction functionWithControlPoints:0.1f:1.0f:0.0f:1.0f];
}

CAMediaTimingFunction* stallCurve() {
	return [CAMediaTimingFunction functionWithControlPoints:1.0f:-0.1f:0.7f:0.85f];
}

/// Build a transform that scales a layer about its centre, whatever its
/// anchorPoint happens to be -- AppKit and Qt do not agree on that default.
CATransform3D popinTransform(CALayer* layer, double scale) {
	auto bounds = layer.bounds;
	auto anchor = layer.anchorPoint;

	auto dx = bounds.size.width * (0.5 - anchor.x);
	auto dy = bounds.size.height * (0.5 - anchor.y);

	auto transform = CATransform3DMakeTranslation(dx * (1 - scale), dy * (1 - scale), 0);
	return CATransform3DScale(transform, scale, scale, 1);
}

// Hyprland animation speeds are in deciseconds. These are end-4's, unmodified.
constexpr auto LAYERS_IN_S = 0.27;      // layersIn      speed 2.7
constexpr auto LAYERS_OUT_S = 0.24;     // layersOut     speed 2.4
constexpr auto FADE_IN_S = 0.05;        // fadeLayersIn  speed 0.5
constexpr auto FADE_OUT_S = 0.27;       // fadeLayersOut speed 2.7
constexpr auto POPIN_IN_SCALE = 0.93;   // popin 93%
constexpr auto POPIN_OUT_SCALE = 0.94;  // popin 94%

} // namespace

void animatePanel(WId view, PanelAnimation animation, bool opening, int durationMs) {
	auto* window = windowFor(view);
	if (window == nil || animation == PanelAnimation::None || durationMs <= 0) return;

	auto* contentView = window.contentView;
	if (contentView == nil) return;

	contentView.wantsLayer = YES;
	auto* layer = contentView.layer;
	if (layer == nil) return;

	// The scale is applied to the rendered layer, NOT to the window frame.
	// Resizing the window makes Qt Quick re-lay-out the contents on every tick --
	// mid-animation a sidebar's rows visibly collapse from labelled tiles to bare
	// icons and back, which is nothing like the compositor scaling a finished
	// surface, and the repeated relayout is what makes a content-heavy popup like
	// the resource readout hitch. Hyprland's popin transforms the surface as a
	// texture, so the layout never changes; this does the same.
	auto from = popinTransform(layer, opening ? POPIN_IN_SCALE : 1.0);
	auto to = popinTransform(layer, opening ? 1.0 : POPIN_OUT_SCALE);

	auto* scale = [CABasicAnimation animationWithKeyPath:@"transform"];
	scale.fromValue = [NSValue valueWithCATransform3D:from];
	scale.toValue = [NSValue valueWithCATransform3D:to];
	scale.duration = opening ? LAYERS_IN_S : LAYERS_OUT_S;
	scale.timingFunction = opening ? emphasizedDecelCurve() : menuAccelCurve();
	scale.removedOnCompletion = NO;
	scale.fillMode = kCAFillModeForwards;

	layer.transform = to;
	[layer addAnimation:scale forKey:@"quickshell.popin"];

	// The fade is a separate animation upstream with its own curve and its own
	// length -- fadeLayersIn is over in 50ms while the popin is still growing for
	// another 220ms, and on the way out the fade outlasts the shrink. Folding
	// them into one would average that away.
	// ponytail: no fade on open. Measured: a panel was left at alpha 0.00 while
	// correctly placed, sized, levelled and visible=1 -- the bar simply gone from
	// a healthy, error-free process. Zeroing alpha first means every path where
	// the fade does not run strands the panel invisible, and settlePanel only
	// rescues it if the timer still has a cycle to run. fadeLayersIn is 50ms and
	// was measured at 1-3 frames, so being opaque immediately loses nothing
	// anyone can see. The close fade is safe: the window is hidden at the end of
	// it and settlePanel resets alpha before it is shown again.
	if (opening) {
		window.alphaValue = 1.0;
	} else {
		[NSAnimationContext runAnimationGroup:^(NSAnimationContext* context) {
		  context.duration = FADE_OUT_S;
		  context.timingFunction = stallCurve();
		  window.animator.alphaValue = 0.0;
		}
		    completionHandler:nil];
	}
}

void settlePanel(WId view) {
	auto* window = windowFor(view);
	if (window == nil) return;

	// Drop the popin transform, or the panel is left permanently scaled: the
	// animation is added with fillMode forwards so it holds its final value.
	auto* layer = window.contentView.layer;
	if (layer != nil) {
		[layer removeAnimationForKey:@"quickshell.popin"];
		layer.transform = CATransform3DIdentity;
	}

	[NSAnimationContext runAnimationGroup:^(NSAnimationContext* context) {
	  context.duration = 0;
	  window.animator.alphaValue = 1.0;
	}
	    completionHandler:nil];

	window.alphaValue = 1.0;
}

void reapplyPanels() {
	auto& configs = panelConfigs();
	for (auto it = configs.cbegin(); it != configs.cend(); ++it) {
		applyConfig(it.key(), it.value());
	}
}

} // namespace qs::cocoa

// Qt's cocoa plugin re-derives window level and collection behavior whenever the
// application's active state changes, clobbering anything set here. Re-apply on
// both transitions.
@interface QsCocoaPanelObserver: NSObject
@end

@implementation QsCocoaPanelObserver
- (void)reapply:(NSNotification*)notification {
	(void) notification;
	qs::cocoa::reapplyPanels();
}
@end

namespace qs::cocoa {

namespace {

void ensureObserver() {
	static QsCocoaPanelObserver* observer = nil;
	if (observer != nil) return;

	observer = [[QsCocoaPanelObserver alloc] init];

	auto* center = NSNotificationCenter.defaultCenter;

	[center addObserver:observer
	           selector:@selector(reapply:)
	               name:NSApplicationDidBecomeActiveNotification
	             object:nil];

	[center addObserver:observer
	           selector:@selector(reapply:)
	               name:NSApplicationDidResignActiveNotification
	             object:nil];

	[center addObserver:observer
	           selector:@selector(reapply:)
	               name:NSApplicationDidChangeScreenParametersNotification
	             object:nil];
}

} // namespace

void registerPanel(WId view, PanelLayer layer, bool focusable) {
	if (view == 0) return;

	// A process that owns panels is a shell: no Dock icon, no menu bar, never
	// the active application. A process that owns none is an ordinary window
	// (settings, the welcome screen) and must stay a regular app, or the user
	// has no menu bar to quit it from and their cmd-Q lands on the shell.
	static auto policyApplied = false;
	if (!policyApplied) {
		policyApplied = true;
		setAccessoryActivationPolicy();
		stripQuitKeyEquivalent();
	}

	ensureObserver();

	auto config = PanelConfig {.layer = layer, .focusable = focusable};
	panelConfigs().insert(view, config);
	applyConfig(view, config);
}

bool processOwnsPanels() { return !panelConfigs().isEmpty(); }

void applyUndecoratedChrome(WId view) {
	auto* window = windowFor(view);
	if (window == nil) return;

	window.titlebarAppearsTransparent = YES;
	window.titleVisibility = NSWindowTitleHidden;
	window.styleMask |= NSWindowStyleMaskFullSizeContentView;

	// NOT movableByWindowBackground. AppKit decides on mouse-down, before Qt
	// ever sees the event, that a drag in the "background" moves the window --
	// and it considers Qt's content view background. That silently ate every
	// drag gesture inside the window: dragging a file out of the file manager
	// moved the window instead of starting a drag, and the window wandered off
	// on any stray click-drag. Moving a window is the window manager's job here
	// (yabai, with a modifier held), which is also what a user expects when they
	// are not holding that modifier.
	window.movableByWindowBackground = NO;

	// Put it back on screen if it is not. This window has no titlebar and is
	// deliberately not movable by its background, so there is nothing to drag it
	// by: one that comes up outside the visible frame -- a remembered position
	// from a display that is gone, a size that no longer fits -- stays there for
	// good, which is exactly how the settings window ended up unreachable. Only
	// the origin moves, and only when it is actually out of bounds.
	if (auto* screen = window.screen ?: NSScreen.mainScreen; screen != nil) {
		auto visible = screen.visibleFrame;
		auto frame = window.frame;

		// fmin before fmax, so a window wider or taller than the screen lands at
		// the top left corner rather than being pushed off the other edge.
		auto x = fmax(NSMinX(visible), fmin(frame.origin.x, NSMaxX(visible) - frame.size.width));
		auto y = fmax(NSMinY(visible), fmin(frame.origin.y, NSMaxY(visible) - frame.size.height));

		if (x != frame.origin.x || y != frame.origin.y) {
			[window setFrameOrigin:NSMakePoint(x, y)];
		}
	}

	for (NSNumber* button in @[
		     @(NSWindowCloseButton),
		     @(NSWindowMiniaturizeButton),
		     @(NSWindowZoomButton)
	     ])
	{
		[window standardWindowButton:static_cast<NSWindowButton>(button.unsignedIntegerValue)]
		    .hidden = YES;
	}
}

void applyPopupChrome(WId view) {
	auto* window = windowFor(view);
	if (window == nil) return;

	window.opaque = NO;
	window.backgroundColor = NSColor.clearColor;
	window.hasShadow = NO;

	// Qt backs a popup with a QNSPanel but leaves out the one bit that lets a
	// panel take a click without its application activating first. A shell is an
	// accessory that never activates, so a press on a dock window preview went
	// nowhere at all -- hover worked, because the pointer poller feeds Qt moves
	// directly, but clicking did nothing. registerPanel() sets the same bit on
	// panels, which is why their buttons have always been clickable.
	if ([window isKindOfClass:[NSPanel class]]) {
		auto* panel = static_cast<NSPanel*>(window);
		panel.styleMask |= NSWindowStyleMaskNonactivatingPanel;

		// An NSPanel hides itself when its application deactivates. This one's
		// application is never active in the first place.
		panel.hidesOnDeactivate = NO;
	}

	window.acceptsMouseMovedEvents = YES;
}

namespace {
/// The application that was frontmost when a focusable panel took focus, so it
/// can be handed back on close. Stored as a pid to avoid holding a strong
/// reference to another process's NSRunningApplication.
pid_t& previousFrontmostPid() {
	static pid_t pid = 0;
	return pid;
}
} // namespace

void focusPanel(WId view) {
	auto* window = windowFor(view);
	if (window == nil) return;
	if (![window canBecomeKeyWindow]) return;

	auto* frontmost = [[NSWorkspace sharedWorkspace] frontmostApplication];
	if (frontmost != nil && frontmost.processIdentifier != getpid()) {
		previousFrontmostPid() = frontmost.processIdentifier;
	}

	[NSApp activateIgnoringOtherApps:YES];
	[window makeKeyWindow];
}

void unfocusPanel() {
	auto pid = previousFrontmostPid();
	if (pid == 0) return;
	previousFrontmostPid() = 0;

	// Give the keyboard back, or closing the launcher leaves the user typing
	// into a shell with nothing focused.
	auto* app = [NSRunningApplication runningApplicationWithProcessIdentifier:pid];
	if (app != nil) [app activateWithOptions:0];
}

void unregisterPanel(WId view) { panelConfigs().remove(view); }

bool anyMouseButtonHeld() {
	// System-wide button state, whichever application the press went to.
	return NSEvent.pressedMouseButtons != 0;
}

void setAccessoryActivationPolicy() {
	[NSApplication.sharedApplication setActivationPolicy:NSApplicationActivationPolicyAccessory];
}

void stripQuitKeyEquivalent() {
	// Qt builds its application menu lazily, so do this after the current turn
	// of the run loop rather than racing it.
	dispatch_async(dispatch_get_main_queue(), ^{
	  auto* mainMenu = NSApplication.sharedApplication.mainMenu;
	  if (mainMenu == nil || mainMenu.numberOfItems == 0) return;

	  // The application menu is always the first item's submenu.
	  auto* appMenu = [mainMenu itemAtIndex:0].submenu;
	  if (appMenu == nil) return;

	  for (NSMenuItem* item in appMenu.itemArray) {
		  if ([item.keyEquivalent isEqualToString:@"q"]) {
			  item.keyEquivalent = @"";
			  item.keyEquivalentModifierMask = 0;
		  }
	  }
	});
}

qreal screenTopSafeAreaInset(WId view) {
	auto* window = windowFor(view);
	auto* screen = window != nil ? window.screen : NSScreen.mainScreen;
	if (screen == nil) return 0;

	return screen.safeAreaInsets.top;
}


namespace {

/// Two pollers ask this twenty times a second each, and the answer cannot change
/// faster than a person can hit a hotkey.
constexpr auto CAPTURE_CACHE_MS = 250;

/// True if @p pid was started to wait on the user rather than to take a shot and
/// exit.
///
/// Read from the argument vector, not from how long the process has been alive.
/// The shell takes non-interactive shots of its own -- `screencapture -x -o
/// -l<id>` per window for the dock's previews -- and blanking hover during one
/// would kill the preview that hover just opened. Measured here, a window shot
/// takes 130ms and a full screen one 240ms, so no lifetime threshold separates
/// the two cases with any margin. The flags do, exactly.
bool captureWaitsOnUser(pid_t pid) {
	int mib[] = {CTL_KERN, KERN_PROCARGS2, pid};

	auto size = size_t(0);
	if (sysctl(mib, 3, nullptr, &size, nullptr, 0) != 0) return false;

	auto buf = std::vector<char>(size);
	if (sysctl(mib, 3, buf.data(), &size, nullptr, 0) != 0) return false;
	if (size < sizeof(int)) return false;

	// The block is argc, then the executable path, then NUL padding, then argc
	// NUL-terminated arguments.
	auto argc = 0;
	memcpy(&argc, buf.data(), sizeof(argc));

	auto* arg = buf.data() + sizeof(argc);
	const auto* end = buf.data() + size;

	while (arg < end && *arg != '\0') arg++;
	while (arg < end && *arg == '\0') arg++;

	for (auto i = 0; i < argc && arg < end; i++) {
		auto* next = arg;
		while (next < end && *next != '\0') next++;
		if (next >= end) break;

		// screencapture bundles its flags: the screenshot hotkeys run `-pdi` and
		// `-pdiU`, while every shot the shell takes for itself is some combination
		// of -x, -o, -t, -R and -l, with no i in any of them.
		if (*arg == '-' && strchr(arg, 'i') != nullptr) return true;

		arg = next + 1;
	}

	return false;
}

bool anyInteractiveCapture() {
	int mib[] = {CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0};

	auto size = size_t(0);
	if (sysctl(mib, 4, nullptr, &size, nullptr, 0) != 0) return false;

	// Processes can start between sizing the table and reading it, so ask for
	// room to spare rather than failing the whole poll with ENOMEM.
	size += size / 8;
	auto buf = std::vector<char>(size);
	if (sysctl(mib, 4, buf.data(), &size, nullptr, 0) != 0) return false;

	auto* procs = reinterpret_cast<kinfo_proc*>(buf.data());
	for (auto i = size_t(0); i < size / sizeof(kinfo_proc); i++) {
		auto& proc = procs[i].kp_proc;

		// Exactly equal, not a prefix. The screenshot hotkey starts screencaptureui
		// alongside screencapture, and that agent outlives the capture: cancelling
		// cmd-shift-4 with escape leaves it running long after the crosshair is gone.
		// A prefix match would go on seeing it and leave the whole shell unhoverable
		// for as long as it lingers.
		if (strcmp(proc.p_comm, "screencapture") != 0) continue;

		if (captureWaitsOnUser(proc.p_pid)) return true;
	}

	return false;
}

} // namespace

bool syncCaptureInertness() {
	auto capturing = interactiveScreenCaptureActive();
	if (capturing == captureInert()) return capturing;

	captureInert() = capturing;
	reapplyPanels();

	return capturing;
}

bool interactiveScreenCaptureActive() {
	static auto cached = false;
	static auto age = QElapsedTimer();

	if (age.isValid() && age.elapsed() < CAPTURE_CACHE_MS) return cached;

	cached = anyInteractiveCapture();
	age.start();

	return cached;
}


} // namespace qs::cocoa
