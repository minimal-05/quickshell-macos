enable_language(OBJCXX)

qt_add_library(quickshell-cocoa STATIC
	nswindow.mm
	appicon.mm
	focusgrab.mm
	filewatch.cpp
	panel_window.cpp
	sysstats.mm # round2/native-stats-power
	power.mm # round2/native-stats-power
	coreaudio.mm # round2/native-audio
	hotkeys.mm # round2/native-input
	clipboard.mm # round2/native-input
	locationauth.mm
)

qt_add_qml_module(quickshell-cocoa
	URI Quickshell.Cocoa
	VERSION 0.1
	DEPENDENCIES QtQuick
)

install_qml_module(quickshell-cocoa)

add_library(quickshell-cocoa-init OBJECT init.cpp)

# QuartzCore: CAMediaTimingFunction for the panel open/close animations.
# CoreAudio and AudioToolbox: the device HAL and the virtual main volume
# selector (coreaudio.mm). CoreLocation: the Location Services request behind
# the weather widget and real Wi-Fi SSIDs (locationauth.mm). IOKit: the power
# sources and the AppleSmartBattery registry node (power.mm). CoreGraphics:
# the idle timer (sysstats.mm). Carbon: RegisterEventHotKey (hotkeys.mm).
target_link_libraries(quickshell-cocoa PRIVATE Qt::Quick
	"-framework AppKit" "-framework QuartzCore" "-framework CoreAudio" "-framework AudioToolbox"
	"-framework CoreLocation" "-framework IOKit" "-framework CoreGraphics" "-framework Carbon")
target_link_libraries(quickshell-cocoa-init PRIVATE Qt::Quick Qt::Qml "-framework AppKit")

target_link_libraries(quickshell PRIVATE quickshell-cocoaplugin quickshell-cocoa-init)

# Quickshell.Wayland compatibility module (WlrLayershell attached type + friends).
add_subdirectory(wayland)

# The default GlobalShortcut chord table, compiled in from shortcuts.json so a fresh checkout
# has working hotkeys before a copy of that file lands in ~/.config/quickshell-macos.
file(READ "${CMAKE_CURRENT_SOURCE_DIR}/shortcuts.json" QS_COCOA_SHORTCUTS_JSON)
file(CONFIGURE OUTPUT "${CMAKE_CURRENT_BINARY_DIR}/shortcuts_json.hpp"
	CONTENT "static const char* const DEFAULT_SHORTCUTS_JSON = R\"qsjson(@QS_COCOA_SHORTCUTS_JSON@)qsjson\";\n")
set_property(DIRECTORY APPEND PROPERTY CMAKE_CONFIGURE_DEPENDS shortcuts.json)
target_include_directories(quickshell-cocoa PRIVATE "${CMAKE_CURRENT_BINARY_DIR}")
