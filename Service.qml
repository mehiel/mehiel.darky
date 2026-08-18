import QtQuick
import Quickshell
import Quickshell.Io
import "Model.js" as Model

// Owns the schedule and the apply path. Declared as a `service` so exactly one
// of these exists per shell: a bar widget is built per monitor, and a schedule
// per monitor would mean the theme being set two or three times at sunset.
//
// The rule this service lives by is that it acts on transitions only. It never
// polices the current theme, so picking something else from the theme switcher
// at noon stays picked until the sun next moves.
Item {
  id: root

  property var shell: null
  property var manifest: null

  property var config: Model.normalizeSettings(null)
  property var themes: []
  property string currentTheme: ""

  property string scheduledMode: ""
  property string scheduleSource: "fixed"
  property var nextTransition: null
  property string nextEvent: ""
  property var sunrise: null
  property var sunset: null

  property bool overrideActive: false
  property string overrideMode: ""
  property string overrideExpiresAt: ""

  property string appliedMode: ""
  property bool applying: false
  property string lastError: ""

  property bool settingsLoaded: false
  property bool overrideLoaded: false
  property bool modeLoaded: false
  property bool stateStarted: false
  property bool seeded: false

  readonly property bool ready: stateStarted && settingsLoaded && overrideLoaded && modeLoaded
  readonly property string mode: config.mode
  readonly property bool scheduleActive: config.mode === "auto"
  readonly property string effectiveMode: Model.effectiveMode(config.mode, scheduledMode, overrideActive ? overrideMode : "")
  // What the desktop shows, which is the effective mode unless Darky is paused
  // and therefore has no opinion.
  readonly property string appearance: effectiveMode !== "" ? effectiveMode : appliedMode

  // Same rule the scripts follow, so both halves agree about where state lives.
  readonly property string stateDir: (Quickshell.env("XDG_STATE_HOME")
    || Quickshell.env("HOME") + "/.local/state") + "/darky"
  readonly property string settingsPath: stateDir + "/settings.json"
  readonly property string overridePath: stateDir + "/override.json"
  readonly property string modePath: stateDir + "/mode"
  readonly property string themeNamePath: Quickshell.env("HOME") + "/.local/state/omarchy/current/theme.name"

  readonly property string locationName: config.location
    ? (config.location.name || config.location.latitude.toFixed(2) + ", " + config.location.longitude.toFixed(2))
    : ""

  signal applied(string mode)

  function scriptPath(name) {
    return String(Qt.resolvedUrl("bin/" + name)).replace(/^file:\/\//, "")
  }

  function slotFor(mode) {
    return mode === "light" ? config.light : config.dark
  }

  function themeFor(mode) {
    return Model.themeBySlug(themes, slotFor(mode).theme)
  }

  function statusObject() {
    return {
      mode: config.mode,
      appearance: appearance,
      scheduled: scheduledMode,
      source: scheduleSource,
      schedule: config.schedule,
      scheduleActive: scheduleActive,
      next: nextTransition ? nextTransition.toISOString() : "",
      nextEvent: nextEvent,
      sunrise: sunrise ? sunrise.toISOString() : "",
      sunset: sunset ? sunset.toISOString() : "",
      temporary: overrideActive,
      temporaryUntil: overrideExpiresAt,
      location: locationName,
      light: config.light,
      dark: config.dark,
      theme: currentTheme,
      ready: ready,
      lastError: lastError
    }
  }

  function statusText() {
    if (!ready) return "Starting"
    if (config.mode === "paused") return "Paused · " + (appearance === "light" ? "Day" : "Night")
    if (config.mode === "day") return "Day, held"
    if (config.mode === "night") return "Night, held"
    if (overrideActive) return (overrideMode === "light" ? "Day" : "Night") + " until "
      + (nextEvent === "sunrise" ? "sunrise" : nextEvent === "sunset" ? "sunset" : "the next change")
    return (scheduledMode === "light" ? "Day" : "Night") + " by "
      + (scheduleSource === "solar" ? "the sun" : "the clock")
  }

  // ------------------------------------------------------------- evaluation

  function evaluate() {
    if (!ready) return

    var now = new Date()
    var state = Model.scheduleState(config, now)
    scheduledMode = state.mode
    scheduleSource = state.source
    nextTransition = state.next
    nextEvent = state.nextEvent
    sunrise = state.sunrise
    sunset = state.sunset

    if (config.mode !== "auto" && overrideActive) clearOverride(false)
    if (overrideActive && Model.overrideExpired(overrideExpiresAt, now)) clearOverride(false)

    armTimer()

    // Read from the model rather than the bound property: the assignments
    // above are what this decision depends on.
    var desired = Model.effectiveMode(config.mode, state.mode, overrideActive ? overrideMode : "")
    if (desired !== "" && desired !== appliedMode) apply(desired)
  }

  function armTimer() {
    transitionTimer.stop()
    var delay = Model.transitionDelay(nextTransition, new Date())
    if (delay <= 0) return
    transitionTimer.interval = delay
    transitionTimer.start()
  }

  // ------------------------------------------------------------------ apply

  function apply(mode) {
    if (mode !== "light" && mode !== "dark") return
    if (applying) {
      applyQueue.mode = mode
      return
    }
    var slot = slotFor(mode)
    applying = true
    lastError = ""
    applyProcess.mode = mode
    applyProcess.command = [scriptPath("darky-apply"), mode, slot.theme, slot.background]
    applyProcess.running = true
  }

  function reapply() {
    if (appearance !== "") apply(appearance)
  }

  function onApplyFinished(exitCode, mode) {
    applying = false
    if (exitCode === 0) {
      appliedMode = mode
      applied(mode)
    } else if (lastError === "") {
      lastError = "Could not switch to " + (mode === "light" ? "day" : "night")
    }
    if (applyQueue.mode !== "") {
      var queued = applyQueue.mode
      applyQueue.mode = ""
      Qt.callLater(function () { root.apply(queued) })
    }
  }

  // ---------------------------------------------------------------- actions

  function setMode(value) {
    if (!ready || !Model.validMode(value)) return false
    if (value === config.mode) {
      // Choosing Auto while a temporary choice is in force is how you cancel it.
      if (value === "auto" && overrideActive) clearOverride(true)
      return true
    }
    if (value !== "auto") clearOverride(false)
    return updateSettings({ mode: value })
  }

  // A choice that lasts until the schedule next disagrees. Outside Auto there
  // is nothing to expire against, so the same request becomes a held pin.
  function setTemporary(value) {
    if (!ready || (value !== "light" && value !== "dark")) return ""
    if (config.mode === "day" || config.mode === "night") {
      setMode(value === "light" ? "day" : "night")
      return value
    }
    if (config.mode === "paused") {
      apply(value)
      return value
    }
    if (value === scheduledMode) {
      clearOverride(true)
      return value
    }
    overrideActive = true
    overrideMode = value
    overrideExpiresAt = nextTransition ? nextTransition.toISOString() : ""
    overrideFile.setText(JSON.stringify({ mode: value, expiresAt: overrideExpiresAt }, null, 2) + "\n")
    apply(value)
    return value
  }

  function toggle() {
    if (!ready) return ""
    return setTemporary(appearance === "light" ? "dark" : "light")
  }

  function clearOverride(applyNow) {
    var had = overrideActive
    overrideActive = false
    overrideMode = ""
    overrideExpiresAt = ""
    if (had) overrideFile.setText("{}\n")
    if (applyNow !== false) evaluate()
  }

  function setSlot(mode, theme, background) {
    if (!ready || (mode !== "light" && mode !== "dark")) return false
    var next = {}
    next[mode] = {
      theme: theme === undefined || theme === null ? slotFor(mode).theme : theme,
      background: background === undefined || background === null ? slotFor(mode).background : background
    }
    return updateSettings(next)
  }

  function setSchedule(kind) {
    if (kind !== "solar" && kind !== "fixed") return false
    return updateSettings({ schedule: kind })
  }

  function setFixedTimes(dayStart, nightStart) {
    if (!Model.validTime(dayStart) || !Model.validTime(nightStart) || dayStart === nightStart) return false
    return updateSettings({ schedule: "fixed", dayStart: dayStart, nightStart: nightStart })
  }

  function setLocation(place) {
    var location = Model.normalizedLocation(place)
    if (!location) return false
    return updateSettings({ schedule: "solar", location: location })
  }

  // A patch over the loaded settings, normalized and written once. Everything
  // that changes configuration goes through here so the file, the in-memory
  // copy and the schedule can never drift apart.
  function updateSettings(patch) {
    if (!ready) return false
    var next = {}
    var keys = ["mode", "schedule", "dayStart", "nightStart", "location", "light", "dark"]
    for (var i = 0; i < keys.length; i++) next[keys[i]] = config[keys[i]]
    for (var key in patch) next[key] = patch[key]

    var normalized = Model.normalizeSettings(next)
    var text = Model.serializeSettings(normalized)
    if (text === _lastWritten) return true

    var previous = config
    var slotsChanged = Model.pairChanged(previous, normalized)
    config = normalized
    _lastWritten = text
    settingsFile.setText(text)

    if (Model.scheduleChanged(previous, normalized) && normalized.mode === "auto") clearOverride(false)
    evaluate()
    if (slotsChanged) repaint(previous, normalized)
    return true
  }

  // A slot that was repainted should show up now if it is the one on screen,
  // rather than waiting for the next sunrise.
  function repaint(previous, next) {
    if (appearance === "" || applying) return
    var now = appearance === "light" ? next.light : next.dark
    var was = appearance === "light" ? previous.light : previous.dark
    if (now.theme !== was.theme || now.background !== was.background) apply(appearance)
  }

  property string _lastWritten: ""

  // ------------------------------------------------------------------ files

  function loadSettings(raw) {
    if (!stateStarted) return
    var text = String(raw || "")
    var loaded = Model.parseSettings(text)
    var first = !settingsLoaded
    var previous = config
    // Our own write coming back through the watcher, byte for byte. Anything
    // else is someone editing the file, and deserves the same live repaint the
    // panel gets.
    var echo = text === _lastWritten

    // Nothing saved yet: take the pair and the location out of the darkman
    // setup being replaced, so the very first evaluation matches the last one
    // darkman made rather than reverting to stock defaults.
    if (first && text.replace(/\s+/g, "") === "" && _seed) {
      loaded = Model.normalizeSettings({
        mode: loaded.mode,
        schedule: _seed.location ? "solar" : "fixed",
        location: _seed.location,
        light: _seed.light,
        dark: _seed.dark
      })
      seeded = true
    }

    config = loaded
    _lastWritten = Model.serializeSettings(loaded)
    settingsLoaded = true
    if (text !== _lastWritten) settingsFile.setText(_lastWritten)
    evaluate()
    if (!first && !echo) repaint(previous, loaded)
  }

  function loadOverride(raw) {
    if (!stateStarted) return
    var saved = Model.parseOverride(raw)
    overrideActive = !!saved
    overrideMode = saved ? saved.mode : ""
    overrideExpiresAt = saved ? saved.expiresAt : ""
    overrideLoaded = true
    evaluate()
  }

  property var _seed: null

  function loadScan(raw) {
    var scan = Model.parseThemeScan(raw)
    themes = scan.themes
    if (scan.current !== "") currentTheme = scan.current
    if (scan.seed) _seed = scan.seed
    // The scan carries the seed, so settings cannot be read before it lands.
    if (!stateStarted) {
      stateStarted = true
      settingsFile.reload()
      overrideFile.reload()
    }
  }

  function rescan() { scanProcess.running = true }

  FileView {
    id: settingsFile
    path: root.settingsPath
    watchChanges: true
    atomicWrites: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: root.loadSettings(text())
    onLoadFailed: root.loadSettings("")
    onSaveFailed: root.lastError = "Could not save Darky settings"
  }

  FileView {
    id: overrideFile
    path: root.overridePath
    atomicWrites: true
    printErrors: false
    onLoaded: root.loadOverride(text())
    onLoadFailed: root.loadOverride("")
    onSaveFailed: root.lastError = "Could not save the temporary choice"
  }

  // Darky is not the only thing that changes the theme, and the panel should
  // not claim otherwise.
  FileView {
    id: themeNameFile
    path: root.themeNamePath
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: root.currentTheme = Model.slug(text())
  }

  // The last mode Darky actually applied, which is what tells a fresh shell
  // whether it slept through a transition and owes the desktop a catch-up.
  FileView {
    id: modeFile
    path: root.modePath
    printErrors: false
    onLoaded: {
      root.appliedMode = String(text() || "").trim()
      root.modeLoaded = true
      root.evaluate()
    }
    onLoadFailed: {
      root.appliedMode = ""
      root.modeLoaded = true
      root.evaluate()
    }
  }

  Process {
    id: ensureDir
    command: ["install", "-d", "-m", "0700", root.stateDir]
    onExited: function (exitCode) {
      if (exitCode !== 0) root.lastError = "Could not create " + root.stateDir
      modeFile.reload()
      themeNameFile.reload()
      scanProcess.running = true
    }
  }

  Process {
    id: scanProcess
    command: [root.scriptPath("darky-scan")]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.loadScan(text)
    }
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: if (String(text || "").trim() !== "") console.warn("darky: scan: " + text)
    }
    onExited: function (exitCode) {
      // A scan that never lands would leave the settings unread forever.
      if (exitCode !== 0 && !root.stateStarted) root.loadScan("")
    }
  }

  Process {
    id: applyProcess
    property string mode: ""
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var message = String(text || "").trim()
        if (message === "") return
        console.warn("darky: " + message)
        root.lastError = message.split("\n")[0]
      }
    }
    onExited: function (exitCode) { root.onApplyFinished(exitCode, applyProcess.mode) }
  }

  QtObject {
    id: applyQueue
    property string mode: ""
  }

  Timer {
    id: transitionTimer
    repeat: false
    onTriggered: root.evaluate()
  }

  // The transition timer is the precise one; this is the safety net that
  // catches a resume from suspend, a clock correction, or an expired override.
  Timer {
    interval: 60000
    running: true
    repeat: true
    onTriggered: root.evaluate()
  }

  // Themes and their backgrounds change when packages update, not by the
  // minute, so the panel gets a fresh catalogue after each theme change and
  // otherwise leaves the disk alone.
  Timer {
    id: rescanDebounce
    interval: 1500
    repeat: false
    onTriggered: root.rescan()
  }

  onCurrentThemeChanged: if (root.stateStarted) rescanDebounce.restart()

  Component.onCompleted: ensureDir.running = true

  IpcHandler {
    target: "mehiel.darky"

    function status(): string { return JSON.stringify(root.statusObject()) }
    function toggle(): string { return root.ready ? root.toggle() : "not ready" }
    function light(): string { return root.ready ? root.setTemporary("light") : "not ready" }
    function dark(): string { return root.ready ? root.setTemporary("dark") : "not ready" }
    function auto(): string {
      if (!root.ready) return "not ready"
      if (root.config.mode !== "auto") root.setMode("auto")
      else root.clearOverride(true)
      return root.scheduledMode
    }
    function modeAuto(): string { root.setMode("auto"); return root.config.mode }
    function modeDay(): string { root.setMode("day"); return root.config.mode }
    function modeNight(): string { root.setMode("night"); return root.config.mode }
    function modePaused(): string { root.setMode("paused"); return root.config.mode }
    function apply(): string {
      if (!root.ready) return "not ready"
      root.reapply()
      return root.appearance
    }
    function refresh(): string { root.rescan(); return "ok" }
  }
}
