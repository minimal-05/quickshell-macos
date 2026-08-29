#include "panel_window.hpp"
#include <algorithm>
#include <map>

#include <qcoreapplication.h>
#include <qprocess.h>
#include <qstandardpaths.h>
#include <qstring.h>
#include <qstringlist.h>
#include <qcursor.h>
#include <qevent.h>
#include <qlist.h>
#include <qpoint.h>
#include <qtimer.h>
#include <qnamespace.h>
#include <qobject.h>
#include <qqmlengine.h>
#include <qquickwindow.h>
#include <qrect.h>
#include <qscreen.h>
#include <qtmetamacros.h>
#include <qtypes.h>

#include "../core/generation.hpp"
#include "../core/qmlscreen.hpp"
#include "../core/types.hpp"
#include "../window/panelinterface.hpp"
#include "../window/proxywindow.hpp"
#include "nswindow.hpp"
#include "wayland/layershell.hpp"

namespace qs::cocoa {

namespace {
// How long a panel stays hidden before its native window is released. Long
// enough that a bar popup flickering off and on under the pointer keeps its
// window; short enough that a closed sidebar is not holding 50 MB a minute
// later. See CocoaPanelWindow::mReleaseTimer.
constexpr auto RELEASE_HIDDEN_MS = 1000;
} // namespace

// macOS has no public API for reserving screen edges, so exclusive zones only
// apply between quickshell's own panels. Other applications will happily draw
// underneath a bar.
class CocoaPanelStack {
public:
	static CocoaPanelStack* instance() {
		static auto* stack = new CocoaPanelStack(); // NOLINT
		return stack;
	}

	[[nodiscard]] const QList<CocoaPanelWindow*>& panels(CocoaPanelWindow* panel) {
		return this->mPanels[EngineGeneration::findObjectGeneration(panel)];
	}

	void addPanel(CocoaPanelWindow* panel) {
		panel->engineGeneration = EngineGeneration::findObjectGeneration(panel);
		auto& panels = this->mPanels[panel->engineGeneration];
		if (!panels.contains(panel)) panels.push_back(panel);
		this->publishReservation();
	}

	void removePanel(CocoaPanelWindow* panel) {
		if (!panel->engineGeneration) return;

		auto& panels = this->mPanels[panel->engineGeneration];
		if (panels.removeOne(panel)) {
			if (panels.isEmpty()) {
				this->mPanels.erase(panel->engineGeneration);
				this->publishReservation();
				return;
			}

			for (auto* other: panels) {
				other->updateDimensions();
			}
		}

		this->publishReservation();
	}

	void updateLowerDimensions(CocoaPanelWindow* exclude) {
		if (!exclude->engineGeneration) return;

		auto found = false;
		for (auto* panel: this->mPanels[exclude->engineGeneration]) {
			if (panel == exclude) found = true;
			else if (found) panel->updateDimensions(false);
		}
	}

