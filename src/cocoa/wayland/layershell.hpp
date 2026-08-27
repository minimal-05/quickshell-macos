#pragma once

#include <qobject.h>
#include <qpointer.h>
#include <qqmlintegration.h>
#include <qstring.h>
#include <qtmetamacros.h>
#include <qtypes.h>

#include "../panel_window.hpp"

// A macOS stand-in for wlr-layer-shell.
//
// Configs written for Linux configure their panels with an attached object:
//
//     PanelWindow { WlrLayershell.layer: WlrLayer.Bottom }
//
// Attached objects can only come from C++ (QML_ATTACHED), which is why this
// lives in the backend rather than alongside the pure-QML compatibility shims.
// Without it, a config asking to sit *below* windows silently gets the default
// above-windows treatment — which puts a full screen wallpaper layer on top of
// everything and swallows every click.
//
// `layer` is real: it selects the NSWindow level. `namespace` and
// `keyboardFocus` are accepted and stored so bindings resolve, but macOS has no
// surface namespacing and keyboard focus is decided by `focusable`.

namespace qs::cocoa {

///! Layer a panel is rendered on.
namespace WlrLayer { // NOLINT
Q_NAMESPACE;
QML_ELEMENT;

enum Enum : quint8 {
	/// Below everything, including desktop icons.
	Background = 0,
	/// Above the wallpaper, below ordinary windows.
	Bottom = 1,
	/// Above ordinary windows. Panels and docks live here.
	Top = 2,
	/// Above nearly everything, including other apps' fullscreen spaces.
	Overlay = 3,
};
Q_ENUM_NS(Enum);

} // namespace WlrLayer

///! Keyboard focus mode.
namespace WlrKeyboardFocus { // NOLINT
Q_NAMESPACE;
QML_ELEMENT;

enum Enum : quint8 {
	/// The panel never takes keyboard input.
	None = 0,
	/// Exclusive keyboard access. macOS has no equivalent; treated as OnDemand.
	Exclusive = 1,
	/// The system decides, i.e. the panel can be focused by clicking it.
	OnDemand = 2,
};
Q_ENUM_NS(Enum);

} // namespace WlrKeyboardFocus

class CocoaLayershell: public QObject {
	Q_OBJECT;
	// clang-format off
	/// Which layer the panel sits on. Maps onto the window's native level.
	Q_PROPERTY(qs::cocoa::WlrLayer::Enum layer READ layer WRITE setLayer NOTIFY layerChanged);
	/// Accepted and stored. macOS surfaces have no namespace.
	Q_PROPERTY(QString namespace READ ns WRITE setNamespace NOTIFY namespaceChanged);
	/// Accepted and stored. Use @@PanelWindow.focusable instead.
	Q_PROPERTY(qs::cocoa::WlrKeyboardFocus::Enum keyboardFocus READ keyboardFocus WRITE setKeyboardFocus NOTIFY keyboardFocusChanged);
	// clang-format on
	QML_NAMED_ELEMENT(WlrLayershell);
	QML_ATTACHED(CocoaLayershell);
	QML_UNCREATABLE("WlrLayershell is only available as an attached object.");

public:
	explicit CocoaLayershell(CocoaPanelWindow* panel, QObject* parent = nullptr);

	static CocoaLayershell* qmlAttachedProperties(QObject* object);

	[[nodiscard]] WlrLayer::Enum layer() const { return this->mLayer; }
	void setLayer(WlrLayer::Enum layer);

	[[nodiscard]] QString ns() const { return this->mNamespace; }
	void setNamespace(const QString& ns);

	[[nodiscard]] WlrKeyboardFocus::Enum keyboardFocus() const { return this->mKeyboardFocus; }
	void setKeyboardFocus(WlrKeyboardFocus::Enum focus);

signals:
	void layerChanged();
	void namespaceChanged();
	void keyboardFocusChanged();

private:
	QPointer<CocoaPanelWindow> mPanel;
	WlrLayer::Enum mLayer = WlrLayer::Top;
	WlrKeyboardFocus::Enum mKeyboardFocus = WlrKeyboardFocus::None;
	QString mNamespace;
};

} // namespace qs::cocoa
