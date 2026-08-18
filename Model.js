// Pure logic for Darky: solar times, schedule resolution, settings shape.
// Everything here runs under both QML's JS engine and node, so tests/model.test.js
// can exercise the parts that decide when the desktop changes appearance.

var DAY_MS = 86400000
var J2000 = 2451545.0
var OBLIQUITY = 23.4397
// Standard sunrise/sunset: the sun's upper limb at the horizon, refracted.
// This is the altitude darkman transitions on, so cutting over keeps the same
// moment.
var SUN_ALTITUDE = -0.833
// How many city suggestions the panel will ever show, and therefore how many
// the parser will ever hand it.
var GEOCODING_LIMIT = 5

var DEFAULTS = {
  mode: "auto",
  schedule: "solar",
  dayStart: "07:00",
  nightStart: "19:00",
  location: null,
  light: { theme: "white", background: "" },
  dark: { theme: "tokyo-night", background: "" }
}

function trim(value) {
  return String(value === undefined || value === null ? "" : value).replace(/^\s+|\s+$/g, "")
}

// Text from a theme directory or a geocoding response ends up in QML Text,
// which sniffs for markup unless told otherwise and will happily fetch a
// remote <img src>. Dropping the one character that starts a tag is enough to
// keep every label plain, wherever it is rendered.
function label(value) {
  return trim(value).replace(/</g, "")
}

// Theme slugs become directory names and land in light-dark.conf, which other
// scripts read with `source`. Anything outside the charset Omarchy's own theme
// directories use is dropped rather than escaped, and a slug that is nothing
// but dots is thrown away so ".." can never address a parent directory.
function slug(value) {
  var cleaned = trim(value).toLowerCase()
    .replace(/\s+/g, "-")
    .replace(/[^a-z0-9._-]/g, "")
    .replace(/\.{2,}/g, ".")
    .replace(/^[.\-]+/, "")
  return /[a-z0-9]/.test(cleaned) ? cleaned : ""
}

function pad2(value) {
  return value < 10 ? "0" + value : String(value)
}

function radians(degrees) { return degrees * Math.PI / 180 }
function degrees(radiansValue) { return radiansValue * 180 / Math.PI }

function sameLocalDate(first, second) {
  return first.getFullYear() === second.getFullYear()
    && first.getMonth() === second.getMonth()
    && first.getDate() === second.getDate()
}

// ------------------------------------------------------------------- solar

// NOAA's solar position algorithm, evaluated at noon UTC of the given day.
// The shorter "sunrise equation" doing the same job lands about two minutes
// away from what darkman scheduled, which would be a visible change of
// behaviour on cutover; this agrees with darkman's log to a few seconds.
function solarDay(latitude, longitude, dayNumber) {
  var julian = dayNumber + 2440588.0
  var century = (julian - J2000) / 36525

  var meanLongitude = (280.46646 + century * (36000.76983 + century * 0.0003032)) % 360
  var meanAnomaly = 357.52911 + century * (35999.05029 - 0.0001537 * century)
  var eccentricity = 0.016708634 - century * (0.000042037 + 0.0000001267 * century)
  var center = Math.sin(radians(meanAnomaly)) * (1.914602 - century * (0.004817 + 0.000014 * century))
    + Math.sin(radians(2 * meanAnomaly)) * (0.019993 - 0.000101 * century)
    + Math.sin(radians(3 * meanAnomaly)) * 0.000289
  var node = 125.04 - 1934.136 * century
  var apparentLongitude = meanLongitude + center - 0.00569 - 0.00478 * Math.sin(radians(node))
  var meanObliquity = OBLIQUITY - (46.815 + century * (0.00059 - century * 0.001813)) * century / 3600
  var obliquity = meanObliquity + 0.00256 * Math.cos(radians(node))

  var declination = Math.asin(Math.sin(radians(obliquity)) * Math.sin(radians(apparentLongitude)))

  // Equation of time, in minutes: the gap between clock noon and solar noon.
  var y = Math.tan(radians(obliquity / 2)) * Math.tan(radians(obliquity / 2))
  var equationOfTime = 4 * degrees(
    y * Math.sin(2 * radians(meanLongitude))
    - 2 * eccentricity * Math.sin(radians(meanAnomaly))
    + 4 * eccentricity * y * Math.sin(radians(meanAnomaly)) * Math.cos(2 * radians(meanLongitude))
    - 0.5 * y * y * Math.sin(4 * radians(meanLongitude))
    - 1.25 * eccentricity * eccentricity * Math.sin(2 * radians(meanAnomaly)))

  var latitudeRad = radians(Number(latitude))
  var transitMinutes = 720 - 4 * Number(longitude) - equationOfTime
  var dayStart = dayNumber * DAY_MS
  var transit = new Date(Math.round(dayStart + transitMinutes * 60000))

  var cosHourAngle = (Math.sin(radians(SUN_ALTITUDE)) - Math.sin(latitudeRad) * Math.sin(declination))
    / (Math.cos(latitudeRad) * Math.cos(declination))
  if (cosHourAngle > 1)
    return { transit: transit, sunrise: null, sunset: null, polar: "night" }
  if (cosHourAngle < -1)
    return { transit: transit, sunrise: null, sunset: null, polar: "day" }

  var hourAngle = degrees(Math.acos(cosHourAngle))
  return {
    transit: transit,
    sunrise: new Date(Math.round(dayStart + (transitMinutes - 4 * hourAngle) * 60000)),
    sunset: new Date(Math.round(dayStart + (transitMinutes + 4 * hourAngle) * 60000)),
    polar: ""
  }
}

