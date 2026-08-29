# Porting Quickshell to macOS — how this works, and how to extend it

Quickshell's platform code lives in C++ behind a plugin seam. This document is
for anyone adding macOS support for a Quickshell module: where the seam is, what
must be C++ and what can be QML, and what is already done.

## Build it

```sh
bin/qs-build            # clone upstream, apply the patch, build, install, sign
bin/qs-build --clean    # from scratch
```

Or directly, in a checkout with the patch applied:

```sh
cmake -B build && cmake --build build
```

No flags. Every Linux-only subsystem (Wayland, X11, the D-Bus services,
Bluetooth, NetworkManager, jemalloc, the crash handler) now defaults **off on
Apple** and `COCOA` defaults on, so a first configure on a Mac just works.

> **Copying the binary breaks it.** A `cp` of a Mach-O file invalidates its
> signature and the kernel then kills it on exec with *no output at all* —
> it looks like the binary silently does nothing. Always
> `codesign -f -s - <binary>` after copying. `bin/qs-bundle` does this for you.

The built binary is installed as `Quickshell.app/Contents/MacOS/quickshell`
(`Info.plist` comes from `assets/Quickshell.plist`), and `bin/qs` — the one
command — execs that real path. `bin/quickshell` is a two-line exec wrapper
onto it for the paths that still know that name — not a symlink, because
`NSBundle.mainBundle` resolves the bundle from the executable's real path and a
symlink outside the bundle leaves the process with no bundle at all. Both the
bundle and the wrapper are generated and gitignored. See "TCC identity" below
for why, and `tests/bundle.sh` for the check.

## The seam

Platform variation happens in two places, both C++:

**1. `QsEnginePlugin`** (`src/core/plugin.hpp`) — a static plugin that declares
when it applies:

```cpp
class CocoaPlugin: public QsEnginePlugin {
    bool applies() override { return QGuiApplication::platformName() == "cocoa"; }
    void registerTypes() override { /* ... */ }
};
QS_REGISTER_PLUGIN(CocoaPlugin);
```

The Wayland backend claims `"wayland"`, X11 claims `"xcb"`, ours claims
`"cocoa"`. This is how `PanelWindow` resolves to a different implementation per
platform without user QML changing.

**2. `qt_add_qml_module`** — each module URI is created by a CMake target
compiled into the binary. `Quickshell.Wayland` on Linux is built from
`src/wayland/`; on macOS it is built from `src/cocoa/wayland/`.

### What must be C++

QML has no syntax for these, so a module using any of them cannot be provided as
loose QML files:

| | why it matters here |
|---|---|
| `QML_ATTACHED` | `WlrLayershell.layer: WlrLayer.Bottom` — used by 31 files in end-4 alone |
| `QML_UNCREATABLE` | the "No PanelWindow backend loaded." guard |
| `QML_VALUE_TYPE` | `Box`, `Margins`, `panelAnchors`, `surfaceFormat` |
| real singletons | shared with C++, not just a QML object |

Everything else can stay QML — but as `QML_FILES` **inside the module target**,
not as loose files on `QML2_IMPORT_PATH`. Loose files are invisible to qmllint
and to the build, and are silently shadowed if someone enables the real module.

### Layout

```
src/cocoa/
  CMakeLists.txt          add_subdirectory per area, gated on COCOA
  init.cpp                CocoaPlugin : QsEnginePlugin
  nswindow.hpp/.mm        shared NSWindow helpers (levels, collection behavior)
  panel_window.hpp/.cpp   the PanelWindow backend
  wayland/                URI Quickshell.Wayland — C++ WlrLayershell + QML files
```

## Adding a module

Take `src/cocoa/wayland/` as the worked example.

1. `mkdir src/cocoa/<area>/` with its own `CMakeLists.txt`:
   ```cmake
   qt_add_library(quickshell-cocoa-<area> STATIC thing.cpp)
   qt_add_qml_module(quickshell-cocoa-<area>
       URI Quickshell.<Area>
       VERSION 0.1
       QML_FILES qml/Thing.qml
   )
   install_qml_module(quickshell-cocoa-<area>)
   target_link_libraries(quickshell-cocoa-<area> PRIVATE Qt::Quick "-framework AppKit")
   target_link_libraries(quickshell PRIVATE quickshell-cocoa-<area>plugin)
   ```
