#include "locationauth.hpp"

#import <CoreLocation/CoreLocation.h>

// CLLocationManagerDelegate needs a real Objective-C type; same split as
// QsCocoaPanelObserver in nswindow.mm (the ObjC class sits at file scope, the
// C++ entry point lives in qs::cocoa below). Nothing here needs the callback
// itself -- an empty implementation is enough for locationd to treat the
// manager as a real listener rather than a fire-and-forget request.
@interface QsLocationAuthDelegate: NSObject <CLLocationManagerDelegate>
@end

@implementation QsLocationAuthDelegate
- (void)locationManagerDidChangeAuthorization:(CLLocationManager*)manager {
	(void) manager;
}
@end

namespace qs::cocoa {

void requestLocationAuthorization() {
	static CLLocationManager* manager = nil;
	if (manager != nil) return;

	// Both objects are kept alive for the life of the process (static, never
	// released): a manager deallocated mid-request drops the request, and the
	// delegate has to outlive it.
	auto* delegate = [[QsLocationAuthDelegate alloc] init];
	manager = [[CLLocationManager alloc] init];
	manager.delegate = delegate;

	if (manager.authorizationStatus == kCLAuthorizationStatusNotDetermined) {
		[manager requestWhenInUseAuthorization];
	}
}

} // namespace qs::cocoa
