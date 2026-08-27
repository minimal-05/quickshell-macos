#include "nswindow.hpp"

#import <AppKit/AppKit.h>

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

	if ([window isKindOfClass:[NSPanel class]]) {
		auto* panel = static_cast<NSPanel*>(window);

		// Qt preserves this bit across its own styleMask recomputation, so it only
		// needs to be set once. It lets the panel take keys without activating us.
		panel.styleMask |= NSWindowStyleMaskNonactivatingPanel;
		panel.hidesOnDeactivate = NO;
		panel.becomesKeyOnlyIfNeeded = !config.focusable;
	}
}

} // namespace

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

	ensureObserver();

	auto config = PanelConfig {.layer = layer, .focusable = focusable};
	panelConfigs().insert(view, config);
	applyConfig(view, config);
}

void unregisterPanel(WId view) { panelConfigs().remove(view); }

void setAccessoryActivationPolicy() {
	[NSApplication.sharedApplication setActivationPolicy:NSApplicationActivationPolicyAccessory];
}

qreal screenTopSafeAreaInset(WId view) {
	auto* window = windowFor(view);
	auto* screen = window != nil ? window.screen : NSScreen.mainScreen;
	if (screen == nil) return 0;

	return screen.safeAreaInsets.top;
}

} // namespace qs::cocoa
