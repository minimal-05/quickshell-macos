#pragma once

#include <qevent.h>
#include <qobject.h>
#include <qpointer.h>
#include <qproperty.h>
#include <qqmlintegration.h>
#include <qscreen.h>
#include <qtclasshelpermacros.h>
#include <qtmetamacros.h>
#include <qtypes.h>

#include "../core/doc.hpp"
#include "../core/util.hpp"
#include "../window/panelinterface.hpp"
#include "../window/proxywindow.hpp"
#include "nswindow.hpp"

namespace qs::cocoa {

class CocoaPanelStack;
class CocoaLayershell;

class CocoaPanelEventFilter: public QObject {
	Q_OBJECT;

public:
	explicit CocoaPanelEventFilter(QObject* parent = nullptr): QObject(parent) {}

signals:
	void surfaceCreated();

protected:
	bool eventFilter(QObject* watched, QEvent* event) override;
};

class CocoaPanelWindow: public ProxyWindowBase {
	QSDOC_BASECLASS(PanelWindowInterface);
	Q_OBJECT;
	// clang-format off
	QSDOC_HIDE Q_PROPERTY(Anchors anchors READ anchors WRITE setAnchors NOTIFY anchorsChanged);
	QSDOC_HIDE Q_PROPERTY(qint32 exclusiveZone READ exclusiveZone WRITE setExclusiveZone NOTIFY exclusiveZoneChanged);
	QSDOC_HIDE Q_PROPERTY(ExclusionMode::Enum exclusionMode READ exclusionMode WRITE setExclusionMode NOTIFY exclusionModeChanged);
	QSDOC_HIDE Q_PROPERTY(Margins margins READ margins WRITE setMargins NOTIFY marginsChanged);
	QSDOC_HIDE Q_PROPERTY(bool aboveWindows READ aboveWindows WRITE setAboveWindows NOTIFY aboveWindowsChanged);
	QSDOC_HIDE Q_PROPERTY(bool focusable READ focusable WRITE setFocusable NOTIFY focusableChanged);
	// clang-format on
	QML_ELEMENT;

public:
	explicit CocoaPanelWindow(QObject* parent = nullptr);
	~CocoaPanelWindow() override;
	Q_DISABLE_COPY_MOVE(CocoaPanelWindow);

	void connectWindow() override;
	[[nodiscard]] bool deleteOnInvisible() const override { return false; }

	void trySetWidth(qint32 implicitWidth) override;
	void trySetHeight(qint32 implicitHeight) override;

	void setScreen(QuickshellScreenInfo* screen) override;

	[[nodiscard]] bool aboveWindows() const { return this->bAboveWindows; }
	void setAboveWindows(bool aboveWindows) { this->bAboveWindows = aboveWindows; }

	[[nodiscard]] Anchors anchors() const { return this->bAnchors; }
	void setAnchors(Anchors anchors) { this->bAnchors = anchors; }

	[[nodiscard]] qint32 exclusiveZone() const { return this->bExclusiveZone; }
	void setExclusiveZone(qint32 exclusiveZone) {
		Qt::beginPropertyUpdateGroup();
		this->bExclusiveZone = exclusiveZone;
		this->bExclusionMode = ExclusionMode::Normal;
		Qt::endPropertyUpdateGroup();
	}

	[[nodiscard]] ExclusionMode::Enum exclusionMode() const { return this->bExclusionMode; }
	void setExclusionMode(ExclusionMode::Enum exclusionMode) { this->bExclusionMode = exclusionMode; }

	[[nodiscard]] Margins margins() const { return this->bMargins; }
	void setMargins(Margins margins) { this->bMargins = margins; }

	[[nodiscard]] bool focusable() const { return this->bFocusable; }
	void setFocusable(bool focusable) { this->bFocusable = focusable; }

