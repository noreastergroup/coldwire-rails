// Turning numbers and timestamps into the words the debug page shows.

// Whole words. "every 1 d" reads like a typo, and the cadence is the one number on this
// card somebody is meant to act on.
export function formatDuration(seconds) {
  if (seconds < 60) return `${seconds} sec`
  if (seconds < 3600) return plural(Math.round(seconds / 60), "min", "min")
  if (seconds < 86400) return plural(Math.round(seconds / 3600), "hour")

  return plural(Math.round(seconds / 86400), "day")
}

export function plural(count, one, many = `${one}s`) {
  return `${count} ${count === 1 ? one : many}`
}

// "Every day", not "Every 1 day".
export function formatInterval(seconds) {
  const text = formatDuration(seconds)

  return text.startsWith("1 ") ? text.slice(2) : text
}

export function displayUrl(href) {
  try {
    const url = new URL(href)
    return `${url.pathname}${url.search}`
  } catch {
    return href
  }
}

export function formatBytes(bytes) {
  if (!Number.isFinite(bytes) || bytes < 0) return "—"
  if (bytes < 1024) return `${bytes} B`
  if (bytes < 1024 * 1024) {
    const kb = bytes / 1024
    return `${kb < 10 ? kb.toFixed(1) : Math.round(kb)} KB`
  }
  return `${(bytes / (1024 * 1024)).toFixed(1)} MB`
}

// Built once. Constructing an Intl formatter is expensive, and this is called for every row
// on every keystroke — 485 of them cost 40ms a piece of typing when it was built per call.
const relative = new Intl.RelativeTimeFormat(undefined, { numeric: "auto" })

export function formatCachedAt(timestamp) {
  if (!timestamp) return "Unknown time"
  const date = new Date(timestamp * 1000)
  if (Number.isNaN(date.getTime())) return "Unknown time"

  const deltaSec = Math.round((date.getTime() - Date.now()) / 1000)
  const abs = Math.abs(deltaSec)
  const rtf = relative
  if (abs < 60) return rtf.format(deltaSec, "second")
  if (abs < 3600) return rtf.format(Math.round(deltaSec / 60), "minute")
  if (abs < 86400) return rtf.format(Math.round(deltaSec / 3600), "hour")
  if (abs < 86400 * 7) return rtf.format(Math.round(deltaSec / 86400), "day")
  return date.toLocaleString(undefined, { month: "short", day: "numeric", hour: "numeric", minute: "2-digit" })
}
