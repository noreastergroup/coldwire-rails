import { Controller } from "@hotwired/stimulus"

const FORCED_KEY = "coldwire-forced"
const SYNCED_AT_KEY = "coldwire-synced-at"
const SYNC_MESSAGE = "coldwire:sync"
const TIMESTAMP_HEADER = "timestamp"

// Drives the Coldwire debug page: inspect the cache, precache the manifest, force offline.
export default class extends Controller {
  static values = { packUrl: String, probeUrl: String, autoSync: Boolean, syncInterval: Number }
  static targets = [
    "status",
    "connection",
    "worker",
    "summary",
    "entries",
    "forcedToggle",
    "prefetchButton",
    "prefetchLabel",
    "spinner",
    "progress",
    "progressBar",
    "progressLabel",
    "clearButton",
    "refreshButton",
    "autoSync",
    "syncedAt",
    "syncStatus",
    "syncButton"
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
    }

    this.restoreForced()
    this.refresh()
  }

  disconnect() {
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
      const retired = data.retired ? `, retired ${data.retired}` : ""
      this.setSyncStatus(`Syncing ${data.pending} outstanding${retired}…`)
    } else if (data.state === "progress") {
      const noun = data.phase === "assets" ? "Assets" : "Pages"
      this.setSyncStatus(data.total ? `${noun} ${data.done} of ${data.total}` : `${noun}: none`)
    } else if (data.state === "finished") {
      this.setSyncStatus(this.describeFinishedSync(data))
      this.renderSyncedAt()
      this.renderCache()
    }
  }

  describeFinishedSync(data) {
    if (data.error) return `Sync failed: ${data.error}`

    const parts = [ `Cached ${data.cached}` ]
    if (data.retired) parts.push(`retired ${data.retired}`)
    if (data.failed?.length) parts.push(`${data.failed.length} failed`)
    // A sync attempts the whole manifest, so anything left is something that would not
    // fetch. It stays missing, so the next sync finds it and tries again.
    if (!data.complete) parts.push(`${data.remaining} to retry`)

    return `${parts.join(", ")}.`
  }

  // Forces a sync regardless of how recently one ran — the interval is a page-side throttle,
  // and the worker does whatever it is asked.
  async syncNow(event) {
    event?.preventDefault()
    this.setSyncStatus("Starting…")

    try {
      await this.sendToWorker("sync", {}, 10 * 60 * 1000)
    } catch (error) {
      this.setSyncStatus(error.message || "Sync failed")
    }
  }

  setSyncStatus(text) {
    if (this.hasSyncStatusTarget) this.syncStatusTarget.textContent = text
  }

  renderAutoSync() {
    if (!this.hasAutoSyncTarget) return

    if (!this.autoSyncValue) {
      this.autoSyncTarget.textContent = "Off"
      return
    }

    const every = this.syncIntervalValue > 0
      ? ` · every ${this.formatDuration(this.syncIntervalValue)}`
      : ""
    this.autoSyncTarget.textContent = `On${every}`
  }

  renderSyncedAt() {
    if (!this.hasSyncedAtTarget) return

    let stamp = null
    try {
      stamp = Number(window.localStorage.getItem(SYNCED_AT_KEY))
    } catch {
      // Private mode and the like. The line just stays unknown.
    }

    if (!Number.isFinite(stamp) || stamp <= 0) {
      this.syncedAtTarget.textContent = "Never"
      return
    }

    const date = new Date(stamp)
    this.syncedAtTarget.textContent = this.formatCachedAt(Math.floor(stamp / 1000))
    this.syncedAtTarget.title = date.toLocaleString()
  }

  formatDuration(seconds) {
    if (seconds < 60) return `${seconds}s`
    if (seconds < 3600) return `${Math.round(seconds / 60)} min`
    if (seconds < 86400) return `${Math.round(seconds / 3600)} h`
    return `${Math.round(seconds / 86400)} d`
  }

  async refresh(event) {
    event?.preventDefault()
    this.renderConnection()
    this.renderWorker()
    this.renderAutoSync()
    this.renderSyncedAt()
    await this.syncForcedToWorker()
    await this.renderCache()
  }

  async prefetch(event) {
    event.preventDefault()
    this.setStatus("Loading manifest…")
    this.toggleBusy(true)
    this.togglePrefetching(true)
    this.showProgress("Loading manifest…")

    try {
      const urls = await this.fetchPackUrls()
      if (urls.length === 0) {
        this.setStatus("Nothing to precache.")
        return
      }

      this.setStatus(`Prefetching ${urls.length} pages…`)
      const result = await this.sendToWorker(
        "prefetch",
        { urls },
        10 * 60 * 1000,
        (progress) => this.renderProgress(progress)
      )
      const failed = result.failed?.length || 0
      if (result.ok) {
        this.setStatus(`Cached ${result.cached} files.`)
      } else {
        this.setStatus(`Cached ${result.cached} files, ${failed} failed.`)
      }
      await this.renderCache()
    } catch (error) {
      this.setStatus(error.message || "Prefetch failed")
    } finally {
      this.toggleBusy(false)
      this.togglePrefetching(false)
      this.hideProgress()
    }
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

  async fetchPackUrls() {
    if (!this.packUrlValue) {
      throw new Error("Manifest URL is missing")
    }

    const response = await fetch(this.packUrlValue, { headers: { Accept: "application/json" } })
    // A signed-out request follows a redirect to the sign-in page and arrives here as a
    // perfectly ok 200 of HTML, which would fail as an opaque JSON parse error.
    if (response.redirected) {
      throw new Error("Signed out — sign in and try again")
    }
    if (!response.ok) {
      throw new Error(`Could not load manifest (${response.status})`)
    }

    const pack = await response.json()
    return Array.isArray(pack.urls) ? pack.urls : []
  }

  async clear(event) {
    event.preventDefault()
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

  // navigator.onLine answers "is a network interface up", not "can I reach the server". In a
  // web view it is true whenever wifi is on, so a stopped server still reads as Online — which
  // is the one moment you are looking at this page to find out otherwise. Trust it only when
  // it says false, which is conclusive, and otherwise ask the server.
  async renderConnection() {
    if (!this.hasConnectionTarget) return

    if (this.hasForcedToggleTarget && this.forcedToggleTarget.checked) {
      this.connectionTarget.textContent = "Forced offline"
      return
    }

    if (!navigator.onLine) {
      this.connectionTarget.textContent = "Offline"
      return
    }

    this.connectionTarget.textContent = "Checking…"

    // A later check can finish after an earlier one; only the newest may write.
    const token = (this.connectionToken = (this.connectionToken || 0) + 1)
    const reachable = await this.serverReachable()
    if (token !== this.connectionToken) return

    this.connectionTarget.textContent = reachable ? "Online" : "Offline · server unreachable"
  }

  async serverReachable() {
    if (!this.hasProbeUrlValue) return navigator.onLine

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

  renderWorker() {
    if (!this.hasWorkerTarget) return
    if (!("serviceWorker" in navigator)) {
      this.workerTarget.textContent = "Not supported"
      return
    }
    if (navigator.serviceWorker.controller) {
      this.workerTarget.textContent = "Controlling this page"
      return
    }
    this.workerTarget.textContent = "Registered, not controlling yet"
  }

  async renderCache() {
    const cachesInfo = await this.listCaches()
    const entries = cachesInfo.flatMap((cache) => cache.entries || [])
    const totalBytes = entries.reduce((sum, entry) => sum + (entry.size || 0), 0)

    if (this.hasSummaryTarget) {
      const cacheCount = cachesInfo.length
      const urlCount = entries.length
      this.summaryTarget.textContent = `${urlCount} URL${urlCount === 1 ? "" : "s"} in ${cacheCount} cache${cacheCount === 1 ? "" : "s"} · ${this.formatBytes(totalBytes)}`
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
    const blob = response ? await response.clone().blob() : null
    const seconds = Number(request.headers.get(TIMESTAMP_HEADER))
    return {
      url: request.url,
      size: blob?.size ?? 0,
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

  async sendToWorker(type, payload, timeoutMs, onProgress) {
    if (!("serviceWorker" in navigator)) {
      throw new Error("Service workers are not available in this web view")
    }

    const registration = await navigator.serviceWorker.ready
    if (!registration.active) {
      throw new Error("Service worker is not active yet. Reload and try again.")
    }

    return new Promise((resolve, reject) => {
      const { port1, port2 } = new MessageChannel()
      let timeout = null
      const arm = () => {
        window.clearTimeout(timeout)
        timeout = window.setTimeout(() => reject(new Error("Timed out")), timeoutMs)
      }
      arm()

      port1.onmessage = (event) => {
        // Progress ticks keep the timeout alive, so it bounds silence, not total work.
        if (event.data?.type === "progress") {
          arm()
          onProgress?.(event.data)
          return
        }

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
    if (this.hasPrefetchButtonTarget) this.prefetchButtonTarget.disabled = disabled
    if (this.hasClearButtonTarget) this.clearButtonTarget.disabled = disabled
    if (this.hasRefreshButtonTarget) this.refreshButtonTarget.disabled = disabled
  }

  // Only the prefetch button spins — toggleBusy also runs for Clear and Refresh.
  togglePrefetching(active) {
    if (this.hasSpinnerTarget) this.spinnerTarget.hidden = !active
    if (this.hasPrefetchLabelTarget) {
      this.prefetchLabelTarget.textContent = active ? "Prefetching…" : "Precache"
    }
  }
}
