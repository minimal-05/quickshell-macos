#include <qcoreapplication.h>
#include <qevent.h>
#include <qguiapplication.h>
#include <qlist.h>
#include <qqml.h>
#include <qquickwindow.h>
#include <qstring.h>
#include <qwindow.h>

#include "../core/iconimageprovider.hpp"
#include "../core/plugin.hpp"
#include "appicon.hpp"
#include "nswindow.hpp"
#include "panel_window.hpp"

namespace {

// Clears the native background of transparent popup windows.
//
// Panels get this from registerPanel(), but popups never go through it, so a
// `color: "transparent"` PopupWindow painted NSWindow's default dark grey over
// everything behind it. There is no "window created" signal to hang this on,
// hence an application event filter; it exits on the event type for everything
// that is not a surface creation or an expose.
//
// Scoped to popups that actually asked to be transparent: Qt's own menus and
// tooltips are opaque and must keep their native background and shadow.
class PopupChromeFilter: public QObject {
public:
	explicit PopupChromeFilter(QObject* parent): QObject(parent) {}

	bool eventFilter(QObject* object, QEvent* event) override {
		switch (event->type()) {
		case QEvent::PlatformSurface:
			if (static_cast<QPlatformSurfaceEvent*>(event)->surfaceEventType()
			    != QPlatformSurfaceEvent::SurfaceCreated)
			{
				return false;
			}
			break;
		case QEvent::Expose: break;
		default: return false;
		}

		auto* window = qobject_cast<QQuickWindow*>(object);
		if (window == nullptr) return false;

		const auto type = window->flags() & Qt::WindowType_Mask;
		if (type != Qt::Popup && type != Qt::ToolTip) return false;
		if (window->color().alpha() == 255) return false;

		// winId() creates the platform window if there is not one; never ask for
		// it before there is a handle. Same trap as applyUndecoratedChrome below.
		if (QCoreApplication::closingDown() || window->handle() == nullptr) return false;

		qs::cocoa::applyPopupChrome(window->winId());
		return false;
	}
};

class CocoaPlugin: public QsEnginePlugin {
	QString name() override { return "cocoa"; }

	QList<QString> dependencies() override { return {"window"}; }

	bool applies() override { return QGuiApplication::platformName() == "cocoa"; }

	// Deliberately empty. Accessory activation policy is applied lazily, when
	// the first panel is registered — see registerPanel() in nswindow.mm.
	// Applying it here would hit every quickshell process, including ones whose
	// only window is an ordinary application window (the settings and welcome
	// configs). Those need to stay a regular app: with a Dock icon, a menu bar,
	// and their own Quit item, so closing them is unambiguous.
	void init() override {
		qGuiApp->installEventFilter(new PopupChromeFilter(qGuiApp));

		// macOS ships no XDG icon theme, so a desktop-entry name never resolves
		// and every app icon in a bar, dock or overview paints as the missing
		// texture. Resolve those against LaunchServices instead.
		IconImageProvider::setFallbackLookup(&qs::cocoa::appIcon);

		// A quickshell process that owns no panels is an ordinary application
		// window -- the settings and welcome configs. Those are the shell's own
		// chrome, drawn by the config itself, so the system titlebar on top of it
		// is duplicate furniture. Strip it once the window exists; there is no
		// earlier hook, and re-applying is harmless.
		QObject::connect(
		    qGuiApp,
		    &QGuiApplication::focusWindowChanged,
		    [](QWindow* window) {
			    if (window == nullptr || qs::cocoa::processOwnsPanels()) return;
			    if (window->flags().testFlag(Qt::Popup)) return;

			    // winId() CREATES the platform window if there is not one, which
			    // during teardown resurrects a half destroyed QCocoaWindow and
			    // segfaults in setVisible(). Focus changes are delivered while the
			    // engine is shutting down, so both guards are load bearing.
			    if (QCoreApplication::closingDown() || window->handle() == nullptr) return;

			    qs::cocoa::applyUndecoratedChrome(window->winId());
		    }
		);
	}

	void registerTypes() override {
		qmlRegisterType<qs::cocoa::CocoaPanelInterface>(
		    "Quickshell._CocoaOverlay",
		    1,
		    0,
		    "PanelWindow"
		);

		qmlRegisterModuleImport(
		    "Quickshell",
		    QQmlModuleImportModuleAny,
		    "Quickshell._CocoaOverlay",
		    QQmlModuleImportLatest
		);
	}
};

QS_REGISTER_PLUGIN(CocoaPlugin);

} // namespace
