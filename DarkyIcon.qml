pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Shapes
import qs.Commons

// Sun and moon on one 128-unit grid, drawn as native shapes so the mark takes
// the theme colour directly and stays crisp in a bar slot. `phase` is 0 for
// full sun and 1 for full moon; animating it turns the switch into the one
// piece of motion Darky has.
Item {
  id: root

  property real iconSize: Style.font.icon
  property color color: Color.foreground
  property real phase: 0
  property bool animate: true

  readonly property real sunOpacity: 1 - Math.min(1, phase * 1.6)
  readonly property real moonOpacity: Math.max(0, (phase - 0.35) / 0.65)

  width: iconSize
  height: iconSize
  implicitWidth: iconSize
  implicitHeight: iconSize

  Behavior on phase {
    enabled: root.animate
    NumberAnimation { duration: 420; easing.type: Easing.InOutCubic }
  }

  Item {
    width: 128
    height: 128
    // The two marks pass through each other rather than cross-fading in place;
    // a quarter turn is enough to read as the sky moving.
    rotation: root.phase * 90
    transform: Scale {
      xScale: root.width / 128
      yScale: root.height / 128
    }

    Item {
      anchors.fill: parent
      opacity: root.sunOpacity
      visible: opacity > 0.01
      scale: 0.75 + 0.25 * root.sunOpacity

      Rectangle {
        x: 37
        y: 37
        width: 54
        height: 54
        radius: 27
        color: root.color
      }

      Repeater {
        model: 8

        Rectangle {
          id: ray
          required property int index

          x: 60
          y: 8
          width: 8
          height: 17
          radius: 4
          color: root.color
          transform: Rotation {
            origin.x: 4
            origin.y: 56
            angle: ray.index * 45
          }
        }
      }
    }

    Shape {
      anchors.fill: parent
      antialiasing: true
      // Curve rendering rasterises at device resolution. Layering would
      // rasterise on the 128-unit grid first and then scale the texture down,
      // which is what makes a small mark look soft beside the bar's glyphs.
      preferredRendererType: Shape.CurveRenderer
      opacity: root.moonOpacity
      visible: opacity > 0.01
      scale: 0.75 + 0.25 * root.moonOpacity

      // The crescent as its own outline: the long way round a disc of radius
      // 44 centred on the grid, then back along the disc of radius 42 centred
      // at (86,42) that bites into it. Subtracting one filled circle from
      // another with a fill rule does not work — even-odd keeps the part of
      // the biting circle that hangs outside, which draws a ring.
      ShapePath {
        fillColor: root.color
        strokeWidth: 0
        PathSvg { path: "M105.24,79.34 A44,44 0 1,1 48.66,22.76 A42,42 0 0,0 105.24,79.34 Z" }
      }
    }
  }
}