// Whole days since the epoch. Solar days are addressed in UTC and the caller
// looks at a window of them, so a location whose local day is offset from UTC
// still finds every event it needs.
function currentCycle(longitude, now) {
  var date = now instanceof Date ? now : new Date(now)
  return Math.floor(date.getTime() / DAY_MS)
}

// A window of solar days around `now`. One day back and two forward is enough
// to answer "which side of the horizon are we on" and "when does that change"
// without any date arithmetic at the call site.
function solarWindow(latitude, longitude, now, forwardDays) {
  var span = forwardDays === undefined ? 2 : forwardDays
  var base = currentCycle(longitude, now)
  var days = []
  for (var offset = -1; offset <= span; offset++)
    days.push(solarDay(latitude, longitude, base + offset))
  return days
}

function validCoordinate(value) {
  if (value === null || value === undefined || typeof value === "boolean") return false
  if (typeof value === "string" && trim(value) === "") return false
  return isFinite(Number(value))
}

function validCoordinates(latitude, longitude) {
  if (!validCoordinate(latitude) || !validCoordinate(longitude)) return false
  var lat = Number(latitude)
  var lng = Number(longitude)
  return lat >= -90 && lat <= 90 && lng >= -180 && lng <= 180
}

function normalizedLocation(value) {
  if (!value || !validCoordinates(value.latitude, value.longitude)) return null
  return {
    name: trim(value.name),
    latitude: Number(value.latitude),
    longitude: Number(value.longitude),
    timezone: trim(value.timezone)
  }
}

function sameLocation(first, second) {
  var a = normalizedLocation(first)
  var b = normalizedLocation(second)
  return !!a && !!b
    && Math.abs(a.latitude - b.latitude) < 0.000001
    && Math.abs(a.longitude - b.longitude) < 0.000001
}

// ---------------------------------------------------------------- settings

function validTime(value) {
  return /^(?:[01][0-9]|2[0-3]):[0-5][0-9]$/.test(trim(value))
}

function timeToMinutes(value) {
  if (!validTime(value)) return null
  var parts = trim(value).split(":")
  return Number(parts[0]) * 60 + Number(parts[1])
}

function validMode(value) {
  return value === "auto" || value === "day" || value === "night" || value === "paused"
}

function normalizedSlot(value, fallback) {
  var data = value && typeof value === "object" ? value : {}
  var theme = slug(data.theme)
  return {
    theme: theme !== "" ? theme : fallback.theme,
    background: trim(data.background)
  }
}

