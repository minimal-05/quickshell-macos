#pragma once

#include <qobject.h>
#include <qqmlintegration.h>
#include <qtmetamacros.h>

namespace qs::cocoa {

/// Notices clicks that land outside this process's own windows.
///
/// This is the macOS stand-in for hyprland_focus_grab_v1, which end-4 uses
/// through its GlobalFocusGrab service to dismiss the sidebars, the overview,
/// the cheatsheet and the wallpaper selector when the user clicks away. Without
/// it those panels have no way to learn the click happened and stay open.
///
/// The mechanism is an AppKit global event monitor, which by definition only
/// receives events that were delivered to some OTHER application -- so every
/// click it sees is already known to be outside our windows, and no hit testing
/// against panel geometry is needed. It observes only; it cannot consume the
/// click, so the click still reaches whatever the user aimed at, which is the
/// behaviour upstream has too.
///
/// A mouse-down is not by itself a click: it's also how every window drag on
/// macOS begins, and title-bar dragging is routine here in a way it isn't on
/// a tiling WM. So this waits for the matching mouse-up and only dismisses if
/// the pointer barely moved in between -- otherwise it was a drag, not a
/// click, and the panel should stay open.
class FocusGrab: public QObject {
	Q_OBJECT;
	QML_ELEMENT;
	Q_PROPERTY(bool active READ active WRITE setActive NOTIFY activeChanged);

public:
	explicit FocusGrab(QObject* parent = nullptr): QObject(parent) {}
	~FocusGrab() override;
	Q_DISABLE_COPY_MOVE(FocusGrab);

	[[nodiscard]] bool active() const { return this->mActive; }
	void setActive(bool active);

signals:
	void activeChanged();
	/// A click landed in another application.
	void dismissed();

private:
	void installMonitor();
	void removeMonitor();

	bool mActive = false;
	void* mMonitor = nullptr;

	// Screen-space mouse-down location, held between down and up so the
	// handler can tell a click from a drag. Plain doubles (not NSPoint) so
	// this header stays includable from plain C++.
	bool mArmed = false;
	double mDownX = 0;
	double mDownY = 0;
};

} // namespace qs::cocoa
