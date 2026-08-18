pragma ComponentBehavior: Bound
import QtQuick
import qs.Commons
import qs.Ui
import "Model.js" as Model

// One half of the pair: the theme and wallpaper Darky puts on the desktop for
// day, or for night. Themes are shown as chips painted in their own colours
// rather than listed by name, because that is the thing being chosen.
Column {
  id: root

  property string slot: "light"
  property var themes: []
  property string theme: ""
  property string background: ""
  property bool active: false

  property color foreground: Color.foreground
  property color accent: Color.accent
  property string fontFamily: Style.font.family

  signal themePicked(string slug)
  signal backgroundPicked(string path)

  readonly property color dim: Qt.rgba(foreground.r, foreground.g, foreground.b, 0.55)
  readonly property var selected: Model.themeBySlug(themes, theme)
  // Themes whose own mode matches this slot come first; the rest stay
  // reachable, because nothing stops you wanting a dark theme by day.
  readonly property var ordered: Model.themesForMode(themes, slot)
    .concat(Model.themesForMode(themes, slot === "light" ? "dark" : "light"))
  readonly property var backgrounds: selected ? selected.backgrounds : []

  spacing: Style.space(8)

  Item {
    width: parent.width
    height: header.implicitHeight

    Row {
      id: header
      spacing: Style.space(8)

      DarkyIcon {
        anchors.verticalCenter: parent.verticalCenter
        iconSize: Style.font.body
        color: root.active ? root.accent : root.dim
        phase: root.slot === "light" ? 0 : 1
        animate: false
      }

      Text {
        anchors.verticalCenter: parent.verticalCenter
        text: root.slot === "light" ? "DAY" : "NIGHT"
        color: root.active ? root.foreground : root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        font.bold: true
        font.letterSpacing: 1.5
      }
    }

    Text {
      anchors.right: parent.right
      anchors.verticalCenter: header.verticalCenter
      width: parent.width - header.width - Style.space(12)
      text: root.selected ? root.selected.name : root.theme
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      horizontalAlignment: Text.AlignRight
      elide: Text.ElideLeft
    }
  }

  Flow {
    width: parent.width
    spacing: Style.space(5)

    Repeater {
      model: root.ordered

      Rectangle {
        id: chip
        required property var modelData

        readonly property bool current: modelData.slug === root.theme

        width: Style.space(26)
        height: Style.space(26)
        radius: Style.cornerRadius > 0 ? Style.space(7) : 0
        color: modelData.background
        border.width: chip.current ? Style.space(2) : 1
        // A light theme's chip is nearly the colour of the panel it sits on, so
        // the outline is doing the work of showing there is a chip there.
        border.color: chip.current
          ? root.accent
          : Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, chipHover.hovered ? 0.5 : 0.28)

        // The theme's accent, as the one detail that tells two dark greys apart.
        Rectangle {
          anchors.centerIn: parent
          width: Style.space(9)
          height: Style.space(9)
          radius: width / 2
          color: chip.modelData.accent
          opacity: chip.current ? 1 : 0.85
        }

        HoverHandler { id: chipHover }

        MouseArea {
          anchors.fill: parent
          onClicked: root.themePicked(chip.modelData.slug)
        }

        PanelToolTip {
          visible: chipHover.hovered
          text: chip.modelData.name
          fontFamily: root.fontFamily
        }

        Behavior on border.width { NumberAnimation { duration: 120 } }
      }
    }
  }

  Item {
    width: parent.width
    height: Style.space(46)
    visible: root.backgrounds.length > 0

    ListView {
      id: strip
      anchors.fill: parent
      orientation: ListView.Horizontal
      spacing: Style.space(5)
      clip: true
      interactive: contentWidth > width
      boundsBehavior: Flickable.StopAtBounds
      // A leading entry for "whatever the theme picks itself", which is what
      // Omarchy does when Darky stays out of the way.
      model: [""].concat(root.backgrounds)

      delegate: Rectangle {
        id: thumb
        required property var modelData

        readonly property bool current: String(modelData) === root.background

        width: Style.space(66)
        height: Style.space(44)
        radius: Style.cornerRadius > 0 ? Style.space(6) : 0
        color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.07)
        border.width: thumb.current ? Style.space(2) : 1
        border.color: thumb.current
          ? root.accent
          : Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, thumbHover.hovered ? 0.45 : 0.12)
        clip: true

        Image {
          anchors.fill: parent
          anchors.margins: thumb.border.width
          visible: String(thumb.modelData) !== ""
          source: String(thumb.modelData) !== "" ? "file://" + thumb.modelData : ""
          fillMode: Image.PreserveAspectCrop
          asynchronous: true
          cache: true
          // Wallpapers are several megapixels; decoding them at thumbnail size
          // keeps opening the panel from costing hundreds of megabytes.
          sourceSize.width: Style.space(132)
          sourceSize.height: Style.space(88)
        }

        Text {
          anchors.centerIn: parent
          visible: String(thumb.modelData) === ""
          text: "Auto"
          color: thumb.current ? root.accent : root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }

        HoverHandler { id: thumbHover }

        MouseArea {
          anchors.fill: parent
          onClicked: root.backgroundPicked(String(thumb.modelData))
        }

        Behavior on border.width { NumberAnimation { duration: 120 } }
      }
    }
  }
}