function normalizeSettings(value) {
  var data = value && typeof value === "object" ? value : {}
  var schedule = data.schedule === "fixed" ? "fixed" : "solar"
  var dayStart = validTime(data.dayStart) ? trim(data.dayStart) : DEFAULTS.dayStart
  var nightStart = validTime(data.nightStart) ? trim(data.nightStart) : DEFAULTS.nightStart
  if (dayStart === nightStart) {
    dayStart = DEFAULTS.dayStart
    nightStart = DEFAULTS.nightStart
  }
  var location = normalizedLocation(data.location)
  // Solar without a place to stand is just the fixed times under another name;
  // say so rather than pretending to follow the sun.
  if (schedule === "solar" && !location) schedule = "fixed"
  return {
    mode: validMode(data.mode) ? data.mode : DEFAULTS.mode,
    schedule: schedule,
    dayStart: dayStart,
    nightStart: nightStart,
    location: location,
    light: normalizedSlot(data.light, DEFAULTS.light),
    dark: normalizedSlot(data.dark, DEFAULTS.dark)
  }
}

function parseSettings(raw) {
  try {
    return normalizeSettings(JSON.parse(String(raw || "{}")))
  } catch (error) {
    return normalizeSettings(null)
  }
}

function serializeSettings(settings) {
  return JSON.stringify(normalizeSettings(settings), null, 2) + "\n"
}

function scheduleChanged(first, second) {
  var a = normalizeSettings(first)
  var b = normalizeSettings(second)
  return a.schedule !== b.schedule
    || a.dayStart !== b.dayStart
    || a.nightStart !== b.nightStart
    || !((!a.location && !b.location) || (sameLocation(a.location, b.location) && a.location.name === b.location.name))
}

function pairChanged(first, second) {
  var a = normalizeSettings(first)
  var b = normalizeSettings(second)
  return a.light.theme !== b.light.theme
    || a.dark.theme !== b.dark.theme
    || a.light.background !== b.light.background
    || a.dark.background !== b.dark.background
}

// ---------------------------------------------------------------- schedule

function fixedState(now, dayStart, nightStart) {
  var date = now instanceof Date ? now : new Date(now)
  var dayMinutes = timeToMinutes(dayStart)
  var nightMinutes = timeToMinutes(nightStart)
  if (dayMinutes === null) dayMinutes = timeToMinutes(DEFAULTS.dayStart)
  if (nightMinutes === null) nightMinutes = timeToMinutes(DEFAULTS.nightStart)
  if (dayMinutes === nightMinutes) {
    dayMinutes = timeToMinutes(DEFAULTS.dayStart)
    nightMinutes = timeToMinutes(DEFAULTS.nightStart)
  }

  var minute = date.getHours() * 60 + date.getMinutes()
  var light = dayMinutes < nightMinutes
    ? minute >= dayMinutes && minute < nightMinutes
    : minute >= dayMinutes || minute < nightMinutes

  function at(minutes) {
    var when = new Date(date.getTime())
    when.setHours(Math.floor(minutes / 60), minutes % 60, 0, 0)
    if (when.getTime() <= date.getTime()) when.setDate(when.getDate() + 1)
    return when
  }

  var next = at(light ? nightMinutes : dayMinutes)
  return {
    mode: light ? "light" : "dark",
    source: "fixed",
    next: next,
    nextEvent: light ? "night" : "day",
    sunrise: null,
    sunset: null
  }
}

function solarState(now, location) {
  var place = normalizedLocation(location)
  if (!place) return null
  var date = now instanceof Date ? now : new Date(now)
  var nowMs = date.getTime()
  var days = solarWindow(place.latitude, place.longitude, date)

  var events = []
  var polarOnly = true
  // Today's pair in the machine's own calendar, so the panel's ribbon lines up
  // with the day the user is living in rather than with UTC.
  var todaySunrise = null
  var todaySunset = null
  for (var i = 0; i < days.length; i++) {
    if (days[i].polar === "") polarOnly = false
    if (days[i].sunrise) {
      events.push({ at: days[i].sunrise, mode: "light", kind: "sunrise" })
      if (sameLocalDate(days[i].sunrise, date)) todaySunrise = days[i].sunrise
    }
    if (days[i].sunset) {
      events.push({ at: days[i].sunset, mode: "dark", kind: "sunset" })
      if (sameLocalDate(days[i].sunset, date)) todaySunset = days[i].sunset
    }
  }
  if (polarOnly || events.length === 0) return null

  events.sort(function (a, b) { return a.at.getTime() - b.at.getTime() })

  var current = null
  var next = null
  for (var e = 0; e < events.length; e++) {
    if (events[e].at.getTime() <= nowMs) current = events[e]
    else if (!next) next = events[e]
  }
  if (!current || !next) return null

  return {
    mode: current.mode,
    source: "solar",
    next: next.at,
    nextEvent: next.kind,
    sunrise: todaySunrise,
    sunset: todaySunset
  }
}

