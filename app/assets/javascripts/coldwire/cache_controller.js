import { Controller } from "@hotwired/stimulus"

// Ask the headers before reading the body. A real cache is hundreds of entries and tens of
// megabytes; blob() on every one of them turns listing the cache into a multi-second job that
// makes the refresh button look broken. Content-Length is present on nearly everything Rails
// serves, and the body is only read when it is not.
async function entrySize(response) {
  if (!response) return 0

  const declared = Number(response.headers.get("Content-Length"))
  if (Number.isFinite(declared) && declared >= 0) return declared

  return (await response.clone().blob()).size
}

const FORCED_KEY = "coldwire-forced"
const SYNCED_AT_KEY = "coldwire-synced-at"
const BACKOFF_KEY = "coldwire-sync-backoff"
// A year. The value is rewritten on every completed sync, so this only has to outlast a gap
// in use, not be tuned.
const STAMP_LIFE = 31536000
const SYNC_MESSAGE = "coldwire:sync"
const TIMESTAMP_HEADER = "timestamp"

// Drives the Coldwire debug page: inspect the cache, precache the manifest, force offline.
export default class extends Controller {
  static values = { probeUrl: String, autoSync: Boolean, syncInterval: Number }
  static targets = [
    "status",
    "connection",
    "connectionLight",
    "summary",
    "entries",
    "forcedToggle",
    "spinner",
    "progress",
    "progressBar",
    "progressLabel",
    "clearButton",
    "refreshButton",
    "autoSync",
    "syncedAt",
    "syncStatus",
    "syncButton",
    "syncLabel"
  ]

  connect() {
    this.onOnline = () => this.renderConnection()
    window.addEventListener("online", this.onOnline)
    window.addEventListener("offline", this.onOnline)

    // The worker broadcasts sync state to every open page, so this hears about syncs it did
    // not start — including one already running when this page opened.
    this.onWorkerMessage = (event) => this.handleSyncMessage(event)
    if ("serviceWorker" in navigator) {
      navigator.serviceWorker.addEventListener("message", this.onWorkerMessage)
      // A ServiceWorkerContainer starts with its message queue disabled. Setting onmessage
      // enables it; addEventListener alone does not. Without this the page can listen
      // faithfully and never hear a thing — no progress, no counts, no outcome.
      if (navigator.serviceWorker.startMessages) navigator.serviceWorker.startMessages()
    }

    this.restoreForced()
    this.refresh()

    // Recomputed from the same clock the head snippet reads, rather than counted down from a
    // number held here — a web view freezes timers when backgrounded, and a countdown that
    // kept its own tally would come back wrong.
    this.ticker = window.setInterval(() => this.tick(), 1000)

    // This page draws a countdown, so it must be the thing that acts on it. The head snippet
    // keeps its own timer for every other page; here it would be a second clock with its own
    // idea of the interval, firing while the countdown still showed time remaining.
    window.__coldwireSyncOwnedByPage = true
  }

  disconnect() {
    window.clearInterval(this.ticker)
    delete window.__coldwireSyncOwnedByPage
    window.removeEventListener("online", this.onOnline)
    window.removeEventListener("offline", this.onOnline)
    if ("serviceWorker" in navigator) {
      navigator.serviceWorker.removeEventListener("message", this.onWorkerMessage)
    }
  }

  // MARK: automatic sync

  handleSyncMessage(event) {
    const data = event.data
    if (!data || data.type !== SYNC_MESSAGE) return

    if (data.state === "started") {
      this.syncRunning = true
      const retired = data.retired ? `, retired ${data.retired}` : ""
      this.setSyncStatus(data.pending
        ? `Syncing ${data.pending} file${data.pending === 1 ? "" : "s"}${retired}…`
        : `Already up to date${retired}.`)
      // Counts arrive with the first progress tick; until then the bar just says "working".
      if (data.pending) this.showProgress("Starting…")
      // Spin for a run this page did not start, but leave the buttons alone: a worker that
      // dies mid-sync sends no "finished", and a permanently disabled page would be worse
      // than a button you can press twice. Pressing it joins the run in flight anyway.
      this.toggleSyncing(Boolean(data.pending))
    } else if (data.state === "progress") {
      // A page that opened mid-run arrives here without ever having seen "started", so this
      // branch has to be able to put the page into the running state on its own.
      this.syncRunning = true
      this.toggleSyncing(true)
      if (this.hasProgressTarget) this.progressTarget.hidden = false
      // The bar carries the live count; the line above stays on the high-level "what".
      this.renderProgress(data)
    } else if (data.state === "finished") {
      this.syncRunning = false
      this.syncSettled = true

      if (data.complete) {
        this.writeStamp(SYNCED_AT_KEY, data.finishedAt || Date.now())
        this.retryAfter = 0
      } else if (!data.offline) {
        this.retryAfter = Date.now() + this.syncIntervalValue * 1000
      }

      this.setSyncStatus(this.describeFinishedSync(data))
      this.hideProgress()
      this.toggleBusy(false)
      this.toggleSyncing(false)
      // The stamp is written by the head snippet's listener, which is registered first and
      // runs synchronously, so it is already up to date by the time this reads it.
      this.renderSyncedAt()
      this.renderCache()
    }
  }

