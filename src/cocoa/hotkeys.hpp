#pragma once

#include <qhash.h>
#include <qlist.h>
#include <qobject.h>
#include <qqmlintegration.h>
#include <qstring.h>
#include <qtmetamacros.h>

namespace qs::cocoa {

/// System-wide keyboard chords behind the Quickshell.Hyprland GlobalShortcut shim.
///
/// Hyprland binds a key to `appid:name` in its own config and reports presses
/// over hyprland_global_shortcuts_v1. macOS has no such protocol, so the shell
/// registers the chords itself with Carbon's RegisterEventHotKey. That API needs
/// no Accessibility grant and reports the press and the release of any chord
/// that ends in a non-modifier key; a bare modifier hold (end-4's SUPER for
/// workspaceNumber) is not a hot key at all and would need a CGEvent tap under
/// Input Monitoring, so those entries are logged and left unbound.
///
/// The chord table is src/cocoa/shortcuts.json, compiled in, overlaid by
/// ~/.config/quickshell-macos/shortcuts.json ($QS_SHORTCUTS):
///     {"quickshell:lock": "ctrl+alt+cmd+l", "quickshell:searchToggle": ["ctrl+alt+cmd+space", "cmd+space"]}
/// Keys are `appid:name` (bare `name` means appid quickshell); a chord is
/// modifiers joined by `+` and a key, with skhd's key names and 0xNN keycodes.
///
/// Overlap policy: any chord ~/.config/skhd/skhdrc ($SKHD_RC) already binds is
/// left to skhd. skhd's event tap sees the key first and swallows it, so binding
/// it here too would at best do nothing and at worst fire an action twice. The
/// table is read once per engine; restart the shell after editing either file.
class Hotkeys: public QObject {
	Q_OBJECT;
	QML_ELEMENT;
	QML_SINGLETON;

public:
	explicit Hotkeys(QObject* parent = nullptr);
	~Hotkeys() override;
	Q_DISABLE_COPY_MOVE(Hotkeys);

	/// Register the chords of `appid:name`; refcounted, so one registration
	/// serves every GlobalShortcut declaring the same name.
	Q_INVOKABLE void bind(const QString& appid, const QString& name);
	Q_INVOKABLE void unbind(const QString& appid, const QString& name);

	// Entry point for the Carbon handler; one chord id per registered chord.
	void dispatch(quint32 chordId, bool pressed);

signals:
	void pressed(const QString& appid, const QString& name);
	void released(const QString& appid, const QString& name);

private:
	void loadTable();

	QHash<QString, QList<quint32>> mChords; // "appid:name" -> chord ids
	QHash<QString, int> mBound;             // "appid:name" -> bind() refcount
	QHash<quint32, QStringList> mListeners; // chord id -> bound "appid:name"s
};

} // namespace qs::cocoa