	/// Sum the zones per screen and edge and hand the largest per edge to the
	/// Reservation singleton. Every generation counts: during a reload the old
	/// panels are still on screen until the new ones have taken over, and the
	/// singleton debounces the hand-over.
	void publishReservation() {
		struct Edges {
			qint32 top = 0, bottom = 0, left = 0, right = 0;
		};
		std::map<QScreen*, Edges> screens;

		for (const auto& [generation, panels]: this->mPanels) {
			for (auto* panel: panels) {
				if (panel->window == nullptr || !panel->window->isVisible()) continue;
				if (panel->bExclusionMode == ExclusionMode::Ignore) continue;

				auto zone = panel->bcExclusiveZone.value();
				if (zone <= 0) continue;

				auto& edges = screens[panel->mTrackedScreen.data()];
				switch (panel->bcExclusionEdge.value()) {
				case Qt::TopEdge: edges.top += zone; break;
				case Qt::BottomEdge: edges.bottom += zone; break;
				case Qt::LeftEdge: edges.left += zone; break;
				case Qt::RightEdge: edges.right += zone; break;
				default: break;
				}
			}
		}

		auto total = Edges();
		for (const auto& [screen, edges]: screens) {
			total.top = std::max(total.top, edges.top);
			total.bottom = std::max(total.bottom, edges.bottom);
			total.left = std::max(total.left, edges.left);
			total.right = std::max(total.right, edges.right);
		}

		CocoaReservation::instance()->setTotals(total.top, total.bottom, total.left, total.right);
	}

private:
	std::map<EngineGeneration*, QList<CocoaPanelWindow*>> mPanels;
};

// CocoaReservation

namespace {
// Settles the burst a bar position change arrives as: the settings window
// writes its config key by key, and a panel's zone, edge and visibility each
// settle separately.
constexpr auto RESERVATION_DEBOUNCE_MS = 100;
} // namespace

CocoaReservation::CocoaReservation(QObject* parent): QObject(parent) {
	this->mPublishTimer.setSingleShot(true);
	this->mPublishTimer.setInterval(RESERVATION_DEBOUNCE_MS);
	QObject::connect(&this->mPublishTimer, &QTimer::timeout, this, &CocoaReservation::publish);
}

CocoaReservation* CocoaReservation::instance() {
	static auto* reservation = new CocoaReservation(QCoreApplication::instance()); // NOLINT
	return reservation;
}

CocoaReservation* CocoaReservation::create(QQmlEngine* engine, QJSEngine* jsEngine) {
	Q_UNUSED(engine);
	auto* reservation = CocoaReservation::instance();
	QJSEngine::setObjectOwnership(reservation, QJSEngine::CppOwnership);
	Q_UNUSED(jsEngine);
	return reservation;
}

void CocoaReservation::setTotals(qint32 top, qint32 bottom, qint32 left, qint32 right) {
	if (top == this->mTop && bottom == this->mBottom && left == this->mLeft && right == this->mRight) {
		return;
	}

	this->mTop = top;
	this->mBottom = bottom;
	this->mLeft = left;
	this->mRight = right;
	emit this->changed();

	if (this->mApplyToYabai) this->mPublishTimer.start();
}

void CocoaReservation::setApplyToYabai(bool apply) {
	if (apply == this->mApplyToYabai) return;
	this->mApplyToYabai = apply;
	emit this->applyToYabaiChanged();

	// Whatever yabai has now is from before this process; put the truth there.
	if (apply) this->mPublishTimer.start();
}

void CocoaReservation::publish() {
	static const auto yabai = QStandardPaths::findExecutable("yabai");
	if (yabai.isEmpty()) return;

	auto value = QString("all:%1:%2").arg(this->mTop).arg(this->mBottom);
	qInfo("cocoa: reservation top=%d bottom=%d left=%d right=%d -> yabai external_bar %s",
	      this->mTop, this->mBottom, this->mLeft, this->mRight, qPrintable(value));

	QProcess::startDetached(yabai, {"-m", "config", "external_bar", value});
}

bool CocoaPanelEventFilter::eventFilter(QObject* watched, QEvent* event) {
	if (event->type() == QEvent::PlatformSurface) {
		auto* surfaceEvent = static_cast<QPlatformSurfaceEvent*>(event); // NOLINT

		if (surfaceEvent->surfaceEventType() == QPlatformSurfaceEvent::SurfaceCreated) {
			emit this->surfaceCreated();
		}
	}

	return this->QObject::eventFilter(watched, event);
}

CocoaPanelWindow::CocoaPanelWindow(QObject* parent): ProxyWindowBase(parent) {
	// A PanelWindow object makes this process a shell, whether or not the panel
	// ever shows. The backing window is only created on first show, so waiting
	// for it would leave a config whose panels start hidden holding the
	// activation Qt took at launch.
	becomeShellProcess();

	QObject::connect(
	    &this->eventFilter,
	    &CocoaPanelEventFilter::surfaceCreated,
	    this,
	    &CocoaPanelWindow::cocoaInit
	);

	this->bcExclusiveZone.setBinding([this]() -> qint32 {
		switch (this->bExclusionMode.value()) {
		case ExclusionMode::Ignore: return 0;
		case ExclusionMode::Normal: return this->bExclusiveZone;
		case ExclusionMode::Auto:
			auto edge = this->bcExclusionEdge.value();
			auto margins = this->bMargins.value();

			if (edge == Qt::TopEdge || edge == Qt::BottomEdge) {
				return this->bImplicitHeight + margins.top + margins.bottom;
			} else if (edge == Qt::LeftEdge || edge == Qt::RightEdge) {
				return this->bImplicitWidth + margins.left + margins.right;
			} else {
				return 0;
			}
		}

		return 0;
	});

	this->bcExclusionEdge.setBinding([this] { return this->bAnchors.value().exclusionEdge(); });

	this->mAnimationTimer.setSingleShot(true);
	QObject::connect(
	    &this->mAnimationTimer,
	    &QTimer::timeout,
	    this,
	    &CocoaPanelWindow::finishOpenCloseAnimation
	);

	this->mReleaseTimer.setSingleShot(true);
	this->mReleaseTimer.setInterval(RELEASE_HIDDEN_MS);
	QObject::connect(
	    &this->mReleaseTimer,
	    &QTimer::timeout,
	    this,
	    &CocoaPanelWindow::releaseHiddenGraphics
	);
}

namespace {

// Hyprland animates every layer surface as it maps and unmaps, and end-4 leaves
// that at the default `popin` style, so every panel animates the same way and
// there is nothing to select per panel. Geometry and fade are separate
// animations with different curves and different lengths, so a panel is only
// settled once the slower of each pair has finished:
//   open:  layersIn 270ms  vs fadeLayersIn 50ms
//   close: layersOut 240ms vs fadeLayersOut 270ms
constexpr auto ANIMATION_OPEN_MS = 270;
constexpr auto ANIMATION_CLOSE_MS = 270;


} // namespace

namespace {

QList<CocoaPanelWindow*>& pointerTrackedPanels() {
	static auto panels = QList<CocoaPanelWindow*>();
	return panels;
}

// A poll rather than an NSEvent global monitor: the monitor only reports moves,
// and the pointer can also end up off a panel because a window opened under it
// or the panel itself moved. Sampling the cursor covers all of those, and at
// this interval it is far below the cost of the animations it is guarding.
constexpr auto POINTER_POLL_MS = 50;

void ensurePointerPoller() {
	static QTimer* timer = nullptr;
	if (timer != nullptr) return;

	timer = new QTimer(QCoreApplication::instance());
	timer->setInterval(POINTER_POLL_MS);

	QObject::connect(timer, &QTimer::timeout, [] {
		// A drag is not a hover. The move synthesised below carries no buttons, so
		// one landing mid-drag reads as "the pointer moved with nothing pressed":
		// Qt hands it to the DragHandler holding the gesture, which sees a button
		// it does not accept, deactivates and drops the grab. Dragging an overlay
		// widget stopped moving it within a tick and the release fell through to
		// the canvas underneath, which closes the overlay. Nothing needs
		// synthesising during a drag anyway -- the press already made this window
		// the event target, so the real moves arrive on their own.
		//
		// Asked of the window server, not of QGuiApplication::mouseButtons().
		// That only knows about presses Qt itself processed, and this is a
		// background accessory whose panels sit under other applications' windows
		// -- a press Qt never saw still holds the button down, and the guard read
		// clear right through the drag it was meant to protect.
		if (anyMouseButtonHeld()) return;

		// Nor is a screenshot. The crosshair is meant to freeze the screen under it,
		// but this poller reads the cursor rather than being handed events, so the
		// bar and dock kept opening their dropdowns under it and the shot caught them.
		// This also drives the panels' native hit-testing, which has to go with it --
		// the tracking areas deliver real pointer movement straight past this poller.
		if (syncCaptureInertness()) return;

		auto pointer = QCursor::pos();
		for (auto* panel: pointerTrackedPanels()) {
			panel->updatePointerInside(pointer);
		}
	});

	timer->start();
}

} // namespace

void CocoaPanelWindow::updatePointerInside(const QPoint& rawPointer) {
	if (this->window == nullptr || !this->window->isVisible()) {
		this->mPointerInside = false;
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
	if (auto* pointerScreen = this->window->screen()) {
		auto rect = pointerScreen->geometry();
		if (rect.adjusted(-1, -1, 1, 1).contains(pointer)) {
			pointer.setX(qBound(rect.left(), pointer.x(), rect.right()));
			pointer.setY(qBound(rect.top(), pointer.y(), rect.bottom()));
		}
	}

	auto geometry = this->window->geometry();
	auto local = pointer - geometry.topLeft();
	auto inside = geometry.contains(pointer) && (!this->mHasMask || this->mMaskRegion.contains(local));

	// The native input switch follows the mask, not the window: with a mask
	// set, the panel takes input only while the pointer is in it, so a click
	// anywhere else on the panel lands on what is underneath. Without one the
	// panel takes input over its whole frame, as it always did.
	if (this->mRegisteredView != 0) {
		setPanelInputEnabled(this->mRegisteredView, !this->mHasMask || inside);
	}

	auto left = this->mPointerInside && !inside;
	this->mPointerInside = inside;

	if (left) {
		// Forget where the pointer was, or coming back to the exact pixel it left
		// from matches the unchanged-position check below and posts no move --
		// leaving Qt with a Leave and nothing to undo it.
		this->mLastPointer = QPoint(-1, -1);
		QCoreApplication::postEvent(this->window, new QEvent(QEvent::Leave));
		return;
	}

	// Not `if (inside != wasInside)`: the moves have to keep coming for as long
	// as the pointer is inside, not just on the tick it crosses the edge. Qt
	// picks the hovered item out of the position each move carries, so a single
	// move on entry hovers whatever was under the pointer at that instant and
	// then nothing ever moves the hover again -- the dock would open the preview
	// for the icon you landed on and refuse to switch to its neighbours until
	// you left the dock entirely and came back. The unchanged-position check
	// below is what keeps this idle when the pointer is still.
	if (!inside) return;

	// Entering has to be synthesised too. AppKit only routes pointer events to
	// the application it considers frontmost, and a shell is an accessory that
	// never becomes frontmost on its own -- so until something makes this process
	// active, a panel is never told the pointer is over it and nothing hover
	// driven works. That is why the bar had to be clicked once before its
	// dropdowns would open. Feeding Qt the moves directly removes the dependency
	// on activation entirely.
	//
	// Real moves, when they do arrive, carry the same coordinates, so the two
	// paths agree rather than fighting; a repeat at an unchanged position is
	// skipped so this is idle when the pointer is still.
	if (pointer == this->mLastPointer) return;
	this->mLastPointer = pointer;

	QCoreApplication::postEvent(
	    this->window,
	    new QMouseEvent(
	        QEvent::MouseMove,
	        QPointF(local),
	        QPointF(pointer),
	        Qt::NoButton,
	        Qt::NoButton,
	        Qt::NoModifier
	    )
	);
}

PanelAnimation CocoaPanelWindow::openCloseAnimation() const {
	// Upstream applies layersIn/layersOut to every layer surface without
	// exception, bar popups included, so there is nothing to select on here.
	// popin scales about the centre and never leaves the panel's resting area,
	// which is also why it is safe for a surface the pointer is hovering: unlike
	// a slide, it does not move out from under the cursor.
	if (this->window == nullptr || !this->mAnimate) return PanelAnimation::None;
	return PanelAnimation::Popin;
}

void CocoaPanelWindow::setAnimate(bool animate) {
	if (animate == this->mAnimate) return;
	this->mAnimate = animate;

	// A close that was mid-animation when animation was switched off finishes
	// now rather than at the end of a transition nobody asked for.
	if (!animate && this->mClosing) this->finishOpenCloseAnimation();

	emit this->animateChanged();
}

void CocoaPanelWindow::releaseHiddenGraphics() {
	if (this->window == nullptr || this->window->handle() == nullptr) return;
	if (this->window->isVisible()) return;

	// The registry holds the NSView by address; drop it before the view goes.
	if (this->mRegisteredView != 0) {
		unregisterPanel(this->mRegisteredView);
		this->mRegisteredView = 0;
	}

	// QWindow::destroy keeps the QQuickWindow and its content item -- every
	// binding and every QML object stays -- and drops the NSWindow. The render
	// loop is told to hide on the way, and only lets go of the scene graph and
	// the swapchain if neither is persistent at that moment: with Qt's
	// defaults the QMetalSwapChain outlived the window and kept every drawable
	// of the old CAMetalLayer mapped (measured: nothing freed, and the pool
	// doubled on re-show). The flags are put back afterwards so a panel that
	// hides and shows within the timer keeps everything and pays nothing.
	this->window->setPersistentSceneGraph(false);
	this->window->setPersistentGraphics(false);
	this->window->destroy();
	this->window->setPersistentSceneGraph(true);
	this->window->setPersistentGraphics(true);

	// The next show creates a new platform window, and the surface event
	// filter runs cocoaInit against it the way it did for the first.
	qInfo("cocoa: panel released its native window");
}

void CocoaPanelWindow::setVisibleDirect(bool visible) {
	auto animation = this->openCloseAnimation();

	// Nothing to play: show and hide immediately, exactly as this did before any
	// of the animation machinery existed. Taking the animated path with a None
	// animation would still hold the hide back by a full close duration, which a
	// surface created and destroyed as fast as a hover popup cannot absorb.
	if (animation == PanelAnimation::None) {
		this->mAnimationTimer.stop();
		this->mClosing = false;

		if (!visible && this->bFocusable.value()) unfocusPanel();
		if (visible) this->mReleaseTimer.stop();

		this->ProxyWindowBase::setVisibleDirect(visible);

		if (visible && this->window != nullptr && this->window->handle() != nullptr) {
			// A previous close left the window transparent; nothing else will put
			// the opacity back when no open animation runs.
			settlePanel(this->window->winId());
			this->updateDimensions();
			if (this->bFocusable.value()) focusPanel(this->window->winId());
		}

		if (!visible) this->mReleaseTimer.start();
		return;
	}

	if (visible) {
		auto reopening = this->mClosing;

		// Already open and not on its way out: nothing to play, and an open
		// animation still in flight must be left to finish.
		if (this->isVisibleDirect() && !reopening) {
			this->mReleaseTimer.stop();
			this->ProxyWindowBase::setVisibleDirect(true);
			return;
		}

		// Reopening mid close cancels the pending hide, or it would fire over the
		// panel that just came back.
		this->mAnimationTimer.stop();
		this->mClosing = false;
		this->mReleaseTimer.stop();

		this->ProxyWindowBase::setVisibleDirect(true);
		if (this->window == nullptr || this->window->handle() == nullptr) return;

		// popin scales about the panel's centre, so the resting frame is also the
		// frame the animation plays on. Place it before scaling it.
		this->updateDimensions();

		animatePanel(this->window->winId(), animation, true, ANIMATION_OPEN_MS);
		this->mAnimationTimer.start(ANIMATION_OPEN_MS);

		if (this->bFocusable.value()) focusPanel(this->window->winId());
	} else {
		// Panels are hidden by a property binding, which can settle on false more
		// than once. Only the first hide starts the animation; the rest would cut
		// it short and make the panel blink out.
		if (this->mClosing) return;

		if (!this->isVisibleDirect() || this->window == nullptr
		    || this->window->handle() == nullptr)
		{
			this->mAnimationTimer.stop();
			this->ProxyWindowBase::setVisibleDirect(false);
			return;
		}

		this->mClosing = true;
		if (this->bFocusable.value()) unfocusPanel();
		animatePanel(this->window->winId(), animation, false, ANIMATION_CLOSE_MS);
		this->mAnimationTimer.start(ANIMATION_CLOSE_MS);
	}
}

void CocoaPanelWindow::finishOpenCloseAnimation() {
	this->mAnimationTimer.stop();

	auto closed = false;
	if (this->mClosing) {
		this->mClosing = false;
		this->ProxyWindowBase::setVisibleDirect(false);
		closed = true;
	}

	// Drop the held final scale and restore full opacity.
	if (this->window != nullptr && this->window->handle() != nullptr) {
		settlePanel(this->window->winId());
	}

	if (closed) this->mReleaseTimer.start();

	this->updateDimensions();
}

CocoaPanelWindow::~CocoaPanelWindow() {
	pointerTrackedPanels().removeAll(this);
	CocoaPanelStack::instance()->removePanel(this);
	if (this->mRegisteredView != 0) unregisterPanel(this->mRegisteredView);
}

void CocoaPanelWindow::connectWindow() {
	this->ProxyWindowBase::connectWindow();

	this->window->installEventFilter(&this->eventFilter);
	this->updateScreen();

	QObject::connect(
	    this->window,
	    &QQuickWindow::visibleChanged,
	    this,
	    &CocoaPanelWindow::updatePanelStack
	);

	this->window->setFlag(Qt::FramelessWindowHint);
	this->updateFocusable();


	if (this->window->handle() != nullptr) {
		this->cocoaInit();
		this->updatePanelStack();
	}
}

void CocoaPanelWindow::cocoaInit() {
	if (!pointerTrackedPanels().contains(this)) pointerTrackedPanels().append(this);
	ensurePointerPoller();

	if (this->window == nullptr || this->window->handle() == nullptr) return;

	this->updateDimensions();
	this->updateNativeState();
}

void CocoaPanelWindow::updateNativeState() {
	if (this->window == nullptr || this->window->handle() == nullptr) return;

	auto view = this->window->winId();
	if (this->mRegisteredView != 0 && this->mRegisteredView != view) {
		unregisterPanel(this->mRegisteredView);
	}

	this->mRegisteredView = view;

	auto layer = this->mHasLayerOverride
	               ? this->mLayerOverride
	               : (this->bAboveWindows.value() ? PanelLayer::Top : PanelLayer::Bottom);

	registerPanel(view, layer, this->bFocusable.value());
}

void CocoaPanelWindow::setLayerOverride(PanelLayer layer) {
	this->mHasLayerOverride = true;
	this->mLayerOverride = layer;
	this->updateNativeState();
}

void CocoaPanelWindow::updateFocusable() {
	if (this->window == nullptr) return;
	this->window->setFlag(Qt::WindowDoesNotAcceptFocus, !this->bFocusable);

	// setWindowFlags resets the native level and collection behavior.
	this->updateNativeState();

	// Focus follows focusable, not visibility alone. A panel usually binds
	// visible and keyboardFocus to the same state, and QML settles the two in
	// either order: if visible won the race, setVisibleDirect saw a panel that
	// was not focusable yet and never took focus, and on the way out it saw one
	// that had already stopped being focusable and never handed focus back --
	// closing the overlay left the keyboard pointed at the shell. Both calls are
	// idempotent, so the path that already ran costs nothing.
	if (this->window->handle() == nullptr || !this->isVisibleDirect()) return;

	if (this->bFocusable.value()) focusPanel(this->window->winId());
	else unfocusPanel();
}

void CocoaPanelWindow::trySetWidth(qint32 implicitWidth) {
	if (!this->bAnchors.value().horizontalConstraint()) {
		this->ProxyWindowBase::trySetWidth(implicitWidth);
		this->updateDimensions();
	}
}

void CocoaPanelWindow::trySetHeight(qint32 implicitHeight) {
	if (!this->bAnchors.value().verticalConstraint()) {
		this->ProxyWindowBase::trySetHeight(implicitHeight);
		this->updateDimensions();
	}
}

void CocoaPanelWindow::setScreen(QuickshellScreenInfo* screen) {
	this->ProxyWindowBase::setScreen(screen);
	this->updateScreen();
}

void CocoaPanelWindow::updateScreen() {
	auto* newScreen =
	    this->mScreen ? this->mScreen : (this->window ? this->window->screen() : nullptr);

	if (newScreen == this->mTrackedScreen) return;

	if (this->mTrackedScreen != nullptr) {
		QObject::disconnect(this->mTrackedScreen, nullptr, this, nullptr);
	}

	this->mTrackedScreen = newScreen;

	if (this->mTrackedScreen != nullptr) {
		QObject::connect(
		    this->mTrackedScreen,
		    &QScreen::geometryChanged,
		    this,
		    &CocoaPanelWindow::updateDimensionsSlot
		);

		QObject::connect(
		    this->mTrackedScreen,
		    &QScreen::availableGeometryChanged,
		    this,
		    &CocoaPanelWindow::updateDimensionsSlot
		);
	}

	this->updateDimensions();
}

void CocoaPanelWindow::updateDimensionsSlot() { this->updateDimensions(); }

void CocoaPanelWindow::updateDimensions(bool propagate) {
	if (this->window == nullptr || this->window->handle() == nullptr
	    || this->mTrackedScreen == nullptr)
		return;

	// availableGeometry excludes the menu bar and dock, which is the only screen
	// space macOS actually reserves. Panels coexist with them by default.
	auto screenGeometry = this->mTrackedScreen->availableGeometry();

	if (this->bExclusionMode != ExclusionMode::Ignore) {
		for (auto* panel: CocoaPanelStack::instance()->panels(this)) {
			if (panel == this) break;
			if (panel->bAboveWindows != this->bAboveWindows) continue;
			if (panel->mTrackedScreen != this->mTrackedScreen) continue;

			auto edge = panel->bcExclusionEdge.value();
			auto exclusiveZone = panel->bcExclusiveZone.value();

			screenGeometry.adjust(
			    edge == Qt::LeftEdge ? exclusiveZone : 0,
			    edge == Qt::TopEdge ? exclusiveZone : 0,
			    edge == Qt::RightEdge ? -exclusiveZone : 0,
			    edge == Qt::BottomEdge ? -exclusiveZone : 0
			);
		}
	}

	auto geometry = QRect();

	auto anchors = this->bAnchors.value();
	auto margins = this->bMargins.value();

	if (anchors.horizontalConstraint()) {
		geometry.setX(screenGeometry.x() + margins.left);
		geometry.setWidth(screenGeometry.width() - margins.left - margins.right);
	} else {
		if (anchors.mLeft) {
			geometry.setX(screenGeometry.x() + margins.left);
		} else if (anchors.mRight) {
			geometry.setX(
			    screenGeometry.x() + screenGeometry.width() - this->implicitWidth() - margins.right
			);
		} else {
			geometry.setX(screenGeometry.x() + screenGeometry.width() / 2 - this->implicitWidth() / 2);
		}

		geometry.setWidth(this->implicitWidth());
	}

	if (anchors.verticalConstraint()) {
		geometry.setY(screenGeometry.y() + margins.top);
		geometry.setHeight(screenGeometry.height() - margins.top - margins.bottom);
	} else {
		if (anchors.mTop) {
			geometry.setY(screenGeometry.y() + margins.top);
		} else if (anchors.mBottom) {
			geometry.setY(
			    screenGeometry.y() + screenGeometry.height() - this->implicitHeight() - margins.bottom
			);
		} else {
			geometry.setY(screenGeometry.y() + screenGeometry.height() / 2 - this->implicitHeight() / 2);
		}

		geometry.setHeight(this->implicitHeight());
	}

	this->window->setGeometry(geometry);

	if (propagate) {
		CocoaPanelStack::instance()->updateLowerDimensions(this);
		// Every input to the reservation -- zone, edge, screen, visibility --
		// comes through here.
		CocoaPanelStack::instance()->publishReservation();
	}
}

void CocoaPanelWindow::onPolished() {
	// Upstream's onPolished turns the mask into QWindow::setMask plus
	// WindowTransparentForInput when it is empty. On cocoa setMask clips the
	// rendered layer to the region, so the mask is kept here as a hit-test
	// region instead and the window is never told about it; the pointer poll
	// applies it (updatePointerInside). Everything else upstream polishes is
	// nothing, so this replaces rather than extends it.
	if (this->pendingPolish.inputMask) {
		this->mHasMask = this->mMask != nullptr;
		this->mMaskRegion = this->mHasMask
		                      ? this->mMask->applyTo(QRect(0, 0, this->width(), this->height()))
		                      : QRegion();
		this->pendingPolish.inputMask = false;

		qInfo(
		    "cocoa: mask -> hit-test (%lld rects)",
		    static_cast<long long>(this->mHasMask ? this->mMaskRegion.rectCount() : -1)
		);

		// A pointer resting on the panel is inside or outside the new region
		// right now, not at its next move.
		this->updatePointerInside(QCursor::pos());
	}

	emit this->polished();
}

void CocoaPanelWindow::updatePanelStack() {
	if (this->window->isVisible()) {
		CocoaPanelStack::instance()->addPanel(this);
	} else {
		CocoaPanelStack::instance()->removePanel(this);
	}
}

// CocoaPanelInterface

CocoaPanelInterface::CocoaPanelInterface(QObject* parent)
    : PanelWindowInterface(parent)
    , panel(new CocoaPanelWindow(this)) {
	this->connectSignals();

	// clang-format off
	QObject::connect(this->panel, &CocoaPanelWindow::anchorsChanged, this, &CocoaPanelInterface::anchorsChanged);
	QObject::connect(this->panel, &CocoaPanelWindow::marginsChanged, this, &CocoaPanelInterface::marginsChanged);
	QObject::connect(this->panel, &CocoaPanelWindow::exclusiveZoneChanged, this, &CocoaPanelInterface::exclusiveZoneChanged);
	QObject::connect(this->panel, &CocoaPanelWindow::exclusionModeChanged, this, &CocoaPanelInterface::exclusionModeChanged);
	QObject::connect(this->panel, &CocoaPanelWindow::aboveWindowsChanged, this, &CocoaPanelInterface::aboveWindowsChanged);
	QObject::connect(this->panel, &CocoaPanelWindow::focusableChanged, this, &CocoaPanelInterface::focusableChanged);
	QObject::connect(this->panel, &CocoaPanelWindow::animateChanged, this, &CocoaPanelInterface::animateChanged);
	// clang-format on
}

void CocoaPanelInterface::onReload(QObject* oldInstance) {
	QQmlEngine::setContextForObject(this->panel, QQmlEngine::contextForObject(this));

	auto* old = qobject_cast<CocoaPanelInterface*>(oldInstance);
	this->panel->reload(old != nullptr ? old->panel : nullptr);
}

ProxyWindowBase* CocoaPanelInterface::proxyWindow() const { return this->panel; }

CocoaLayershell* CocoaPanelInterface::layershell() {
	if (!this->mLayershell) {
		this->mLayershell = new CocoaLayershell(this->panel, this);
	}

	return this->mLayershell;
}


// NOLINTBEGIN
#define proxyPair(type, get, set)                                                                  \
	type CocoaPanelInterface::get() const { return this->panel->get(); }                             \
	void CocoaPanelInterface::set(type value) { this->panel->set(value); }

proxyPair(Anchors, anchors, setAnchors);
proxyPair(Margins, margins, setMargins);
proxyPair(qint32, exclusiveZone, setExclusiveZone);
proxyPair(ExclusionMode::Enum, exclusionMode, setExclusionMode);
proxyPair(bool, focusable, setFocusable);
proxyPair(bool, aboveWindows, setAboveWindows);
proxyPair(bool, animate, setAnimate);

#undef proxyPair
// NOLINTEND

} // namespace qs::cocoa