2. `add_subdirectory(<area>)` from `src/cocoa/CMakeLists.txt`.
3. **Match upstream's API exactly** — property, signal and method names. Read
   the Linux implementation under `src/wayland/`, `src/services/` etc. and mirror
   it. A macOS module whose members are named differently is useless: the whole
   point is that a config written for Linux keeps working.
4. Where something cannot work on macOS, still declare it with a sane inert
   default (empty list, `false`, no-op method) so bindings resolve, and say why
   in a comment at the top of the file.
5. Singletons declared as `QML_FILES` need telling explicitly:
   ```cmake
   set_source_files_properties(qml/Thing.qml PROPERTIES QT_QML_SINGLETON_TYPE TRUE)
   ```

## Status

**Native (C++, in the binary)**

`Quickshell` core · `Quickshell.Io` · `Quickshell.Widgets` · `PanelWindow`,
`FloatingWindow`, `PopupWindow` · `Quickshell.Wayland` (`WlrLayershell` attached
type driving NSWindow level; `ToplevelManager`/`Toplevel` over yabai)

**Shims (loose QML — should migrate into the binary)**

`Quickshell.Hyprland` (yabai) · `Services.Mpris` (media-control) ·
`Services.UPower` (pmset) · `Services.Pipewire` (default sink only) ·
`Quickshell.Bluetooth` · `org.kde.kirigami` (`Icon` only)

**Inert but present, so configs load**

`Services.SystemTray` · `Services.Notifications` · `Services.Polkit` ·
`Services.Pam` · `org.kde.syntaxhighlighting`

**Not possible on macOS — document, don't shim**

Hosting other apps' menu-bar items · acting as the notification server ·
observing now-playing through public API · per-app volume control (needs a HAL
plugin) · a *secure* session lock · Spaces enumeration without private CGS ·
greetd · polkit

## Roadmap, by value over effort

**Small.** `GlobalShortcut` via Carbon `RegisterEventHotKey` (removes the skhd
dependency entirely) · `IdleMonitor` via `CGEventSourceSecondsSinceLastEventType`
and `IdleInhibitor` via `IOPMAssertionCreateWithName` (both currently fork a
subprocess every second) · `UPower` via `IOPSCopyPowerSourcesInfo` +
`IOPSNotificationCreateRunLoopSource` · `Pipewire` default device via CoreAudio
property listeners.

**Medium.** `ScreencopyView` via ScreenCaptureKit (`SCStream` → `IOSurface` →
`QSGTexture`) · `Networking` via SystemConfiguration + CoreWLAN, with
`CLLocationManager` authorization to fix the redacted SSID · `ToplevelManager`
via `CGWindowListCopyWindowInfo` + `AXUIElement`, which would drop the yabai
dependency · `Bluetooth` via IOBluetooth.

**Blocked on a bundle.** Running as a bare Mach-O binary gives no bundle
identifier. That blocks `UNUserNotificationCenter` outright and keys Screen
Recording / Accessibility grants to the binary path, so every rebuild loses them.
A `.app` target should land before any permission-gated feature.

## Upstreamable

`src/network/` already has the right shape: an abstract `NetworkBackend`
(`src/network/qml.hpp`), a NetworkManager implementation under `src/network/nm/`,
and a `NetworkBackendType` enum. A macOS backend belongs at
`src/network/scnetwork/` implementing the same interface — a contribution
upstream could take with no fork divergence.

SystemTray, Mpris, UPower and Notifications have no such interface; their
QML-facing type *is* the D-Bus client. Getting upstream to give those the same
backend seam `src/network/` has is the single highest-leverage change for
cross-platform Quickshell.

## Gotchas

- **Re-sign after copying the binary** (see above). This one wastes hours.
- The launchers put `bin/` first on `PATH`. It holds `notify-send`, `xdg-open`,
  `pidof` and `qs` stand-ins that configs shell out to by bare name. Nothing is
  installed system-wide.
- All launchers share `XDG_RUNTIME_DIR=/tmp/quickshell-$UID`. If you start a
  shell with a different one, `qs ipc` cannot reach it.
- `~/.config/quickshell/` carries `// macos: ` markers where a line was disabled.
  Grep for that exact marker — two `WlrLayershell` lines were already commented
  out upstream and must stay that way.
