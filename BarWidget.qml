pragma ComponentBehavior: Bound
import QtQuick
import qs.Commons
import qs.Ui

BarWidget {
  id: root
  moduleName: "mehiel.darky"

  readonly property var service: bar && bar.shell && typeof bar.shell.serviceFor === "function"
    ? bar.shell.serviceFor("mehiel.darky") : null
  readonly property Item button: buttonItem
  readonly property bool opened: panelLoader.item ? panelLoader.item.opened === true : false
  readonly property bool popoutSwitchClosing: panelLoader.item ? panelLoader.item.popoutSwitchClosing === true : false

  readonly property color barTint: bar ? bar.barForeground : Color.foreground
  readonly property bool night: service ? service.appearance === "dark" : false
  // Paused fades the mark toward the bar rather than darkening it: on a light
  // theme a darker foreground reads as more prominent, not less. A temporary
  // choice sits between the two, because it is a schedule that is being
  // overruled rather than switched off.
  readonly property real iconFade: !service || !service.ready ? 0.45
    : service.mode === "paused" ? 0.5
    : service.overrideActive ? 0.75
    : 1.0

  readonly property string tooltip: {
    if (!service || !service.ready) return "Darky"
    return "Darky — " + service.statusText()
  }

  function injectPanel() {
    var target = panelLoader.item
    if (!target) return
    if ("hostWidget" in target) target.hostWidget = root
    if ("anchorItem" in target) target.anchorItem = buttonItem
    if ("bar" in target) target.bar = root.bar
    if ("settings" in target) target.settings = root.settings
    if ("service" in target) target.service = root.service
  }

  function toggle() { if (panelLoader.item) panelLoader.item.toggle() }
  function open() { if (panelLoader.item) panelLoader.item.open() }
  function close() { if (panelLoader.item) panelLoader.item.close() }
  function closeForPopoutSwitch() {
    if (panelLoader.item && panelLoader.item.closeForPopoutSwitch) panelLoader.item.closeForPopoutSwitch()
  }

  implicitWidth: buttonItem.implicitWidth
  implicitHeight: barSize

  onBarChanged: injectPanel()
  onSettingsChanged: injectPanel()
  onServiceChanged: injectPanel()

  BarIconButton {
    id: buttonItem
    anchors.fill: parent
    bar: root.bar
    foreground: root.barTint
    tooltipText: root.tooltip

    iconComponent: Component {
      Item {
        DarkyIcon {
          anchors.centerIn: parent
          iconSize: Style.space(15)
          color: root.barTint
          opacity: root.iconFade
          phase: root.night ? 1 : 0
        }
      }
    }

    // Middle click flips day and night without opening anything, which is the
    // same thing the Super+Alt+T bind does.
    onPressed: function (buttonCode) {
      if (buttonCode === Qt.MiddleButton && root.service) root.service.toggle()
      else root.toggle()
    }
  }

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
}
