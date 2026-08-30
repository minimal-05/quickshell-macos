#include <qcoreapplication.h>
#include <qcursor.h>
#include <qevent.h>
#include <qguiapplication.h>
#include <qlist.h>
#include <qpointer.h>
#include <qqml.h>
#include <qquickwindow.h>
#include <qscreen.h>
#include <qstring.h>
#include <qtimer.h>
#include <qwindow.h>

#include "../core/iconimageprovider.hpp"
#include "../core/plugin.hpp"
#include "appicon.hpp"
#include "nswindow.hpp"
#include "panel_window.hpp"
#include "clipboard.hpp" // round2/native-input

namespace {

// Nothing was feeding pointer positions to popup windows.
//
// CocoaPanelWindow polls the cursor and synthesises moves into Qt because
// AppKit only routes pointer events to the application it considers frontmost,
// and a shell is an accessory that never is. A PopupWindow is not a
// CocoaPanelWindow, so it was never in that list and its MouseAreas never saw
// the pointer at all.
//
// The dock's preview reads popupMouseArea.containsMouse to decide whether to
// stay open, and that could never go true: moving off the icons towards the
// previews closed the popup before the pointer arrived, taking the dock with
// it, and the previews could not be clicked because they were gone by the time
// the click landed. Every other popup in a config -- tray menus, bar popups,
// tooltips -- had the same hole.
//
// Deliberately a second poller rather than sharing the panel one: that list is
// keyed on CocoaPanelWindow and a popup has no such object. Merge them if a
// third kind of window ever needs this.
struct PopupPointer {
	QPointer<QWindow> window;
	bool inside = false;
	QPoint lastPointer = QPoint(-1, -1);
};

QList<PopupPointer>& popupPointers() {
	static QList<PopupPointer> pointers;
	return pointers;
}

void updatePopupPointer(PopupPointer& state, const QPoint& rawPointer) {
	auto* window = state.window.data();

	if (!window->isVisible()) {
		state.inside = false;
		return;
	}

	// QCursor::pos() is rounded, and the bottom row of a screen can round to one
	// past the last pixel a bottom-anchored panel covers. Shoving the mouse hard
	// into the bottom edge -- exactly how you open an auto-hiding dock -- then
	// read as *outside* the dock, so it refused to open at the one position the
	// gesture always ends at, while a few pixels higher worked fine. A position
	// at most a pixel outside the screen is that rounding, not a real place the
	// pointer can be; pull it back on.
	auto pointer = rawPointer;
	if (auto* pointerScreen = window->screen()) {
		auto rect = pointerScreen->geometry();
		if (rect.adjusted(-1, -1, 1, 1).contains(pointer)) {
			pointer.setX(qBound(rect.left(), pointer.x(), rect.right()));
			pointer.setY(qBound(rect.top(), pointer.y(), rect.bottom()));
		}
	}

	auto inside = window->geometry().contains(pointer);
	auto left = state.inside && !inside;
	state.inside = inside;

	if (left) {
		state.lastPointer = QPoint(-1, -1);
		QCoreApplication::postEvent(window, new QEvent(QEvent::Leave));
		return;
	}

	// Unchanged position means nothing to say, which is what keeps this idle
	// while the pointer rests inside a popup.
	if (!inside || pointer == state.lastPointer) return;
	state.lastPointer = pointer;

	auto local = QPointF(pointer - window->geometry().topLeft());

	QCoreApplication::postEvent(
	    window,
	    new QMouseEvent(
	        QEvent::MouseMove,
	        local,
	        QPointF(pointer),
	        Qt::NoButton,
	        Qt::NoButton,
	        Qt::NoModifier
	    )
	);
}

void trackPopupPointer(QWindow* window) {
	for (const auto& existing: popupPointers()) {
		if (existing.window == window) return;
	}

	popupPointers().append(PopupPointer {.window = window});

	static QTimer* timer = nullptr;
	if (timer != nullptr) return;

	timer = new QTimer(QCoreApplication::instance());
	timer->setInterval(50); // POINTER_POLL_MS, as the panel poller uses.

	QObject::connect(timer, &QTimer::timeout, [] {
		// As in the panel poller: a screenshot's crosshair is supposed to be the
		// only thing the pointer can reach, and reading the cursor instead of being
		// handed events is exactly what let popups go on tracking it underneath.
		if (qs::cocoa::interactiveScreenCaptureActive()) return;

		auto pointer = QCursor::pos();
		auto& pointers = popupPointers();

		for (auto it = pointers.begin(); it != pointers.end();) {
			if (it->window.isNull()) {
				it = pointers.erase(it);
				continue;
			}

			updatePopupPointer(*it, pointer);
			++it;
		}
	});

	timer->start();
}

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
		trackPopupPointer(window);
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
		//
		// It also needs promoting off the shared bundle's LSUIElement default:
		// see setRegularActivationPolicy. An accessory-policy window gets no
		// normal accessibility role, so yabai could see it existed but never its
		// title -- every dock/taskbar integration keyed on title silently failed
		// for exactly these "ordinary window" configs.
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

			    qs::cocoa::setRegularActivationPolicy();
			    qs::cocoa::applyUndecoratedChrome(window->winId());
		    }
		);

		qs::cocoa::startClipboardWatch(); // round2/native-input
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