// The schedule's own opinion, before any manual pin or override.
function scheduleState(settings, now) {
  var config = normalizeSettings(settings)
  if (config.schedule === "solar") {
    var solar = solarState(now, config.location)
    if (solar) return solar
  }
  var fallback = fixedState(now, config.dayStart, config.nightStart)
  // A solar schedule that could not be computed is still a solar schedule; the
  // panel needs to say the times on screen are not the sun's.
  fallback.source = config.schedule === "solar" ? "fixed-fallback" : "fixed"
  return fallback
}

function parseOverride(raw) {
  try {
    var data = JSON.parse(String(raw || "{}"))
    if (data.mode !== "light" && data.mode !== "dark") return null
    var expires = new Date(data.expiresAt)
    if (isNaN(expires.getTime())) return null
    return { mode: data.mode, expiresAt: expires.toISOString() }
  } catch (error) {
    return null
  }
}

function overrideExpired(expiresAt, now) {
  var expires = new Date(expiresAt)
  var date = now instanceof Date ? now : new Date(now)
  return isNaN(expires.getTime()) || date.getTime() >= expires.getTime()
}

// What the desktop should look like right now. "" means Darky is paused and
// has no opinion at all.
function effectiveMode(mode, scheduled, overrideMode) {
  if (mode === "day") return "light"
  if (mode === "night") return "dark"
  if (mode === "paused") return ""
  return overrideMode === "light" || overrideMode === "dark" ? overrideMode : scheduled
}

function transitionDelay(next, now) {
  var when = next instanceof Date ? next : new Date(next)
  var date = now instanceof Date ? now : new Date(now)
  if (isNaN(when.getTime())) return -1
  // Qt timers take a 32-bit millisecond interval; a polar-summer "next" can
  // exceed it, and re-arming early is harmless.
  return Math.max(1000, Math.min(2147483647, when.getTime() - date.getTime()))
}

// ------------------------------------------------------------------ ribbon

// Positions on a midnight-to-midnight strip, as fractions of the local day.
// Returned even without solar data so the strip can show the fixed times.
function dayRibbon(state, now) {
  var date = now instanceof Date ? now : new Date(now)
  var midnight = new Date(date.getTime())
  midnight.setHours(0, 0, 0, 0)

  function fraction(value) {
    if (!value) return -1
    var when = value instanceof Date ? value : new Date(value)
    if (isNaN(when.getTime())) return -1
    return Math.max(0, Math.min(1, (when.getTime() - midnight.getTime()) / DAY_MS))
  }

  var dayFraction = -1
  var nightFraction = -1
  if (state && state.sunrise && state.sunset) {
    dayFraction = fraction(state.sunrise)
    nightFraction = fraction(state.sunset)
  } else {
    var dayMinutes = timeToMinutes(state && state.dayStart ? state.dayStart : DEFAULTS.dayStart)
    var nightMinutes = timeToMinutes(state && state.nightStart ? state.nightStart : DEFAULTS.nightStart)
    if (dayMinutes !== null) dayFraction = dayMinutes / 1440
    if (nightMinutes !== null) nightFraction = nightMinutes / 1440
  }

  return {
    dayStart: dayFraction,
    nightStart: nightFraction,
    now: fraction(date),
    wraps: dayFraction >= 0 && nightFraction >= 0 && dayFraction > nightFraction
  }
}

function clockLabel(value, use24Hour) {
  if (!value) return "—"
  var date = value instanceof Date ? value : new Date(value)
  if (isNaN(date.getTime())) return "—"
  var hours = date.getHours()
  var minutes = pad2(date.getMinutes())
  if (use24Hour === false) {
    var suffix = hours >= 12 ? "PM" : "AM"
    var hour12 = hours % 12
    return (hour12 === 0 ? 12 : hour12) + ":" + minutes + " " + suffix
  }
  return pad2(hours) + ":" + minutes
}

