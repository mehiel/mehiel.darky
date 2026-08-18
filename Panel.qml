pragma ComponentBehavior: Bound
import QtQuick
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

// Darky's whole surface: what the desktop looks like now, when that changes,
// and which theme and wallpaper each half of the day gets.
Panel {
  id: root
  moduleName: "mehiel.darky"
  ipcTarget: "mehiel.darky.panel"
  manageIpc: false

  property var hostWidget: null
  property Item anchorItem: null
  property var service: null

  property string scheduleDraft: "solar"
  property var locationDraft: null
  property var suggestions: []
  property int suggestionIndex: 0
  property string pendingQuery: ""
  property string activeQuery: ""
  property string formError: ""

  readonly property var barIdentity: hostWidget || root
  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color accent: Color.accent
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color dim: Qt.rgba(foreground.r, foreground.g, foreground.b, 0.55)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  readonly property bool ready: !!service && service.ready === true
  readonly property string appearance: service ? service.appearance : ""
  readonly property string mode: service ? service.mode : "auto"
  readonly property bool solar: !!service && service.scheduleSource === "solar"
  // Which of Day and Night is showing as chosen, whether it was pinned or only
  // borrowed until the next transition.
  readonly property string chosen: {
    if (!service) return ""
    if (service.mode === "day") return "light"
    if (service.mode === "night") return "dark"
    return service.overrideActive ? service.overrideMode : ""
  }

  readonly property bool use24Hour: !/(AP|ap)/.test(Qt.locale().timeFormat(Locale.ShortFormat))

  readonly property var ribbon: service
    ? Model.dayRibbon({
        sunrise: service.sunrise,
        sunset: service.sunset,
        dayStart: service.config.dayStart,
        nightStart: service.config.nightStart
      }, tick.now)
    : null

  readonly property string dayText: solar && service && service.sunrise
    ? "\u2191 " + Model.clockLabel(service.sunrise, use24Hour)
    : (service ? service.config.dayStart : "07:00")

  readonly property string nightText: solar && service && service.sunset
    ? "\u2193 " + Model.clockLabel(service.sunset, use24Hour)
    : (service ? service.config.nightStart : "19:00")

  readonly property string nextText: {
    if (!service || !service.nextTransition) return "—"
    var event = service.nextEvent === "sunrise" ? "Sunrise"
      : service.nextEvent === "sunset" ? "Sunset"
      : service.nextEvent === "day" ? "Day" : "Night"
    return event + " " + Model.clockLabel(service.nextTransition, use24Hour)
      + " · " + Model.relativeLabel(service.nextTransition, tick.now)
  }

  readonly property string sourceText: {
    if (!service) return "—"
    if (service.scheduleSource === "solar") return "Sun over " + service.locationName
    if (service.scheduleSource === "fixed-fallback")
      return "Fixed times · the sun never sets there this week"
    return "Fixed times"
  }

  function switchPanel(direction) {
    if (bar && typeof bar.switchPanelFrom === "function") return bar.switchPanelFrom(barIdentity, direction)
    return false
  }

  function syncDrafts() {
    if (!service) return
    scheduleDraft = service.config.schedule
    locationDraft = service.config.location
    dayField.text = service.config.dayStart
    nightField.text = service.config.nightStart
    formError = ""
    suggestions = []
    cityField.text = ""
  }

  function chooseMode(value) {
    formError = ""
    if (service) service.setMode(value)
  }

  function chooseSchedule(kind) {
    scheduleDraft = kind
    formError = ""
    if (!service) return
    if (kind === "fixed") saveTimes()
    else if (locationDraft) service.setLocation(locationDraft)
    else formError = "Search for a city first"
  }

  function saveTimes() {
    if (!service || !service.setFixedTimes(dayField.text, nightField.text)) {
      formError = "Enter two different times as HH:MM"
      return
    }
    formError = ""
  }

  function selectCity(place) {
    var location = Model.normalizedLocation(place)
    if (!location || !service) return
    locationDraft = location
    suggestions = []
    cityField.text = ""
    pendingQuery = ""
    activeQuery = ""
    formError = ""
    service.setLocation(location)
  }

  function requestGeocode() {
    var query = cityField.text.trim()
    pendingQuery = query
    if (query.length < 2) {
      suggestions = []
      return
    }
    if (!geocode.running) startGeocode()
  }

  function startGeocode() {
    activeQuery = pendingQuery
    // One host, one protocol, no redirects, and a ceiling on both time and
    // bytes: a city search has no business going anywhere else or growing large.
    geocode.command = ["curl", "-fsS",
      "--proto", "=https", "--tlsv1.2", "--max-redirs", "0",
      "--max-filesize", "262144", "--max-time", "5",
      "https://geocoding-api.open-meteo.com/v1/search?name="
        + encodeURIComponent(activeQuery) + "&count=5&language=en&format=json"]
    geocode.running = true
  }

  onOpenedChanged: {
    if (!opened) return
    syncDrafts()
    Qt.callLater(function () {
      if (root.opened) keyCatcher.forceActiveFocus()
    })
  }

  Connections {
    target: root.service
    function onReadyChanged() { root.syncDrafts() }
  }

  // Drives the "in 3h 20m" line and the marker's creep along the ribbon.
  Timer {
    id: tick
    property var now: new Date()
    interval: 20000
    running: root.opened
    repeat: true
    triggeredOnStart: true
    onTriggered: now = new Date()
  }

  Timer {
    id: geocodeDebounce
    interval: 300
    onTriggered: root.requestGeocode()
  }

  Process {
    id: geocode
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var query = cityField.text.trim()
        if (root.activeQuery === query && query.length >= 2) {
          root.suggestions = Model.parseGeocoding(text)
          root.suggestionIndex = 0
        }
        if (root.pendingQuery.length >= 2 && root.pendingQuery !== root.activeQuery)
          Qt.callLater(root.startGeocode)
      }
    }
    onExited: function (exitCode) {
      if (exitCode !== 0 && root.pendingQuery.length >= 2)
        root.formError = "Could not reach the city search"
    }
  }

  // Namespaced under the plugin id like every first-party panel: the service
  // already answers to "mehiel.darky", so the window gets its own target rather
  // than squatting a bare word any other plugin could claim.
  IpcHandler {
    target: "mehiel.darky.panel"

    function open(): void { root.open() }
    function close(): void { root.close() }
    function toggle(): void { root.toggle() }
  }

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(420))
    contentHeight: panel.fittedContentHeight(content.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: dayField.activeFocus || nightField.activeFocus || cityField.activeFocus
      onCloseRequested: root.close()
      onTabRequested: function (direction) { root.switchPanel(direction) }
      onActivateRequested: if (root.service) root.service.toggle()

      Flickable {
        id: scroller
        anchors.fill: parent
        contentWidth: width
        contentHeight: content.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        interactive: contentHeight > height

        Column {
          id: content
          width: parent.width
          spacing: Style.space(12)

          PanelHero {
            width: parent.width
            title: "Darky"
            meta: root.service ? root.service.statusText() : "Starting"
            foreground: root.foreground
            fontFamily: root.fontFamily
            iconSize: Style.font.displayLarge
            iconComponent: Component {
              DarkyIcon {
                iconSize: Style.font.displayLarge
                color: root.foreground
                phase: root.appearance === "dark" ? 1 : 0
              }
            }
          }

          DayRibbon {
            width: parent.width
            foreground: root.foreground
            accent: root.accent
            fontFamily: root.fontFamily
            ribbon: root.ribbon
            dayText: root.dayText
            nightText: root.nightText
            appearance: root.appearance
          }

          Row {
            id: modeRow
            width: parent.width
            spacing: Style.space(5)
            readonly property real cellWidth: (width - spacing * 3) / 4

            ModeButton { label: "Auto"; value: "auto"; width: modeRow.cellWidth }
            ModeButton { label: "Day"; value: "day"; width: modeRow.cellWidth }
            ModeButton { label: "Night"; value: "night"; width: modeRow.cellWidth }
            ModeButton { label: "Paused"; value: "paused"; width: modeRow.cellWidth }
          }

          Row {
            id: durationRow
            width: parent.width
            spacing: Style.space(6)
            visible: root.chosen !== "" && root.service && root.service.nextTransition
            readonly property real cellWidth: (width - spacing) / 2

            Button {
              width: durationRow.cellWidth
              text: "Until further notice"
              fontSize: Style.font.bodySmall
              bordered: true
              foreground: root.foreground
              fontFamily: root.fontFamily
              active: root.mode === "day" || root.mode === "night"
              onClicked: root.chooseMode(root.chosen === "light" ? "day" : "night")
            }

            Button {
              width: durationRow.cellWidth
              text: "Until " + (root.service && root.service.nextEvent === "sunrise" ? "sunrise"
                : root.service && root.service.nextEvent === "sunset" ? "sunset" : "the next change")
              fontSize: Style.font.bodySmall
              bordered: true
              foreground: root.foreground
              fontFamily: root.fontFamily
              active: !!root.service && root.service.overrideActive
              onClicked: {
                if (!root.service) return
                // A borrowed choice only means anything against a schedule.
                if (root.service.mode !== "auto") root.service.setMode("auto")
                root.service.setTemporary(root.chosen)
              }
            }
          }

          InfoRow { label: "Schedule"; value: root.sourceText }
          InfoRow { label: "Next"; value: root.nextText }
          InfoRow {
            label: "Theme"
            value: root.service && root.service.currentTheme !== "" ? root.service.currentTheme : "—"
          }

          PanelSeparator { width: parent.width; foreground: root.foreground }

          PanelSectionHeader {
            text: "PAIR"
            foreground: root.foreground
            fontFamily: root.fontFamily
          }

          ThemeSlot {
            width: parent.width
            slot: "light"
            themes: root.service ? root.service.themes : []
            theme: root.service ? root.service.config.light.theme : ""
            background: root.service ? root.service.config.light.background : ""
            active: root.appearance === "light"
            foreground: root.foreground
            accent: root.accent
            fontFamily: root.fontFamily
            onThemePicked: function (slug) { if (root.service) root.service.setSlot("light", slug, null) }
            onBackgroundPicked: function (path) { if (root.service) root.service.setSlot("light", null, path) }
          }

          ThemeSlot {
            width: parent.width
            slot: "dark"
            themes: root.service ? root.service.themes : []
            theme: root.service ? root.service.config.dark.theme : ""
            background: root.service ? root.service.config.dark.background : ""
            active: root.appearance === "dark"
            foreground: root.foreground
            accent: root.accent
            fontFamily: root.fontFamily
            onThemePicked: function (slug) { if (root.service) root.service.setSlot("dark", slug, null) }
            onBackgroundPicked: function (path) { if (root.service) root.service.setSlot("dark", null, path) }
          }

          PanelSeparator { width: parent.width; foreground: root.foreground }

          PanelSectionHeader {
            text: "SCHEDULE"
            foreground: root.foreground
            fontFamily: root.fontFamily
          }

          Text {
            width: parent.width
            visible: root.mode !== "auto"
            text: "Used while the mode is Auto."
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.WordWrap
          }

          Row {
            id: scheduleRow
            width: parent.width
            spacing: Style.space(6)
            readonly property real cellWidth: (width - spacing) / 2

            Button {
              width: scheduleRow.cellWidth
              text: "Sunrise & sunset"
              fontSize: Style.font.bodySmall
              bordered: true
              foreground: root.foreground
              fontFamily: root.fontFamily
              active: root.scheduleDraft === "solar"
              onClicked: root.chooseSchedule("solar")
            }

            Button {
              width: scheduleRow.cellWidth
              text: "Fixed times"
              fontSize: Style.font.bodySmall
              bordered: true
              foreground: root.foreground
              fontFamily: root.fontFamily
              active: root.scheduleDraft === "fixed"
              onClicked: root.chooseSchedule("fixed")
            }
          }

          Column {
            width: parent.width
            spacing: Style.space(8)
            visible: root.scheduleDraft === "solar"

            Text {
              width: parent.width
              text: root.locationDraft
                ? root.locationDraft.name + " · "
                  + root.locationDraft.latitude.toFixed(2) + ", " + root.locationDraft.longitude.toFixed(2)
                : "Search for a city to follow its sunrise and sunset."
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              wrapMode: Text.WordWrap
            }

            TextField {
              id: cityField
              width: parent.width
              placeholderText: "Change city"
              foreground: root.foreground
              font.family: root.fontFamily
              onTextChanged: {
                root.pendingQuery = text.trim()
                if (root.pendingQuery.length < 2) root.suggestions = []
                geocodeDebounce.restart()
              }
              Keys.onDownPressed: root.suggestionIndex = Math.min(root.suggestions.length - 1, root.suggestionIndex + 1)
              Keys.onUpPressed: root.suggestionIndex = Math.max(0, root.suggestionIndex - 1)
              Keys.onReturnPressed: if (root.suggestions.length > 0) root.selectCity(root.suggestions[root.suggestionIndex])
              Keys.onEscapePressed: {
                text = ""
                root.suggestions = []
                keyCatcher.forceActiveFocus()
              }
            }

            Column {
              width: parent.width
              visible: root.suggestions.length > 0
              spacing: 0

              Repeater {
                model: root.suggestions

                Button {
                  required property var modelData
                  required property int index

                  width: parent.width
                  text: modelData.name
                  leftAlign: true
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                  hasCursor: index === root.suggestionIndex
                  onHovered: function (on) { if (on) root.suggestionIndex = index }
                  onClicked: root.selectCity(modelData)
                }
              }

              // Open-Meteo's terms ask for attribution wherever their data is
              // shown; the sun maths after this point is local.
              Text {
                width: parent.width
                topPadding: Style.space(4)
                text: "City search by <a href=\"https://open-meteo.com/\">Open-Meteo</a> · <a href=\"https://creativecommons.org/licenses/by/4.0/\">CC BY 4.0</a>"
                textFormat: Text.StyledText
                horizontalAlignment: Text.AlignHCenter
                color: root.dim
                linkColor: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                onLinkActivated: function (link) { Qt.openUrlExternally(link) }
              }
            }
          }

          Column {
            width: parent.width
            spacing: Style.space(8)
            visible: root.scheduleDraft === "fixed"

            Row {
              width: parent.width
              spacing: Style.space(8)

              TimeField { id: dayField; label: "DAY STARTS"; width: (parent.width - parent.spacing) / 2 }
              TimeField { id: nightField; label: "NIGHT STARTS"; width: (parent.width - parent.spacing) / 2 }
            }

            Button {
              width: parent.width
              text: "Save times"
              iconText: "✓"
              bordered: true
              foreground: root.foreground
              fontFamily: root.fontFamily
              onClicked: root.saveTimes()
            }
          }

          Text {
            width: parent.width
            visible: root.formError !== "" || (!!root.service && root.service.lastError !== "")
            text: root.formError !== "" ? root.formError : (root.service ? root.service.lastError : "")
            // An error line quotes paths and names Darky did not choose. Text
            // sniffs for markup unless told, and its rich-text engine fetches
            // remote images; this line says the quiet part out loud.
            textFormat: Text.PlainText
            color: root.urgent
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.WordWrap
          }

          PanelSeparator { width: parent.width; foreground: root.foreground }

          Item {
            width: parent.width
            height: footer.height

            Text {
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
              width: parent.width - footer.width - Style.space(8)
              text: "Drop-in scripts: ~/.config/omarchy/hooks/darky.d"
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              elide: Text.ElideRight
            }

            Row {
              id: footer
              anchors.right: parent.right
              spacing: Style.space(6)

              PanelActionButton {
                iconText: "󰑐"
                tooltipText: "Look for new themes and wallpapers"
                foreground: root.foreground
                fontFamily: root.fontFamily
                onClicked: if (root.service) root.service.rescan()
              }

              PanelActionButton {
                iconText: "󰸉"
                tooltipText: "Apply the current pair again"
                enabled: root.ready && !root.service.applying
                foreground: root.foreground
                fontFamily: root.fontFamily
                onClicked: if (root.service) root.service.reapply()
              }
            }
          }
        }
      }
    }
  }

  component ModeButton: Button {
    required property string label
    required property string value

    text: label
    fontSize: Style.font.bodySmall
    bordered: true
    focusable: true
    foreground: root.foreground
    fontFamily: root.fontFamily
    active: value === "day" ? root.chosen === "light"
      : value === "night" ? root.chosen === "dark"
      : root.mode === value && root.chosen === ""
    Keys.onEscapePressed: root.close()
    onClicked: root.chooseMode(value)
  }

  component InfoRow: Item {
    id: infoRow
    required property string label
    required property string value

    width: parent.width
    height: Math.max(rowLabel.implicitHeight, rowValue.implicitHeight)

    Text {
      id: rowLabel
      anchors.left: parent.left
      text: infoRow.label
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
    }

    Text {
      id: rowValue
      anchors.right: parent.right
      width: infoRow.width - rowLabel.implicitWidth - Style.space(12)
      text: infoRow.value
      color: root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
      horizontalAlignment: Text.AlignRight
      elide: Text.ElideLeft
    }
  }

  component TimeField: Column {
    id: timeField
    required property string label
    property alias text: input.text

    spacing: Style.spacing.labelGap

    Text {
      text: timeField.label
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      font.letterSpacing: 1
    }

    TextField {
      id: input
      width: parent.width
      placeholderText: "HH:MM"
      maximumLength: 5
      inputMethodHints: Qt.ImhDigitsOnly
      validator: RegularExpressionValidator { regularExpression: /(?:[01][0-9]|2[0-3]):[0-5][0-9]/ }
      foreground: root.foreground
      font.family: root.fontFamily
      Keys.onEscapePressed: root.close()
      Keys.onReturnPressed: root.saveTimes()
    }
  }
}
