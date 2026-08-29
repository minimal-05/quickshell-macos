enable_language(OBJCXX)

qt_add_library(quickshell-cocoa STATIC
	nswindow.mm
	appicon.mm
	focusgrab.mm
	panel_window.cpp
	hotkeys.mm # round2/native-input
	clipboard.mm # round2/native-input
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

# round2/native-input: GlobalShortcut chords via Carbon RegisterEventHotKey, and
# the default chord table compiled in from shortcuts.json so a fresh checkout
# has working hotkeys before qs-install-keybinds copies that file to ~/.config.
file(READ "${CMAKE_CURRENT_SOURCE_DIR}/shortcuts.json" QS_COCOA_SHORTCUTS_JSON)
file(CONFIGURE OUTPUT "${CMAKE_CURRENT_BINARY_DIR}/shortcuts_json.hpp"
	CONTENT "static const char* const DEFAULT_SHORTCUTS_JSON = R\"qsjson(@QS_COCOA_SHORTCUTS_JSON@)qsjson\";\n")
set_property(DIRECTORY APPEND PROPERTY CMAKE_CONFIGURE_DEPENDS shortcuts.json)
target_include_directories(quickshell-cocoa PRIVATE "${CMAKE_CURRENT_BINARY_DIR}")
target_link_libraries(quickshell-cocoa PRIVATE "-framework Carbon")