  // The head snippet fires a sync while the page is still parsing, so a run — a short one
  // especially — can start and finish before this controller connects and starts listening.
  // Asking the worker on arrival is the difference between showing the sync you just caused
  // and sitting on "Idle" through it.
  async catchUpOnSync() {
    let state = null
    try {
      state = await this.sendToWorker("syncState", {}, 5000)
    } catch {
      // No worker yet, or an older one that does not answer. Nothing to catch up on.
      return
    }

    const last = state?.last
    if (!last) return

    // A run that stopped without ever saying "finished" is a worker that was shut down
    // mid-sync. Replaying it would leave a spinner up for a sync nobody is doing.
    if (!state.running && last.state !== "finished") return

    // Joining part way through, the count of what this run set out to do is already gone —
    // only "started" carried it. The bar still says where it has got to.
    if (last.state !== "finished") this.setSyncStatus("Syncing…")

    this.handleSyncMessage({ data: last })
  }

  describeFinishedSync(data) {
    // Nothing went wrong and nothing needs retrying — it was simply never asked to work.
    if (data.offline) {
      return data.reason === "forced"
        ? "Paused while force offline is on."
        : "No connection. Will sync when it is back."
    }
    if (data.error) return `Sync failed: ${data.error}`

    const parts = [ `Cached ${data.cached}` ]
    if (data.retired) parts.push(`retired ${data.retired}`)
    if (data.failed?.length) parts.push(`${data.failed.length} failed`)
    // A sync attempts the whole manifest, so anything left is something that would not
    // fetch. It stays missing, so the next sync finds it and tries again.
    if (!data.complete) parts.push(`${data.remaining} to retry`)

    return `${parts.join(", ")}.`
  }

  // The same pass a page load kicks off by itself, minus the wait — the interval throttles
  // only the automatic trigger, and asking by hand means now. The worker hands back the run
  // already in flight rather than starting a second, so pressing this during a sync joins it.
  //
  // Progress and the closing summary arrive on the broadcast every page gets, so this run
  // renders through handleSyncMessage exactly like one another tab started.
  async syncNow(event) {
    event?.preventDefault()
    this.setStatus("")
    this.syncSettled = false
    // Reaching the worker takes a moment, and the ticker keeps ticking while it does.
    this.syncStarting = true
    this.toggleBusy(true)
    this.toggleSyncing(true)
    this.setSyncStatus("Starting…")
    this.showProgress("Starting…")

    try {
      await this.sendToWorker("sync", {}, 10 * 60 * 1000)
    } catch (error) {
      // A sync that already reported itself finished has nothing to apologise for; the reply
      // channel simply did not survive to say so.
      if (!this.syncSettled) {
        this.setSyncStatus(error.message || "Sync failed")
        this.hideProgress()
      }
    } finally {
      this.syncStarting = false
      this.toggleBusy(false)
      this.toggleSyncing(false)
    }
  }

  setSyncStatus(text) {
    if (this.hasSyncStatusTarget) this.syncStatusTarget.textContent = text
  }

  renderAutoSync() {
    if (!this.hasAutoSyncTarget) return

    if (!this.autoSyncValue) {
      this.autoSyncTarget.textContent = "Automatic sync is off"
      return
    }

    this.autoSyncTarget.textContent = this.syncIntervalValue > 0
      ? `Automatic sync is on — every ${this.formatDuration(this.syncIntervalValue)}`
      : "Automatic sync is on"
  }

