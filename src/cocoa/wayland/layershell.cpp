#include "layershell.hpp"

#include <qobject.h>
#include <qstring.h>

#include "../nswindow.hpp"
#include "../panel_window.hpp"

namespace qs::cocoa {

// WlrLayer and PanelLayer document the same 0..3 numbering, so the layer is a
// cast; these pin the four values in case either enum is ever reordered.
static_assert(static_cast<quint8>(WlrLayer::Background) == static_cast<quint8>(PanelLayer::Desktop));
static_assert(static_cast<quint8>(WlrLayer::Bottom) == static_cast<quint8>(PanelLayer::Bottom));
static_assert(static_cast<quint8>(WlrLayer::Top) == static_cast<quint8>(PanelLayer::Top));
static_assert(static_cast<quint8>(WlrLayer::Overlay) == static_cast<quint8>(PanelLayer::Overlay));

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
		this->mPanel->setLayerOverride(static_cast<PanelLayer>(layer));
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
