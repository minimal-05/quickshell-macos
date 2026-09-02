#pragma once

namespace qs::cocoa {

/// Ask macOS for Location Services authorization once, if the user has not
/// already answered.
///
/// Nothing here reads a location. Requesting is a prerequisite in its own
/// right: both the weather widget's location and a real Wi-Fi SSID (from
/// `networksetup -getairportnetwork` / `system_profiler SPAirPortDataType`,
/// as the darwin-dotfiles Wi-Fi dialog shells out to) come back as the
/// literal string "<redacted>" to a process macOS has not authorized. Asking
/// is what makes Quickshell appear in System Settings -> Privacy & Security
/// -> Location Services at all, so there is something for the user to grant.
/// See NSLocationWhenInUseUsageDescription in assets/Quickshell.plist for the
/// prompt text, and "TCC identity" in PLATFORM.md for why this only sticks
/// when the Mach-O is signed with a stable identity.
///
/// Idempotent; the cocoa plugin calls it once at init. A repeat call after
/// the user has already answered (authorized, denied or restricted) is a
/// silent no-op on Apple's side -- this only checks notDetermined to skip
/// re-registering the delegate.
void requestLocationAuthorization();

} // namespace qs::cocoa