  renderSyncedAt() {
    if (!this.hasSyncedAtTarget) return

    const stamp = this.readStamp(SYNCED_AT_KEY)
    const synced = stamp
      ? `Synced ${this.formatCachedAt(Math.floor(stamp / 1000))}`
      : "Never synced"
    const next = this.describeNextSync()

    this.syncedAtTarget.textContent = next ? `${synced} · ${next}` : synced
    this.syncedAtTarget.title = stamp ? new Date(stamp).toLocaleString() : ""
  }

  // A page that shows a countdown had better act on it. The head snippet keeps its own timer
  // for every other page in the app, but this page must not depend on it: the two are
  // separate clocks, and when they disagreed the page sat there saying "due now" with
  // nothing scheduled to do anything about it — and no way to tell from the page which of
  // them had gone wrong. Now the countdown reaching zero *is* what starts the sync, so what
  // the page says and what it does cannot come apart.
  tick() {
    this.renderSyncedAt()

    if (!this.autoSyncValue || this.syncIntervalValue <= 0) return
    if (this.syncRunning || this.syncStarting) return
    // Nothing to do out of sight, and nothing worth doing with no network.
    if (document.hidden || this.syncPaused()) return
    if (Date.now() < this.dueAt()) return

    this.syncNow()
  }

  // When a sync is next owed. Reads the same keys the head snippet writes, so opening this
  // page never resets a clock that was already running.
  dueAt() {
    const stamp = this.readStamp(SYNCED_AT_KEY)

    return Math.max(
      stamp ? stamp + this.syncIntervalValue * 1000 : 0,
      this.readStamp(BACKOFF_KEY) || 0,
      // A run that finished without getting through everything leaves the deadline in the
      // past. Held here rather than in storage: it is this page pacing its own retries, not
      // a decision the rest of the app should inherit.
      this.retryAfter || 0
    )
  }

  // Syncing is nothing but network. Force offline is a request for none of it, and with no
  // connection there is nothing to ask for — so neither counts down to anything.
  syncPaused() {
    if (this.isForced()) return "forced"
    if (this.online === false) return "offline"

    return null
  }

  isForced() {
    if (this.hasForcedToggleTarget) return this.forcedToggleTarget.checked

    try {
      return window.localStorage.getItem(FORCED_KEY) === "1"
    } catch {
      return false
    }
  }

  describeNextSync() {
    if (!this.autoSyncValue || this.syncIntervalValue <= 0) return ""
    if (this.syncRunning) return "syncing now"

    const paused = this.syncPaused()
    if (paused) {
      return paused === "forced" ? "paused, force offline is on" : "paused, no connection"
    }

    const seconds = Math.ceil((this.dueAt() - Date.now()) / 1000)

    return seconds > 0 ? `next in ${this.formatDuration(seconds)}` : "due now"
  }

  // The one fact worth keeping properly — when the cache was last brought up to date — lives
  // in a cookie with an explicit expiry, which outlives the site data a web view may clear
  // out from under localStorage. It is one number, so it costs a dozen bytes on a request.
  // The scheduling scratch (attempts, backoff) stays in localStorage; losing it costs
  // nothing, and there is no reason to send it to the server.
  writeStamp(key, value) {
    if (key === SYNCED_AT_KEY) {
      // Kept in memory as well: a cookie that will not store would otherwise leave the clock
      // reading zero, making every finished sync instantly due again — a hot loop.
      this.lastFinished = Number(value) || 0
      return this.writeCookie(key, value)
    }

    try {
      window.localStorage.setItem(key, String(value))
    } catch {
      // Private mode and the like. The clock falls back to the head snippet's copy.
    }
  }

  readStamp(key) {
    let value = null
    try {
      value = key === SYNCED_AT_KEY
        ? Math.max(this.readCookie(key) || 0, this.lastFinished || 0)
        : Number(window.localStorage.getItem(key))
    } catch {
      // Private mode and the like. The line just stays unknown.
    }

    return Number.isFinite(value) && value > 0 ? value : null
  }

  readCookie(key) {
    const match = document.cookie.match(new RegExp(`(?:^|; )${key}=([^;]*)`))

    return match ? Number(decodeURIComponent(match[1])) : NaN
  }

