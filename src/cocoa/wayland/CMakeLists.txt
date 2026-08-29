# A macOS-side Quickshell.Wayland.
#
# Configs written for Linux import this module. Most of it can be plain QML
# (see qml/ below), but WlrLayershell is an *attached* type and attached types
# can only come from C++ — which is why this module is built into the binary
# rather than shipped as loose QML alongside the other compatibility shims.

qt_add_library(quickshell-cocoa-wayland STATIC
	layershell.cpp
	screencopy.mm # round2/screencapture
)

# qt_add_qml_module does not infer singleton-ness from `pragma Singleton` when
# the file is listed as a QML_FILE, so say it explicitly.
set_source_files_properties(qml/ToplevelManager.qml PROPERTIES QT_QML_SINGLETON_TYPE TRUE)

qt_add_qml_module(quickshell-cocoa-wayland
	URI Quickshell.Wayland
	VERSION 0.1
	DEPENDENCIES QtQuick
	QML_FILES
		qml/ToplevelManager.qml
		qml/Toplevel.qml
		qml/IdleInhibitor.qml
		qml/IdleMonitor.qml
		qml/WlSessionLock.qml
		qml/WlSessionLockSurface.qml
		qml/ShortcutInhibitor.qml
		qml/ShortcutsInhibitor.qml
)

install_qml_module(quickshell-cocoa-wayland)

target_link_libraries(quickshell-cocoa-wayland PRIVATE Qt::Quick "-framework AppKit")
target_link_libraries(quickshell PRIVATE quickshell-cocoa-waylandplugin)

# round2/screencapture: ScreencopyView on ScreenCaptureKit. ARC for this one
# file only; the rest of the backend is MRC and does not hold SCK objects.
set_source_files_properties(screencopy.mm PROPERTIES COMPILE_OPTIONS "-fobjc-arc")
target_link_libraries(quickshell-cocoa-wayland PRIVATE "-framework ScreenCaptureKit" "-framework CoreMedia" "-framework CoreVideo" "-framework CoreGraphics")