	/// Pin the window to a specific native level, overriding the coarse
	/// aboveWindows boolean. Set by the WlrLayershell attached object so
	/// layer-shell configs land on the layer they asked for.
	void setLayerOverride(PanelLayer layer);

signals:
	QSDOC_HIDE void anchorsChanged();
	QSDOC_HIDE void exclusiveZoneChanged();
	QSDOC_HIDE void exclusionModeChanged();
	QSDOC_HIDE void marginsChanged();
	QSDOC_HIDE void aboveWindowsChanged();
	QSDOC_HIDE void focusableChanged();

private slots:
	void cocoaInit();
	void updatePanelStack();
	void updateDimensionsSlot();

private:
	void updateScreen();
	void updateNativeState();
	void updateDimensions(bool propagate = true);
	void updateDimensionsCb() { this->updateDimensions(); }
	void updateFocusable();

	QPointer<QScreen> mTrackedScreen = nullptr;
	WId mRegisteredView = 0;
	CocoaPanelEventFilter eventFilter;

	bool mHasLayerOverride = false;
	PanelLayer mLayerOverride = PanelLayer::Top;

	// clang-format off
	Q_OBJECT_BINDABLE_PROPERTY_WITH_ARGS(CocoaPanelWindow, bool, bAboveWindows, true, &CocoaPanelWindow::aboveWindowsChanged);
	Q_OBJECT_BINDABLE_PROPERTY(CocoaPanelWindow, bool, bFocusable, &CocoaPanelWindow::focusableChanged);
	Q_OBJECT_BINDABLE_PROPERTY(CocoaPanelWindow, Anchors, bAnchors, &CocoaPanelWindow::anchorsChanged);
	Q_OBJECT_BINDABLE_PROPERTY(CocoaPanelWindow, Margins, bMargins, &CocoaPanelWindow::marginsChanged);
	Q_OBJECT_BINDABLE_PROPERTY(CocoaPanelWindow, qint32, bExclusiveZone, &CocoaPanelWindow::exclusiveZoneChanged);
	Q_OBJECT_BINDABLE_PROPERTY_WITH_ARGS(CocoaPanelWindow, ExclusionMode::Enum, bExclusionMode, ExclusionMode::Auto, &CocoaPanelWindow::exclusionModeChanged);
	Q_OBJECT_BINDABLE_PROPERTY(CocoaPanelWindow, qint32, bcExclusiveZone);
	Q_OBJECT_BINDABLE_PROPERTY(CocoaPanelWindow, Qt::Edge, bcExclusionEdge);

	QS_BINDING_SUBSCRIBE_METHOD(CocoaPanelWindow, bAboveWindows, updateNativeState, onValueChanged);
	QS_BINDING_SUBSCRIBE_METHOD(CocoaPanelWindow, bAnchors, updateDimensionsCb, onValueChanged);
	QS_BINDING_SUBSCRIBE_METHOD(CocoaPanelWindow, bMargins, updateDimensionsCb, onValueChanged);
	QS_BINDING_SUBSCRIBE_METHOD(CocoaPanelWindow, bcExclusiveZone, updateDimensionsCb, onValueChanged);
	QS_BINDING_SUBSCRIBE_METHOD(CocoaPanelWindow, bFocusable, updateFocusable, onValueChanged);
	// clang-format on

	friend class CocoaPanelStack;
};

class CocoaPanelInterface: public PanelWindowInterface {
	Q_OBJECT;

public:
	explicit CocoaPanelInterface(QObject* parent = nullptr);

	void onReload(QObject* oldInstance) override;

	[[nodiscard]] ProxyWindowBase* proxyWindow() const override;

	// NOLINTBEGIN
	[[nodiscard]] Anchors anchors() const override;
	void setAnchors(Anchors anchors) override;

	[[nodiscard]] Margins margins() const override;
	void setMargins(Margins margins) override;

	[[nodiscard]] qint32 exclusiveZone() const override;
	void setExclusiveZone(qint32 exclusiveZone) override;

	[[nodiscard]] ExclusionMode::Enum exclusionMode() const override;
	void setExclusionMode(ExclusionMode::Enum exclusionMode) override;

	[[nodiscard]] bool aboveWindows() const override;
	void setAboveWindows(bool aboveWindows) override;

	[[nodiscard]] bool focusable() const override;
	void setFocusable(bool focusable) override;
	// NOLINTEND

	/// The WlrLayershell attached object for this panel, created on first use.
	[[nodiscard]] CocoaLayershell* layershell();

private:
	CocoaPanelWindow* panel;
	CocoaLayershell* mLayershell = nullptr;
};

} // namespace qs::cocoa