  writeCookie(key, value) {
    try {
      const secure = window.location.protocol === "https:" ? "; secure" : ""
      document.cookie =
        `${key}=${encodeURIComponent(String(value))}; path=/; max-age=${STAMP_LIFE}; samesite=lax${secure}`
    } catch {
      // Nothing to do; the line just stays unknown.
    }
  }

  formatDuration(seconds) {
    if (seconds < 60) return `${seconds}s`
    if (seconds < 3600) return `${Math.round(seconds / 60)} min`
    if (seconds < 86400) return `${Math.round(seconds / 3600)} h`
    return `${Math.round(seconds / 86400)} d`
  }

  async refresh(event) {
    event?.preventDefault()
    this.setRefreshing(true)

    try {
        this.renderAutoSync()
      this.renderSyncedAt()
      await this.syncForcedToWorker()
      await this.catchUpOnSync()
      await this.renderCache()
      // Last, and awaited: it waits on a network probe, so the button should still be
      // spinning while it does.
      await this.renderConnection()
    } catch (error) {
      // One unreadable cache entry used to abandon the rest of the refresh with nothing said,
      // which is indistinguishable from a button that does not work.
      this.setStatus(error.message || "Could not refresh")
    } finally {
      this.setRefreshing(false)
    }
  }

  // Reloading beats re-rendering in place: it re-runs the worker registration, the identity
  // check and the sync trigger too, so what you see afterwards is a genuine fresh start
  // rather than a few values re-read.
  reload(event) {
    event?.preventDefault()
    this.setRefreshing(true)
    window.location.reload()
  }

  setRefreshing(busy) {
    if (!this.hasRefreshButtonTarget) return

    this.refreshButtonTarget.toggleAttribute("data-busy", busy)
    this.refreshButtonTarget.disabled = busy
  }

  showProgress(label) {
    if (this.hasProgressTarget) this.progressTarget.hidden = false
    this.setProgressBar(null)
    if (this.hasProgressLabelTarget) this.progressLabelTarget.textContent = label
  }

  hideProgress() {
    if (!this.hasProgressTarget) return
    this.progressTarget.hidden = true
    this.progressTarget.removeAttribute("aria-busy")
  }

  renderProgress({ phase, done, total }) {
    const noun = phase === "assets" ? "asset" : "page"
    if (total === 0) {
      this.setProgressBar(1)
      if (this.hasProgressLabelTarget) this.progressLabelTarget.textContent = `No ${noun}s to cache.`
      return
    }

    this.setProgressBar(done / total)
    if (this.hasProgressLabelTarget) {
      this.progressLabelTarget.textContent = `${noun === "page" ? "Pages" : "Assets"} ${done} of ${total}`
    }
  }

  // A null fraction means "working, count unknown" — show a full-width pulse instead.
  setProgressBar(fraction) {
    if (!this.hasProgressBarTarget) return

    const indeterminate = fraction === null
    const percent = indeterminate ? 100 : Math.round(Math.min(Math.max(fraction, 0), 1) * 100)

    this.progressBarTarget.style.width = `${percent}%`
    this.progressBarTarget.classList.toggle("coldwire-pulse", indeterminate)

    if (!this.hasProgressTarget) return
    this.progressTarget.setAttribute("aria-busy", "true")
    if (indeterminate) {
      this.progressTarget.removeAttribute("aria-valuenow")
    } else {
      this.progressTarget.setAttribute("aria-valuenow", String(percent))
    }
  }

  async clear(event) {
    event.preventDefault()
    // It is an unlabelled icon next to Reload and it throws away everything the app has to
    // work with offline. Worth one question.
    if (!window.confirm("Delete everything cached? The app will have nothing to show offline until it syncs again.")) return

    this.setStatus("Clearing cache…")
    this.toggleBusy(true)

    try {
      const result = await this.clearCaches()
      const cleared = result.cleared || 0
      this.setStatus(cleared === 1 ? "Cleared 1 cache." : `Cleared ${cleared} caches.`)
      await this.renderCache()
    } catch (error) {
      this.setStatus(error.message || "Could not clear cache")
    } finally {
      this.toggleBusy(false)
    }
  }

