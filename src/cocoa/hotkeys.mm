#include "hotkeys.hpp"

#include <qdir.h>
#include <qfile.h>
#include <qjsonarray.h>
#include <qjsondocument.h>
#include <qjsonobject.h>
#include <qlogging.h>
#include <qset.h>
#include <qstringlist.h>

// Carbon's AssertMacros.h otherwise defines check()/verify()/require() as
// macros, which collide with ordinary identifiers in Qt headers.
#define __ASSERT_MACROS_DEFINE_VERSIONS_WITHOUT_UNDERSCORES 0
#import <Carbon/Carbon.h>

#include "shortcuts_json.hpp" // generated from shortcuts.json, see CMakeLists.txt

namespace qs::cocoa {

namespace {

// A chord id is the EventHotKeyID Carbon hands back: Carbon modifier bits
// (cmdKey 0x100 .. controlKey 0x1000) shifted over the 7-bit virtual keycode.
constexpr quint32 chordId(quint32 keycode, quint32 modifiers) { return (modifiers << 8) | keycode; }
constexpr quint32 chordKeycode(quint32 id) { return id & 0xFF; }
constexpr quint32 chordModifiers(quint32 id) { return id >> 8; }

// ponytail: keycodes of the US ANSI layout, the same fixed table skhd's key
// names resolve to. Resolving letters through UCKeyTranslate against the active
// input source would follow a non-US layout; nothing here needs that yet.
const QHash<QString, quint32>& keycodes() {
	static const QHash<QString, quint32> table = {
	    {"a", 0},        {"s", 1},         {"d", 2},         {"f", 3},          {"h", 4},
	    {"g", 5},        {"z", 6},         {"x", 7},         {"c", 8},          {"v", 9},
	    {"b", 11},       {"q", 12},        {"w", 13},        {"e", 14},         {"r", 15},
	    {"y", 16},       {"t", 17},        {"1", 18},        {"2", 19},         {"3", 20},
	    {"4", 21},       {"6", 22},        {"5", 23},        {"=", 24},         {"9", 25},
	    {"7", 26},       {"-", 27},        {"8", 28},        {"0", 29},         {"]", 30},
	    {"o", 31},       {"u", 32},        {"[", 33},        {"i", 34},         {"p", 35},
	    {"return", 36},  {"enter", 36},    {"l", 37},        {"j", 38},         {"'", 39},
	    {"k", 40},       {";", 41},        {"\\", 42},       {",", 43},         {"/", 44},
	    {"n", 45},       {"m", 46},        {".", 47},        {"tab", 48},       {"space", 49},
	    {"`", 50},       {"backspace", 51}, {"escape", 53},  {"esc", 53},       {"f17", 64},
	    {"f18", 79},     {"f19", 80},      {"f20", 90},      {"f5", 96},        {"f6", 97},
	    {"f7", 98},      {"f3", 99},       {"f8", 100},      {"f9", 101},       {"f11", 103},
	    {"f13", 105},    {"f16", 106},     {"f14", 107},     {"f10", 109},      {"f12", 111},
	    {"f15", 113},    {"insert", 114},  {"home", 115},    {"pageup", 116},   {"delete", 117},
	    {"f4", 118},     {"end", 119},     {"f2", 120},      {"pagedown", 121}, {"f1", 122},
	    {"left", 123},   {"right", 124},   {"down", 125},    {"up", 126},
	};
	return table;
}

// skhd's modifier vocabulary plus the names end-4's Hyprland config uses.
const QHash<QString, quint32>& modifierBits() {
	static const QHash<QString, quint32> table = {
	    {"cmd", cmdKey},        {"lcmd", cmdKey},      {"rcmd", cmdKey},         {"command", cmdKey},
	    {"super", cmdKey},      {"meta", cmdKey},      {"win", cmdKey},
	    {"alt", optionKey},     {"lalt", optionKey},   {"ralt", optionKey},      {"opt", optionKey},
	    {"option", optionKey},  {"ctrl", controlKey},  {"lctrl", controlKey},    {"rctrl", controlKey},
	    {"control", controlKey}, {"shift", shiftKey},  {"lshift", shiftKey},     {"rshift", shiftKey},
	    {"hyper", cmdKey | optionKey | controlKey | shiftKey},
	    {"meh", optionKey | controlKey | shiftKey},
	};
	return table;
}

struct Chord {
	quint32 id = 0;
	bool modifierOnly = false;
	QString error;
};

Chord parseChord(const QString& text) {
	Chord chord;
	auto parts = text.trimmed().toLower().split('+', Qt::SkipEmptyParts);
	if (parts.isEmpty()) {
		chord.error = "empty chord";
		return chord;
	}

	quint32 modifiers = 0;
	for (auto i = 0; i < parts.size() - 1; ++i) {
		auto name = parts[i].trimmed();
		if (!modifierBits().contains(name)) {
			chord.error = QString("unknown modifier \"%1\"").arg(name);
			return chord;
		}
		modifiers |= modifierBits().value(name);
	}

	auto key = parts.last().trimmed();
	if (modifierBits().contains(key)) {
		chord.modifierOnly = true;
		return chord;
	}

	bool hexOk = false;
	auto keycode = key.startsWith("0x") ? key.mid(2).toUInt(&hexOk, 16) : keycodes().value(key, 0xFFFF);
	if (!hexOk && keycode == 0xFFFF) {
		chord.error = QString("unknown key \"%1\"").arg(key);
		return chord;
	}
	if (keycode > 0x7F) {
		chord.error = QString("keycode %1 out of range").arg(key);
		return chord;
	}

	chord.id = chordId(keycode, modifiers);
	return chord;
}

// Every chord skhdrc binds: `mods - key : command`, with an optional
// `mode <` prefix and `->` passthrough marker.
QSet<quint32> skhdChords() {
	QSet<quint32> chords;
	auto path = qEnvironmentVariable("SKHD_RC");
	if (path.isEmpty()) path = QDir::homePath() + "/.config/skhd/skhdrc";
	if (!QFile::exists(path)) path = QDir::homePath() + "/.skhdrc";

	QFile file(path);
	if (!file.open(QIODevice::ReadOnly | QIODevice::Text)) return chords;

	for (auto raw: QString::fromUtf8(file.readAll()).split('\n')) {
		auto line = raw.trimmed();
		if (line.isEmpty() || line.startsWith('#') || line.startsWith(':') || line.startsWith('.')) continue;
		auto colon = line.indexOf(':');
		if (colon < 0) continue;
		auto lhs = line.left(colon).section('<', -1).trimmed();
		lhs.remove("->");
		auto dash = lhs.lastIndexOf('-');
		auto mods = dash < 0 ? QString() : lhs.left(dash);
		auto key = (dash < 0 ? lhs : lhs.mid(dash + 1)).trimmed();
		auto chord = parseChord(mods.replace(' ', "") + (mods.isEmpty() ? "" : "+") + key);
		if (chord.error.isEmpty() && !chord.modifierOnly) chords.insert(chord.id);
	}
	return chords;
}

QString describeChord(quint32 id) {
	QStringList out;
	auto modifiers = chordModifiers(id);
	if (modifiers & controlKey) out << "ctrl";
	if (modifiers & optionKey) out << "alt";
	if (modifiers & cmdKey) out << "cmd";
	if (modifiers & shiftKey) out << "shift";
	auto keycode = chordKeycode(id);
	out << keycodes().key(keycode, QString("0x%1").arg(keycode, 2, 16, QChar('0')).toUpper());
	return out.join('+');
}

// One Carbon registration per chord for the whole process, shared by every
// engine's Hotkeys instance: a config reload creates the new engine's singleton
// while the old one is still alive, and a second RegisterEventHotKey for a chord
// this process already holds fails with eventHotKeyExistsErr.
struct Registration {
	EventHotKeyRef ref = nullptr;
	int refs = 0;
};

QHash<quint32, Registration>& registrations() {
	static QHash<quint32, Registration> table;
	return table;
}

QList<Hotkeys*>& instances() {
	static QList<Hotkeys*> list;
	return list;
}

OSStatus hotkeyEvent(EventHandlerCallRef, EventRef event, void*) {
	EventHotKeyID hotkey {};
	auto status = GetEventParameter(
	    event,
	    kEventParamDirectObject,
	    typeEventHotKeyID,
	    nullptr,
	    sizeof(hotkey),
	    nullptr,
	    &hotkey
	);
	if (status != noErr) return status;

	auto pressed = GetEventKind(event) == kEventHotKeyPressed;
	for (auto* instance: QList<Hotkeys*>(instances())) {
		instance->dispatch(hotkey.id, pressed);
	}
	return noErr;
}

void installHandler() {
	static EventHandlerRef handler = nullptr;
	if (handler != nullptr) return;
	const EventTypeSpec specs[] = {
	    {kEventClassKeyboard, kEventHotKeyPressed},
	    {kEventClassKeyboard, kEventHotKeyReleased},
	};
	InstallApplicationEventHandler(NewEventHandlerUPP(&hotkeyEvent), 2, specs, nullptr, &handler);
}

void acquire(quint32 id) {
	auto& reg = registrations()[id];
	if (reg.refs++ > 0) return;

	installHandler();
	EventHotKeyID hotkey = {'QSHK', id};
	auto status = RegisterEventHotKey(
	    chordKeycode(id),
	    chordModifiers(id),
	    hotkey,
	    GetApplicationEventTarget(),
	    0,
	    &reg.ref
	);
	if (status != noErr) {
		qWarning() << "Hotkeys: RegisterEventHotKey failed for" << describeChord(id) << "status" << status;
		reg.ref = nullptr;
	}
}

void release(quint32 id) {
	auto it = registrations().find(id);
	if (it == registrations().end() || --it->refs > 0) return;
	if (it->ref != nullptr) UnregisterEventHotKey(it->ref);
	registrations().erase(it);
}

} // namespace

Hotkeys::Hotkeys(QObject* parent): QObject(parent) {
	this->loadTable();
	instances().append(this);
}

Hotkeys::~Hotkeys() {
	instances().removeAll(this);
	for (const auto& bound: this->mBound) {
		for (auto id: bound.chords) release(id);
	}
}

void Hotkeys::loadTable() {
	QJsonObject table = QJsonDocument::fromJson(DEFAULT_SHORTCUTS_JSON).object();

	auto path = qEnvironmentVariable("QS_SHORTCUTS");
	if (path.isEmpty()) path = QDir::homePath() + "/.config/quickshell-macos/shortcuts.json";
	QFile file(path);
	if (file.open(QIODevice::ReadOnly)) {
		QJsonParseError error {};
		auto doc = QJsonDocument::fromJson(file.readAll(), &error);
		if (error.error != QJsonParseError::NoError) {
			qWarning() << "Hotkeys:" << path << "ignored:" << error.errorString();
		} else {
			auto user = doc.object();
			for (auto it = user.begin(); it != user.end(); ++it) {
				table[it.key().contains(':') ? it.key() : "quickshell:" + it.key()] = it.value();
			}
		}
	}

	auto skhd = skhdChords();

	for (auto it = table.begin(); it != table.end(); ++it) {
		auto key = it.key().contains(':') ? it.key() : "quickshell:" + it.key();
		QStringList texts;
		if (it.value().isString()) texts << it.value().toString();
		else if (it.value().isArray()) {
			for (auto value: it.value().toArray()) texts << value.toString();
		}

		QStringList kept;
		for (const auto& text: texts) {
			if (text.trimmed().isEmpty()) continue;
			auto chord = parseChord(text);
			if (!chord.error.isEmpty()) {
				qWarning() << "Hotkeys:" << key << text << "ignored:" << chord.error;
			} else if (chord.modifierOnly) {
				qWarning() << "Hotkeys:" << key << text
				           << "is a bare modifier; Carbon hot keys need a key, and holding a modifier"
				              " alone would need a CGEvent tap under Input Monitoring. Unbound.";
			} else if (skhd.contains(chord.id)) {
				qInfo() << "Hotkeys:" << key << text << "left to skhd, which binds it in skhdrc";
			} else {
				this->mChords[key].append(chord.id);
				kept << text.trimmed().toLower();
			}
		}

		if (kept.size() == 1) this->mBindings[key] = kept.first();
		else if (kept.size() > 1) this->mBindings[key] = kept;
	}
}

void Hotkeys::bind(const QString& appid, const QString& name) {
	auto key = appid + ":" + name;
	auto& bound = this->mBound[key];
	if (bound.refs++ > 0) return;

	bound.chords = this->mChords.value(key);
	for (auto id: bound.chords) {
		acquire(id);
		this->mListeners[id].append(key);
	}
}

void Hotkeys::unbind(const QString& appid, const QString& name) {
	auto key = appid + ":" + name;
	auto it = this->mBound.find(key);
	if (it == this->mBound.end() || --it->refs > 0) return;

	for (auto id: it->chords) {
		release(id);
		this->mListeners[id].removeAll(key);
	}
	this->mBound.erase(it);
}

QString Hotkeys::chord(const QString& appid, const QString& name) const {
	auto value = this->mBindings.value(appid + ":" + name);
	return value.typeId() == QMetaType::QStringList ? value.toStringList().join(", ") : value.toString();
}

void Hotkeys::dispatch(quint32 id, bool pressed) {
	for (const auto& key: QStringList(this->mListeners.value(id))) {
		auto colon = key.indexOf(':');
		auto appid = key.left(colon);
		auto name = key.mid(colon + 1);
		if (pressed) emit this->pressed(appid, name);
		else emit this->released(appid, name);
	}
}

} // namespace qs::cocoa
