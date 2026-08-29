#pragma once

#include <qevent.h>
#include <qobject.h>
#include <qpointer.h>
#include <qproperty.h>
#include <qqmlintegration.h>
#include <qscreen.h>
#include <qtclasshelpermacros.h>
#include <qpoint.h>
#include <qtimer.h>
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
	/// Whether the panel plays the compositor's open/close animation.
	///
	/// On Hyprland every layer surface pops in and out (end-4's `layersIn` /
	/// `layersOut`), which this backend reproduces. Set false for a panel that
	/// needs `visible: false` to take effect at once rather than after the
	/// 270 ms close. Defaults to true.
	Q_PROPERTY(bool animate READ animate WRITE setAnimate NOTIFY animateChanged);
	// clang-format on
	QML_ELEMENT;

public:
	explicit CocoaPanelWindow(QObject* parent = nullptr);
	~CocoaPanelWindow() override;
	Q_DISABLE_COPY_MOVE(CocoaPanelWindow);

	void connectWindow() override;
	[[nodiscard]] bool deleteOnInvisible() const override { return false; }

	void setVisibleDirect(bool visible) override;

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

	[[nodiscard]] bool animate() const { return this->mAnimate; }
	void setAnimate(bool animate);

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
	void animateChanged();

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

	[[nodiscard]] PanelAnimation openCloseAnimation() const;
	void finishOpenCloseAnimation();

	/// Release the native window behind a panel that has stayed hidden.
	void releaseHiddenGraphics();

public:
	/// Post a synthetic leave when the pointer is no longer over this panel.
	///
	/// A backstop, not the primary mechanism. This was originally added on the
	/// assumption that Qt never sees the exit for a borderless, never-key panel in
	/// an accessory process; that assumption was afterwards measured and is FALSE.
	/// Under exactly those conditions a hoverEnabled MouseArea reported
	/// containsMouse false 5ms after a single pointer event moved off the panel,
	/// so the exit does arrive. The always-active NSTrackingArea installed in
	/// applyConfig is what delivers it, and it is the fastest of the options
	/// measured.
	///
	/// This is kept because it costs almost nothing -- a cursor sample was
	/// measured at ~0.006ms, about 0.04% of one core at this interval -- and it
	/// covers the cases the tracking area cannot: a panel that moves or is
	/// destroyed out from under a stationary pointer, and a window appearing over
	/// one. It never fires spuriously, since it only acts when the pointer is
	/// outside the whole window.
	void updatePointerInside(const QPoint& pointer);

private:

	QPointer<QScreen> mTrackedScreen = nullptr;
	WId mRegisteredView = 0;
	CocoaPanelEventFilter eventFilter;

	// A closing panel stays mapped until its animation has played out; the timer
	// is what finally hides it. Geometry updates are NOT held off meanwhile --
	// popin scales the rendered layer and never moves the frame, so the window
	// can be resized and repositioned freely while it plays.
	QTimer mAnimationTimer;
	bool mClosing = false;
	bool mAnimate = true;

	// Hiding a panel does not free what it holds on the GPU: measured on a
	// 600pt full-height panel, Qt's own release (non-persistent scene graph and
	// graphics, releaseResources) dropped IOAccelerator from 3.9 MB to 0.4 MB
	// but one of the two 10 MB Metal drawables stayed mapped for as long as the
	// NSWindow existed, whatever was done to the CAMetalLayer. Two hidden
	// full-height panels held 113 MB that way. Releasing the platform window
	// itself is what frees it, so a panel that stays hidden past this timer
	// destroys its native window and gets a fresh one on show. The delay keeps
	// a hover popup that reopens at once from paying for a new window each time.
	QTimer mReleaseTimer;

	bool mHasLayerOverride = false;
	bool mPointerInside = false;
	QPoint mLastPointer;
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
	/// See CocoaPanelWindow::animate.
	Q_PROPERTY(bool animate READ animate WRITE setAnimate NOTIFY animateChanged);

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

	[[nodiscard]] bool animate() const;
	void setAnimate(bool animate);

	/// The WlrLayershell attached object for this panel, created on first use.
	[[nodiscard]] CocoaLayershell* layershell();

signals:
	void animateChanged();

private:
	CocoaPanelWindow* panel;
	CocoaLayershell* mLayershell = nullptr;
};

} // namespace qs::cocoa
