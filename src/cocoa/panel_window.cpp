#include "panel_window.hpp"
#include <map>

#include <qevent.h>
#include <qlist.h>
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
	}

	void removePanel(CocoaPanelWindow* panel) {
		if (!panel->engineGeneration) return;

		auto& panels = this->mPanels[panel->engineGeneration];
		if (panels.removeOne(panel)) {
			if (panels.isEmpty()) {
				this->mPanels.erase(panel->engineGeneration);
				return;
			}

			for (auto* other: panels) {
				other->updateDimensions();
			}
		}
	}

	void updateLowerDimensions(CocoaPanelWindow* exclude) {
		if (!exclude->engineGeneration) return;

		auto found = false;
		for (auto* panel: this->mPanels[exclude->engineGeneration]) {
			if (panel == exclude) found = true;
			else if (found) panel->updateDimensions(false);
		}
	}

private:
	std::map<EngineGeneration*, QList<CocoaPanelWindow*>> mPanels;
};

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
}

CocoaPanelWindow::~CocoaPanelWindow() {
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

	if (propagate) CocoaPanelStack::instance()->updateLowerDimensions(this);
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

#undef proxyPair
// NOLINTEND

} // namespace qs::cocoa
