pragma ComponentBehavior: Bound
import QtQuick
import qs.Commons

// The whole local day on one strip: midnight to midnight, lit between the
// day's two transitions, with a marker where you are in it. It replaces the
// three rows of times a schedule panel usually needs — the shape of the
// seasons is legible at a glance, and so is how long you have before the
// desktop changes.
Item {
  id: root

  property color foreground: Color.foreground
  property color accent: Color.accent
  property string fontFamily: Style.font.family

  // { dayStart, nightStart, now, wraps } as fractions of the day.
  property var ribbon: null
  property string dayText: ""
  property string nightText: ""
  property string appearance: "light"

  readonly property real dayStart: ribbon && ribbon.dayStart >= 0 ? ribbon.dayStart : 0.3
  readonly property real nightStart: ribbon && ribbon.nightStart >= 0 ? ribbon.nightStart : 0.8
  readonly property real nowFraction: ribbon && ribbon.now >= 0 ? ribbon.now : 0
  readonly property bool wraps: !!ribbon && ribbon.wraps === true

  readonly property real trackHeight: Style.space(30)

  implicitHeight: trackHeight + Style.space(4) + labels.implicitHeight

  Rectangle {
    id: track
    width: parent.width
    height: root.trackHeight
    radius: Style.cornerRadius > 0 ? Style.space(8) : 0
    color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.07)
    clip: true

    // One or two lit spans, depending on whether the day wraps past midnight.
    Repeater {
      model: root.wraps
        ? [{ from: 0, to: root.nightStart }, { from: root.dayStart, to: 1 }]
        : [{ from: root.dayStart, to: root.nightStart }]

      Rectangle {
        required property var modelData

        x: track.width * modelData.from
        width: Math.max(0, track.width * (modelData.to - modelData.from))
        height: track.height
        // Dawn and dusk are the softest thing in the panel: the band does not
        // begin and end, it arrives and leaves.
        gradient: Gradient {
          orientation: Gradient.Horizontal
          GradientStop { position: 0.0; color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.03) }
          GradientStop { position: 0.14; color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.20) }
          GradientStop { position: 0.86; color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.20) }
          GradientStop { position: 1.0; color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.03) }
        }

        Behavior on x { NumberAnimation { duration: 300; easing.type: Easing.OutCubic } }
        Behavior on width { NumberAnimation { duration: 300; easing.type: Easing.OutCubic } }
      }
    }

    // Noon, as the one fixed reference the eye can measure the band against.
    Rectangle {
      x: track.width / 2
      width: 1
      height: track.height
      color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.12)
    }

    Rectangle {
      id: marker
      x: Math.round(track.width * root.nowFraction) - width / 2
      width: Style.space(2)
      height: track.height
      radius: width / 2
      color: root.accent

      Behavior on x { NumberAnimation { duration: 600; easing.type: Easing.OutCubic } }
    }

    DarkyIcon {
      anchors.verticalCenter: parent.verticalCenter
      // Keeps the mark inside the strip at either end of the day.
      x: Math.max(Style.space(3), Math.min(track.width - width - Style.space(3),
                                           marker.x + marker.width / 2 - width / 2))
      iconSize: Style.space(14)
      color: root.accent
      phase: root.appearance === "light" ? 0 : 1

      Behavior on x { NumberAnimation { duration: 600; easing.type: Easing.OutCubic } }
    }
  }

  Item {
    id: labels
    anchors.top: track.bottom
    anchors.topMargin: Style.space(4)
    width: parent.width
    implicitHeight: dayLabel.implicitHeight

    Text {
      id: dayLabel
      x: Math.max(0, Math.min(root.width - implicitWidth, root.width * root.dayStart - implicitWidth / 2))
      text: root.dayText
      color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.6)
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
    }

    Text {
      x: Math.max(0, Math.min(root.width - implicitWidth, root.width * root.nightStart - implicitWidth / 2))
      text: root.nightText
      color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.6)
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
    }
  }
}