function relativeLabel(target, now) {
  var when = target instanceof Date ? target : new Date(target)
  var date = now instanceof Date ? now : new Date(now)
  if (isNaN(when.getTime())) return ""
  var minutes = Math.round((when.getTime() - date.getTime()) / 60000)
  if (minutes <= 0) return "now"
  if (minutes < 60) return "in " + minutes + " min"
  var hours = Math.floor(minutes / 60)
  var rest = minutes % 60
  if (hours < 24) return "in " + hours + "h" + (rest > 0 ? " " + rest + "m" : "")
  return "in " + Math.round(hours / 24) + "d"
}

// -------------------------------------------------------------- theme scan

function parseThemeScan(raw) {
  try {
    var data = JSON.parse(String(raw || "{}"))
    var themes = data.themes instanceof Array ? data.themes : []
    var cleaned = []
    for (var i = 0; i < themes.length; i++) {
      var theme = themes[i]
      if (!theme || trim(theme.slug) === "") continue
      cleaned.push({
        slug: slug(theme.slug),
        name: label(theme.name) || slug(theme.slug),
        mode: theme.mode === "light" ? "light" : "dark",
        background: trim(theme.background) || "#000000",
        foreground: trim(theme.foreground) || "#ffffff",
        accent: trim(theme.accent) || trim(theme.foreground) || "#ffffff",
        backgrounds: theme.backgrounds instanceof Array ? theme.backgrounds : []
      })
    }
    cleaned.sort(function (a, b) { return a.name.localeCompare(b.name) })
    return { themes: cleaned, current: slug(data.current), seed: data.seed || null }
  } catch (error) {
    return { themes: [], current: "", seed: null }
  }
}

function themeBySlug(themes, wanted) {
  var target = slug(wanted)
  for (var i = 0; i < (themes || []).length; i++)
    if (themes[i].slug === target) return themes[i]
  return null
}

function themesForMode(themes, mode) {
  var out = []
  for (var i = 0; i < (themes || []).length; i++)
    if (themes[i].mode === mode) out.push(themes[i])
  return out
}

function parseGeocoding(raw) {
  try {
    var data = JSON.parse(String(raw || "{}"))
    var results = data.results || []
    var out = []
    // The query asks for five. A reply that ignores that would otherwise become
    // one row of UI per entry, in the process that draws the whole desktop.
    for (var i = 0; i < results.length && out.length < GEOCODING_LIMIT; i++) {
      var item = results[i]
      var place = normalizedLocation(item)
      if (!place || !item.name) continue
      var detail = [item.admin1, item.country].filter(function (part) { return !!part }).join(", ")
      place.name = label(item.name) + (detail ? ", " + label(detail) : "")
      place.timezone = trim(item.timezone)
      out.push(place)
    }
    return out
  } catch (error) {
    return []
  }
}

if (typeof module !== "undefined") {
  module.exports = {
    DAY_MS: DAY_MS,
    DEFAULTS: DEFAULTS,
    SUN_ALTITUDE: SUN_ALTITUDE,
    slug: slug,
    solarDay: solarDay,
    solarWindow: solarWindow,
    currentCycle: currentCycle,
    validCoordinates: validCoordinates,
    normalizedLocation: normalizedLocation,
    sameLocation: sameLocation,
    validTime: validTime,
    timeToMinutes: timeToMinutes,
    validMode: validMode,
    normalizeSettings: normalizeSettings,
    parseSettings: parseSettings,
    serializeSettings: serializeSettings,
    scheduleChanged: scheduleChanged,
    pairChanged: pairChanged,
    fixedState: fixedState,
    solarState: solarState,
    scheduleState: scheduleState,
    parseOverride: parseOverride,
    overrideExpired: overrideExpired,
    effectiveMode: effectiveMode,
    transitionDelay: transitionDelay,
    dayRibbon: dayRibbon,
    clockLabel: clockLabel,
    relativeLabel: relativeLabel,
    parseThemeScan: parseThemeScan,
    themeBySlug: themeBySlug,
    themesForMode: themesForMode,
    parseGeocoding: parseGeocoding
  }
}
