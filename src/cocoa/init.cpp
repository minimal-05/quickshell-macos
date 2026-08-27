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

	void init() override { qs::cocoa::setAccessoryActivationPolicy(); }

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
