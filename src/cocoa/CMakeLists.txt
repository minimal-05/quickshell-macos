enable_language(OBJCXX)

qt_add_library(quickshell-cocoa STATIC
	nswindow.mm
	appicon.mm
	focusgrab.mm
	panel_window.cpp
	sysstats.mm # round2/native-stats-power
)

qt_add_qml_module(quickshell-cocoa
	URI Quickshell.Cocoa
	VERSION 0.1
	DEPENDENCIES QtQuick
)

install_qml_module(quickshell-cocoa)

add_library(quickshell-cocoa-init OBJECT init.cpp)

# QuartzCore for CAMediaTimingFunction, used by the panel open/close animations.
target_link_libraries(quickshell-cocoa PRIVATE Qt::Quick "-framework AppKit" "-framework QuartzCore")
target_link_libraries(quickshell-cocoa-init PRIVATE Qt::Quick Qt::Qml "-framework AppKit")

target_link_libraries(quickshell PRIVATE quickshell-cocoaplugin quickshell-cocoa-init)

# Quickshell.Wayland compatibility module (WlrLayershell attached type + friends).
add_subdirectory(wayland)

