#include "layershell.hpp"

#include <qobject.h>
#include <qstring.h>

#include "../nswindow.hpp"
#include "../panel_window.hpp"

namespace qs::cocoa {

namespace {

PanelLayer toPanelLayer(WlrLayer::Enum layer) {
	switch (layer) {
	case WlrLayer::Background: return PanelLayer::Desktop;
	case WlrLayer::Bottom: return PanelLayer::Bottom;
	case WlrLayer::Top: return PanelLayer::Top;
	case WlrLayer::Overlay: return PanelLayer::Overlay;
	}

	return PanelLayer::Top;
}

} // namespace

CocoaLayershell::CocoaLayershell(CocoaPanelWindow* panel, QObject* parent)
    : QObject(parent)
    , mPanel(panel) {}

CocoaLayershell* CocoaLayershell::qmlAttachedProperties(QObject* object) {
	if (auto* interface = qobject_cast<CocoaPanelInterface*>(object)) {
		return interface->layershell();
	}

	return nullptr;
}

void CocoaLayershell::setLayer(WlrLayer::Enum layer) {
	if (layer == this->mLayer) return;
	this->mLayer = layer;

	if (this->mPanel) {
		this->mPanel->setLayerOverride(toPanelLayer(layer));
	}

	emit this->layerChanged();
}

void CocoaLayershell::setNamespace(const QString& ns) {
	if (ns == this->mNamespace) return;
	this->mNamespace = ns;
	emit this->namespaceChanged();
}

void CocoaLayershell::setKeyboardFocus(WlrKeyboardFocus::Enum focus) {
	if (focus == this->mKeyboardFocus) return;
	this->mKeyboardFocus = focus;

	// The closest macOS equivalent is simply whether the panel may take key
	// status at all. Exclusive has no counterpart and is treated as OnDemand.
	if (this->mPanel) {
		this->mPanel->setFocusable(focus != WlrKeyboardFocus::None);
	}

	emit this->keyboardFocusChanged();
}

} // namespace qs::cocoa