  async toggleForced(event) {
    const enabled = event.currentTarget.checked
    window.localStorage.setItem(FORCED_KEY, enabled ? "1" : "0")
    this.renderConnection()
    // The countdown means something different the instant this changes; do not make the user
    // wait a tick to see it.
    this.renderSyncedAt()

    try {
      await this.sendToWorker("setForcedOffline", { value: enabled }, 5000)
      this.setStatus(enabled ? "Forced offline is on. Requests will use the cache only." : "Forced offline is off.")
    } catch (error) {
      this.setStatus(error.message || "Could not update offline mode")
    }
  }

  restoreForced() {
    if (!this.hasForcedToggleTarget) return
    this.forcedToggleTarget.checked = window.localStorage.getItem(FORCED_KEY) === "1"
  }

  async syncForcedToWorker() {
    if (!this.hasForcedToggleTarget) return
    try {
      await this.sendToWorker("setForcedOffline", { value: this.forcedToggleTarget.checked }, 5000)
    } catch {
      // Worker may not be controlling yet; the checkbox still reflects local state.
    }
  }

  // Ask the server, always.
  //
  // navigator.onLine answers "is a network interface up", which is not the question — and in
  // a web view it is unreliable in both directions: true with the server stopped, and
  // sometimes false while everything works. Consulting it at all meant the page could report
  // Offline without ever checking. One HEAD to the health check is cheap and it is the truth.
  async renderConnection() {
    if (!this.hasConnectionTarget) return

    if (this.hasForcedToggleTarget && this.forcedToggleTarget.checked) {
      // Amber, not red: nothing is wrong, you asked for this.
      this.setConnection("Forced offline", "forced")
      return
    }

    this.setConnection("Checking…", "checking")

    // A later check can finish after an earlier one; only the newest may write.
    const token = (this.connectionToken = (this.connectionToken || 0) + 1)
    const reachable = await this.serverReachable()
    if (token !== this.connectionToken) return

    if (reachable === null) {
      this.setConnection("Unknown", "checking")
      return
    }

    this.online = reachable
    this.setConnection(reachable ? "Online" : "Offline", reachable ? "online" : "offline")
  }

  setConnection(text, state) {
    this.connectionTarget.textContent = text
    if (this.hasConnectionLightTarget) this.connectionLightTarget.dataset.state = state
  }

  async serverReachable() {
    // With nothing to probe there is no honest answer, so say so rather than guess.
    if (!this.hasProbeUrlValue) return null

    const controller = new AbortController()
    const timeout = window.setTimeout(() => controller.abort(), 4000)

    try {
      // Any answer at all means reachable — a 401 or a redirect is still the server talking.
      await fetch(this.probeUrlValue, { method: "HEAD", cache: "no-store", signal: controller.signal })
      return true
    } catch {
      return false
    } finally {
      window.clearTimeout(timeout)
    }
  }

  async renderCache() {
    const cachesInfo = await this.listCaches()
    const entries = cachesInfo.flatMap((cache) => cache.entries || [])
    const totalBytes = entries.reduce((sum, entry) => sum + (entry.size || 0), 0)

    if (this.hasSummaryTarget) {
      const cacheCount = cachesInfo.length
      const urlCount = entries.length
      this.summaryTarget.textContent = urlCount === 0
        ? "Nothing cached"
        : `${urlCount} file${urlCount === 1 ? "" : "s"} cached · ${this.formatBytes(totalBytes)}`
    }

    if (!this.hasEntriesTarget) return

    this.entriesTarget.replaceChildren()
    if (entries.length === 0) {
      const empty = document.createElement("li")
      empty.className = "coldwire-empty"
      empty.textContent = "None yet."
      this.entriesTarget.append(empty)
      return
    }

    entries
      .slice()
      .sort((a, b) => (b.timestamp || 0) - (a.timestamp || 0) || this.displayUrl(a.url).localeCompare(this.displayUrl(b.url)))
      .forEach((entry) => {
        const item = document.createElement("li")
        item.className = "coldwire-entry"

        const path = document.createElement("div")
        path.className = "coldwire-entry-url"
        path.textContent = this.displayUrl(entry.url)
        path.title = entry.url

        const meta = document.createElement("div")
        meta.className = "coldwire-entry-meta"
        meta.textContent = entry.timestamp
          ? `${this.formatBytes(entry.size)} · ${this.formatCachedAt(entry.timestamp)}`
          : this.formatBytes(entry.size)
        if (entry.timestamp) meta.title = new Date(entry.timestamp * 1000).toLocaleString()

        item.append(path, meta)
        this.entriesTarget.append(item)
      })
  }

