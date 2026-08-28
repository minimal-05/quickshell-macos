#include "focusgrab.hpp"

#import <AppKit/AppKit.h>

namespace qs::cocoa {

FocusGrab::~FocusGrab() { this->removeMonitor(); }

void FocusGrab::setActive(bool active) {
	if (active == this->mActive) return;
	this->mActive = active;

	if (active) this->installMonitor();
	else this->removeMonitor();

	emit this->activeChanged();
}

void FocusGrab::installMonitor() {
	if (this->mMonitor != nullptr) return;

	auto mask = NSEventMaskLeftMouseDown | NSEventMaskRightMouseDown
	          | NSEventMaskOtherMouseDown;

	auto* monitor = [NSEvent addGlobalMonitorForEventsMatchingMask:mask
	                                                       handler:^(NSEvent* event) {
	                                                         Q_UNUSED(event);
	                                                         emit this->dismissed();
	                                                       }];

	this->mMonitor = static_cast<void*>(monitor);
}

void FocusGrab::removeMonitor() {
	if (this->mMonitor == nullptr) return;
	[NSEvent removeMonitor:static_cast<id>(this->mMonitor)];
	this->mMonitor = nullptr;
}

} // namespace qs::cocoa
