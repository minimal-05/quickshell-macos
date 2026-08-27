#include <qguiapplication.h>
#include <qlist.h>
#include <qqml.h>
#include <qstring.h>

#include "../core/plugin.hpp"
#include "nswindow.hpp"
#include "panel_window.hpp"

namespace {

class CocoaPlugin: public QsEnginePlugin {
	QString name() override { return "cocoa"; }

	QList<QString> dependencies() override { return {"window"}; }

	bool applies() override { return QGuiApplication::platformName() == "cocoa"; }

	// Deliberately empty. Accessory activation policy is applied lazily, when
	// the first panel is registered — see registerPanel() in nswindow.mm.
	// Applying it here would hit every quickshell process, including ones whose
	// only window is an ordinary application window (the settings and welcome
	// configs). Those need to stay a regular app: with a Dock icon, a menu bar,
	// and their own Quit item, so closing them is unambiguous.
	void init() override {}

	void registerTypes() override {
		qmlRegisterType<qs::cocoa::CocoaPanelInterface>(
		    "Quickshell._CocoaOverlay",
		    1,
		    0,
		    "PanelWindow"
		);

		qmlRegisterModuleImport(
		    "Quickshell",
		    QQmlModuleImportModuleAny,
		    "Quickshell._CocoaOverlay",
		    QQmlModuleImportLatest
		);
	}
};

QS_REGISTER_PLUGIN(CocoaPlugin);

} // namespace