  async listCaches() {
    if ("caches" in window) {
      const names = await caches.keys()
      const result = []
      for (const name of names) {
        const cache = await caches.open(name)
        const keys = await cache.keys()
        const entries = []
        for (const request of keys) {
          entries.push(await this.describeCached(request, await cache.match(request, { ignoreVary: true })))
        }
        result.push({ name, entries })
      }
      return result
    }

    const response = await this.sendToWorker("listCache", {}, 5000)
    return response.caches || []
  }

  async describeCached(request, response) {
    const seconds = Number(request.headers.get(TIMESTAMP_HEADER))

    return {
      url: request.url,
      size: await entrySize(response),
      timestamp: Number.isFinite(seconds) && seconds > 0 ? seconds : null
    }
  }

  async clearCaches() {
    if ("caches" in window) {
      const names = await caches.keys()
      await Promise.all(names.map((name) => caches.delete(name)))
      this.sendToWorker("clearCache", {}, 5000).catch(() => {})
      return { ok: true, cleared: names.length }
    }

    return this.sendToWorker("clearCache", {}, 5000)
  }

  displayUrl(href) {
    try {
      const url = new URL(href)
      return `${url.pathname}${url.search}`
    } catch {
      return href
    }
  }

  formatBytes(bytes) {
    if (!Number.isFinite(bytes) || bytes < 0) return "—"
    if (bytes < 1024) return `${bytes} B`
    if (bytes < 1024 * 1024) {
      const kb = bytes / 1024
      return `${kb < 10 ? kb.toFixed(1) : Math.round(kb)} KB`
    }
    return `${(bytes / (1024 * 1024)).toFixed(1)} MB`
  }

  formatCachedAt(timestamp) {
    if (!timestamp) return "Unknown time"
    const date = new Date(timestamp * 1000)
    if (Number.isNaN(date.getTime())) return "Unknown time"

    const deltaSec = Math.round((date.getTime() - Date.now()) / 1000)
    const abs = Math.abs(deltaSec)
    const rtf = new Intl.RelativeTimeFormat(undefined, { numeric: "auto" })
    if (abs < 60) return rtf.format(deltaSec, "second")
    if (abs < 3600) return rtf.format(Math.round(deltaSec / 60), "minute")
    if (abs < 86400) return rtf.format(Math.round(deltaSec / 3600), "hour")
    if (abs < 86400 * 7) return rtf.format(Math.round(deltaSec / 86400), "day")
    return date.toLocaleString(undefined, { month: "short", day: "numeric", hour: "numeric", minute: "2-digit" })
  }

  async sendToWorker(type, payload, timeoutMs) {
    if (!("serviceWorker" in navigator)) {
      throw new Error("Service workers are not available in this web view")
    }

    const registration = await navigator.serviceWorker.ready
    if (!registration.active) {
      throw new Error("Service worker is not active yet. Reload and try again.")
    }

    return new Promise((resolve, reject) => {
      const { port1, port2 } = new MessageChannel()
      // A worker torn down mid-job answers nobody, so every send needs a way out. For a sync
      // that is a backstop only: the run reports itself over the broadcast either way.
      const timeout = window.setTimeout(() => reject(new Error("Timed out")), timeoutMs)

      port1.onmessage = (event) => {
        window.clearTimeout(timeout)
        resolve(event.data)
      }

      registration.active.postMessage({ type, ...payload }, [ port2 ])
    })
  }

  setStatus(text) {
    if (this.hasStatusTarget) this.statusTarget.textContent = text
  }

  toggleBusy(disabled) {
    if (this.hasSyncButtonTarget) this.syncButtonTarget.disabled = disabled
    if (this.hasClearButtonTarget) this.clearButtonTarget.disabled = disabled
    if (this.hasRefreshButtonTarget) this.refreshButtonTarget.disabled = disabled
  }

  // Only the sync button spins — toggleBusy also runs for Clear and Refresh.
  toggleSyncing(active) {
    if (this.hasSpinnerTarget) this.spinnerTarget.hidden = !active
    if (this.hasSyncLabelTarget) {
      this.syncLabelTarget.textContent = active ? "Syncing…" : "Sync now"
    }
  }
}
