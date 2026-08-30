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

	auto mask = NSEventMaskLeftMouseDown | NSEventMaskRightMouseDown | NSEventMaskOtherMouseDown
	          | NSEventMaskLeftMouseUp | NSEventMaskRightMouseUp | NSEventMaskOtherMouseUp;

	auto* monitor = [NSEvent addGlobalMonitorForEventsMatchingMask:mask
	                                                       handler:^(NSEvent* event) {
	                                                         auto loc = NSEvent.mouseLocation;

	                                                         switch (event.type) {
	                                                         case NSEventTypeLeftMouseDown:
	                                                         case NSEventTypeRightMouseDown:
	                                                         case NSEventTypeOtherMouseDown:
	                                                           this->mArmed = true;
	                                                           this->mDownX = loc.x;
	                                                           this->mDownY = loc.y;
	                                                           return;
	                                                         default: break;
	                                                         }

	                                                         if (!this->mArmed) return;
	                                                         this->mArmed = false;

	                                                         // ponytail: fixed slop rather than the system's actual
	                                                         // drag threshold -- revisit if it ever needs to track
	                                                         // trackpad vs. mouse sensitivity.
	                                                         static constexpr double kClickSlop = 4.0;
	                                                         auto dx = loc.x - this->mDownX;
	                                                         auto dy = loc.y - this->mDownY;
	                                                         if (dx * dx + dy * dy > kClickSlop * kClickSlop) return;

	                                                         emit this->dismissed();
	                                                       }];

	this->mMonitor = static_cast<void*>(monitor);
}

void FocusGrab::removeMonitor() {
	if (this->mMonitor == nullptr) return;
	[NSEvent removeMonitor:static_cast<id>(this->mMonitor)];
	this->mMonitor = nullptr;
	this->mArmed = false;
}

} // namespace qs::cocoa
