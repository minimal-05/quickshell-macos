#include "nswindow.hpp"

#import <AppKit/AppKit.h>
#import <QuartzCore/QuartzCore.h>

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

	window.level = levelFor(config.layer);

	// Sticky across spaces, unmoved by Mission Control, skipped by cmd-tab, and
	// allowed over other applications' full screen spaces.
	window.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces
	                          | NSWindowCollectionBehaviorStationary
	                          | NSWindowCollectionBehaviorIgnoresCycle
	                          | NSWindowCollectionBehaviorFullScreenAuxiliary;

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
	NSLog(@"[qs] cfg frame=%@ lvl=%ld a=%.2f vis=%d onscreen=%d style=0x%lx opaque=%d",
	      NSStringFromRect(window.frame), (long) window.level, window.alphaValue,
	      (int) window.isVisible, (int) window.occlusionState, (unsigned long) window.styleMask,
	      (int) window.isOpaque);

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
	if (!config.focusable) {
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

	// Dragging normally happens by the titlebar, which is now invisible, so let
	// the window be dragged by its background instead.
	window.movableByWindowBackground = YES;

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

	// The same three lines applyConfig() uses on panels. Popups are transient
	// and are re-applied on every surface creation and expose, so unlike panels
	// they need no entry in panelConfigs() and no reapply observer.
	window.opaque = NO;
	window.backgroundColor = NSColor.clearColor;
	window.hasShadow = NO;
}

void unregisterPanel(WId view) { panelConfigs().remove(view); }

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

} // namespace qs::cocoa
