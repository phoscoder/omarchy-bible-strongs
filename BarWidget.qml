import QtQuick
import Qt5Compat.GraphicalEffects
import Quickshell.Io
import qs.Commons
import qs.Ui

// Book glyph in the bar. Service.qml stays mounted with the bar so the
// day's verse is always derived. Click/IPC contract matches
// the Liturgy of the Hours widget.
BarWidget {
  id: root
  moduleName: "bible-strongs"

  Service {
    id: service
  }

  readonly property color barForeground: bar ? bar.barForeground : Color.foreground

  readonly property bool opened: panelLoader.item ? panelLoader.item.opened === true : false

  function open() {
    if (panelLoader.item) panelLoader.item.open()
  }

  function close() {
    if (panelLoader.item) panelLoader.item.close()
  }

  function togglePanel() {
    if (panelLoader.item) panelLoader.item.toggle()
  }

  function injectPanel() {
    var target = panelLoader.item
    if (!target) return
    if ("bar" in target) target.bar = root.bar
    if ("anchorItem" in target) target.anchorItem = button
    if ("hostWidget" in target) target.hostWidget = root
    if ("service" in target) target.service = service
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onBarChanged: injectPanel()

  Loader {
    id: panelLoader
    active: true
    source: Qt.resolvedUrl("Panel.qml")
    visible: false
    onLoaded: {
      root.injectPanel()
      Qt.callLater(root.injectPanel)
    }
  }

  IpcHandler {
    target: "bible"

    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function togglePanel(): void { root.togglePanel() }
    function status(): string {
      return service.todayReference !== "" ? service.todayReference : "Bible"
    }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    tooltipText: service.todayReference !== "" ? service.todayReference : "Bible"
    foreground: root.barForeground
    iconComponent: Component {
      ColorOverlay {
        anchors.fill: parent
        color: button.foreground
        source: Image {
          source: "assets/bible.svg"
          fillMode: Image.PreserveAspectFit
          sourceSize.width: Style.font.body
          sourceSize.height: Style.font.body
        }
      }
    }

    onPressed: function(b) {
      if (b === Qt.LeftButton) root.togglePanel()
    }
  }
}