- `Quickshell.WindowManager` compiles on macOS but only speaks ext-workspace-v1,
  so it is present and permanently empty rather than absent.

## TCC identity

macOS records every privacy grant (Screen Recording, Accessibility, Full Disk
Access, Location, Automation) against the requesting program's *designated
requirement*. For a bare ad-hoc-signed binary that requirement is the cdhash,
so every rebuild produced a new program and every grant died with it — the
shell's `screencapture` path, SSID, weather GPS and the notification bridge
all broke after the next `qs-build`. Inside a bundle signed with a certificate
the requirement is "bundle id `org.quickshell.shell`, signed by this
certificate", which a rebuild does not change.

`bin/qs-bundle` (called by `qs-build` and `qs-dev`) builds the bundle, signs it
with `$QS_CODESIGN_IDENTITY` or ad-hoc when that is unset, and rewrites
`bin/quickshell` as the wrapper. Ad-hoc signing works today but keeps the
per-build identity. Two one-time steps make it stable — these need the user's
keychain and the System Settings UI, so nothing here does them for you.

### 1. Create the "Quickshell Dev" code-signing certificate (once)

Keychain Access → menu **Keychain Access → Certificate Assistant → Create a
Certificate…**

- Name: `Quickshell Dev`
- Identity Type: `Self Signed Root`
- Certificate Type: **`Code Signing`**
- Leave "Let me override defaults" unchecked → **Create**.

It lands in the *login* keychain. Check with:

```sh
security find-identity -v -p codesigning     # lists "Quickshell Dev"
```

Then build with it, and export the variable in the shell you build from
(`~/.zshenv`, or the environment of whatever runs `qs-build`):

```sh
export QS_CODESIGN_IDENTITY="Quickshell Dev"
bin/qs-build
codesign -dvv Quickshell.app 2>&1 | grep Authority     # Authority=Quickshell Dev
```

The first `codesign` with a new certificate pops a keychain dialog asking to
let `codesign` use the key: choose **Always Allow**, or every rebuild asks
again.

Command-line alternative: an OpenSSL self-signed certificate with the
code-signing EKU, imported into the login keychain. The PKCS#12 must use the
legacy PBE algorithms or `security import` rejects it ("MAC verification
failed"), and the final `add-trusted-cert` opens an authorization dialog —
until the certificate is trusted, `find-identity -v` lists nothing and
`codesign` reports "no identity found".

```sh
cd "$(mktemp -d)"
cat > ext.cnf <<'CNF'
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = Quickshell Dev
[ext]
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
basicConstraints = critical, CA:false
CNF
openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -config ext.cnf \
    -keyout key.pem -out cert.pem
openssl pkcs12 -export -inkey key.pem -in cert.pem -name "Quickshell Dev" \
    -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg sha1 \
    -passout pass:qs -out qs.p12
security import qs.p12 -k ~/Library/Keychains/login.keychain-db -P qs \
    -T /usr/bin/codesign
security add-trusted-cert -p codeSign -k ~/Library/Keychains/login.keychain-db cert.pem
security find-identity -v -p codesigning        # now lists "Quickshell Dev"
```

### 2. Grant the permissions to Quickshell.app (once)

System Settings → **Privacy & Security**. In each list press **+** (or drag
`Quickshell.app` from the repo root into the list) and enable the toggle:

- **Screen Recording** — window thumbnails (`qs-window-thumbs`), the
  screenshot / region tools, `ScreencopyView`.
- **Accessibility** — event taps, focus grabs, window management helpers.
- **Full Disk Access** — the notification bridge reads Notification Center's
  database.
- **Location Services** — the weather widget; this one prompts on first use
  rather than needing to be added by hand, once the app is signed.
- **Automation** — prompts per target application (System Events, Music, …)
  the first time an `osascript` runs; there is nothing to add in advance.

Screen Recording and Accessibility changes need the shell restarted
(`qs-start`) before they take effect. After a rebuild with the
certificate in place nothing needs re-granting; after a rebuild *without* it
(ad-hoc), every one of these has to be redone, which is why step 1 exists.

Which program macOS holds responsible for a subprocess's request is inherited
from the process that launched it, so launch the shell through `qs-start` (which
execs the bundle binary through `qs`) rather than from a terminal, whose own
grants would otherwise be the ones consulted.
