import { Controller } from "@hotwired/stimulus"
import { formatBytes, formatCachedAt, formatDuration, formatInterval, displayUrl } from "coldwire/format"
import { sendToWorker } from "coldwire/worker"
import { renderArchiveStatus, renderArchiveProgress, toggleArchiveBusy } from "coldwire/archives"
import { describeEntry, describeCached, describeFinishedSync } from "coldwire/entries"

// Storage goes through the one wrapper the head snippet defines, so the page and the snippet
// cannot disagree about where anything is kept. Without that snippet there is no service
// worker either, so an inert stand-in is the honest degradation rather than a second
// implementation that would only drift.
const INERT_STORE = {
  keys: {},
  get: () => null,
  set: () => {},
  number: () => 0,
  on: () => false,
  toggle: () => {}
}
const SYNC_MESSAGE = "coldwire:sync"

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
    "autoSyncToggle",
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
    "syncLabel",
    "search",
    "sort",
    "forgetTemplate",
    "detail",
    "detailUrl",
    "detailMeta",
    "detailForget",
    "archives"
  ]

  get store() {
    return window.coldwireStore || INERT_STORE
  }

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
    this.restoreAutoSync()
    this.renderArchives()
    this.refresh()

    // A download outlives the page that started it, and reports itself as it goes.
    this.onArchiveMessage = (event) => this.handleArchiveMessage(event)
    if ("serviceWorker" in navigator) {
      navigator.serviceWorker.addEventListener("message", this.onArchiveMessage)
    }

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
    if ("serviceWorker" in navigator && this.onArchiveMessage) {
      navigator.serviceWorker.removeEventListener("message", this.onArchiveMessage)
    }
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

      this.settleSync(data)
      this.setSyncStatus(describeFinishedSync(data))
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
      state = await sendToWorker("syncState", {}, 5000)
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

  // Reached from this page's own reply as well as from the broadcast, because a broadcast can
  // go missing and this page drives its own sync — miss the outcome and it reads "Never
  // synced" and re-syncs on every tick. Writing the same finishedAt twice is harmless.
  settleSync(data) {
    if (!data) return

    if (data.offline) {
      // Nothing was attempted, so the clock keeps saying when the cache was last actually
      // brought up to date — but do not ask again on the very next tick either.
      this.retryAfter = Date.now() + this.syncIntervalValue * 1000
      return
    }

    // A pass happened. Record it however it went: requiring every URL to succeed meant one
    // bad entry among hundreds stopped the clock for good.
    this.store.set(this.store.keys.syncedAt, data.finishedAt || Date.now())
    this.retryAfter = 0
  }

  // The same pass a page load kicks off, minus the wait. The worker hands back the run already
  // in flight rather than starting a second, so pressing this during a sync joins it.
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
      const result = await sendToWorker("sync", {}, 10 * 60 * 1000)

      // The reply cannot be missed the way a broadcast can, so this is what the clock rests
      // on. If the broadcast did arrive it has already recorded the same thing.
      this.settleSync(result)
      this.renderSyncedAt()
      if (!this.syncSettled) this.setSyncStatus(describeFinishedSync(result))
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
    if (!this.hasSyncStatusTarget) return

    this.syncStatusTarget.textContent = text || ""
    this.syncStatusTarget.hidden = !text
  }

  renderAutoSync() {
    if (!this.hasAutoSyncTarget) return

    // The switch beside this already says whether it is on, so this line carries the one
    // thing the switch cannot: how often.
    if (!this.autoSyncValue) {
      this.autoSyncTarget.textContent = "Automatic syncing is off"
      return
    }

    if (!this.autoSyncOn()) {
      this.autoSyncTarget.textContent = "Off for this device"
      return
    }

    this.autoSyncTarget.textContent = this.syncIntervalValue > 0
      ? `Every ${formatInterval(this.syncIntervalValue)}`
      : "On"
  }

  renderSyncedAt() {
    if (!this.hasSyncedAtTarget) return

    const stamp = this.store.number(this.store.keys.syncedAt)
    const synced = stamp
      ? `Synced ${formatCachedAt(Math.floor(stamp / 1000))}`
      : "Never synced"
    const next = this.describeNextSync()

    this.syncedAtTarget.textContent = next ? `${synced} · ${next}` : synced
    this.syncedAtTarget.title = stamp ? new Date(stamp).toLocaleString() : ""
  }

  // MARK: whole archives

  archiveRows() {
    if (!this.hasArchivesTarget) return []

    return [ ...this.archivesTarget.querySelectorAll("[data-archive-url]") ]
  }

  async renderArchives() {
    for (const row of this.archiveRows()) {
      let status = null

      try {
        status = await sendToWorker("archiveStatus", { url: row.dataset.archiveUrl }, 15000)
      } catch {
        // No worker yet. The row still names the file and offers the button.
      }

      renderArchiveStatus(row, status)
    }
  }

  archiveRow(url) {
    return this.archiveRows().find((row) => row.dataset.archiveUrl === url)
  }

  async downloadArchive(event) {
    event.preventDefault()

    const url = event.currentTarget.dataset.url
    const row = this.archiveRow(url)
    toggleArchiveBusy(row, true)

    try {
      const result = await sendToWorker("archiveDownload", { url }, 60 * 60 * 1000)
      if (result && result.ok === false) {
        this.setStatus(result.offline ? "No connection — the download will resume when there is one." : (result.error || "Download failed"))
      }
    } catch (error) {
      this.setStatus(error.message || "Download failed")
    } finally {
      toggleArchiveBusy(row, false)
      await this.renderArchives()
      await this.renderCache()
    }
  }

  async removeArchive(event) {
    event.preventDefault()

    const url = event.currentTarget.dataset.url
    if (!window.confirm("Delete this download? It will have to be downloaded again to work offline.")) return

    try {
      await sendToWorker("archiveRemove", { url }, 60000)
      this.setStatus("Deleted.")
    } catch (error) {
      this.setStatus(error.message || "Could not remove it")
    } finally {
      await this.renderArchives()
      await this.renderCache()
    }
  }

  handleArchiveMessage(event) {
    const data = event.data
    if (!data || data.type !== "coldwire:archive") return

    const row = this.archiveRow(data.url)
    if (!row) return

    if (data.state === "progress") {
      renderArchiveProgress(row, data.done, data.total)
    } else if (data.state === "finished") {
      toggleArchiveBusy(row, false)
      this.renderArchives()
    }
  }

  // A page that shows a countdown had better act on it. Two clocks disagreeing left the page
  // saying "due now" with nothing scheduled to do anything about it, so the countdown reaching
  // zero *is* what starts the sync here.
  tick() {
    this.renderSyncedAt()

    if (!this.autoSyncOn() || this.syncIntervalValue <= 0) return
    if (this.syncRunning || this.syncStarting) return
    // Nothing to do out of sight, and nothing worth doing with no network.
    if (document.hidden || this.syncPaused()) return
    if (Date.now() < this.dueAt()) return

    this.syncNow()
  }

  // When a sync is next owed. Reads the same keys the head snippet writes, so opening this
  // page never resets a clock that was already running.
  dueAt() {
    const stamp = this.store.number(this.store.keys.syncedAt)

    return Math.max(
      stamp ? stamp + this.syncIntervalValue * 1000 : 0,
      // Set only when a run was refused outright, which leaves the clock untouched and the
      // deadline in the past. Held here rather than in storage: it is this page pacing itself,
      // not a decision the rest of the app should inherit.
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

    return this.store.on(this.store.keys.forced)
  }

  describeNextSync() {
    if (!this.autoSyncOn() || this.syncIntervalValue <= 0) return ""
    if (this.syncRunning) return "syncing now"

    const paused = this.syncPaused()
    if (paused) {
      return paused === "forced" ? "paused, force offline is on" : "paused, no connection"
    }

    const seconds = Math.ceil((this.dueAt() - Date.now()) / 1000)

    return seconds > 0 ? `next in ${formatDuration(seconds)}` : "due now"
  }

  async refresh(event) {
    event?.preventDefault()
    this.setRefreshing(true)

    try {
      this.renderAutoSync()
      this.renderSyncedAt()

      // What this page can answer by itself comes first: the cache is read directly and the
      // probe is one request. Behind the worker questions they waited out a registration that
      // may never arrive, and the page sat on "Checking…" with an empty list.
      await this.renderCache()
      await this.renderConnection()

      await this.syncForcedToWorker()
      await this.catchUpOnSync()
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
    this.store.toggle(this.store.keys.forced, enabled)
    this.renderConnection()
    // The countdown means something different the instant this changes; do not make the user
    // wait a tick to see it.
    this.renderSyncedAt()
    // And anything watching Coldwire.onChange — a map holding remote tile sources, say —
    // hears about it without waiting for a navigation.
    document.dispatchEvent(new CustomEvent("coldwire:change", {
      detail: { offline: enabled, forced: enabled, cachedAt: null }
    }))

    try {
      await sendToWorker("setForcedOffline", { value: enabled }, 5000)
      this.setStatus(enabled ? "Forced offline is on. Requests will use the cache only." : "Forced offline is off.")
    } catch (error) {
      this.setStatus(error.message || "Could not update offline mode")
    }
  }

  restoreForced() {
    if (!this.hasForcedToggleTarget) return
    this.forcedToggleTarget.checked = this.store.on(this.store.keys.forced)
  }

  // Automatic syncing, as this device has it. The config decides whether it is on offer at
  // all; this decides whether it happens, and is remembered per device rather than per page.
  autoSyncOn() {
    return this.autoSyncValue && !this.store.on(this.store.keys.syncOff)
  }

  restoreAutoSync() {
    if (!this.hasAutoSyncToggleTarget) return
    this.autoSyncToggleTarget.checked = this.autoSyncOn()
  }

  toggleAutoSync(event) {
    this.store.toggle(this.store.keys.syncOff, !event.currentTarget.checked)

    // Say so at once rather than on the next tick: the line above the switch and the
    // countdown beside it both mean something different now.
    this.renderAutoSync()
    this.renderSyncedAt()
    this.setStatus(this.autoSyncOn()
      ? "Automatic syncing is on for this device."
      : "Automatic syncing is off for this device. Sync now still works.")

    // Turning it back on with the clock already past due should sync, not wait out an
    // interval that expired while it was off.
    if (this.autoSyncOn()) this.tick()
  }

  async syncForcedToWorker() {
    if (!this.hasForcedToggleTarget) return
    try {
      await sendToWorker("setForcedOffline", { value: this.forcedToggleTarget.checked }, 5000)
    } catch {
      // Worker may not be controlling yet; the checkbox still reflects local state.
    }
  }

  // Ask the server, always. navigator.onLine answers "is an interface up", which in a web view
  // is unreliable both ways — true with the server stopped, sometimes false while everything
  // works. One HEAD to the health check is cheap and it is the truth.
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
    const entries = cachesInfo.flatMap((cache) =>
      (cache.entries || []).map((entry) => ({ ...entry, cache: cache.name })))
    const totalBytes = entries.reduce((sum, entry) => sum + (entry.size || 0), 0)

    if (this.hasSummaryTarget) {
      const cacheCount = cachesInfo.length
      const urlCount = entries.length
      // This lists every cache the origin has, not only ours, and a URL held in two of them
      // is two rows that read as one page cached twice. Bumping cache_name leaves the old
      // one behind, so say when there is more than one rather than leaving the duplicate
      // unexplained.
      const spread = cacheCount > 1 ? ` · in ${cacheCount} caches` : ""
      this.summaryTarget.textContent = urlCount === 0
        ? "Nothing cached"
        : `${urlCount} file${urlCount === 1 ? "" : "s"} cached · ${formatBytes(totalBytes)}${spread}`
    }

    // Held so searching and sorting are pure display work. Reading the cache means asking
    // every entry for its headers, which is slow enough to feel broken if it happened on each
    // keystroke.
    this.entries = entries

    this.renderEntries()
  }

  filterEntries() {
    this.renderEntries()
  }

  renderEntries() {
    if (!this.hasEntriesTarget) return

    const entries = this.entries || []
    const query = this.hasSearchTarget ? this.searchTarget.value.trim().toLowerCase() : ""
    const matches = query
      ? entries.filter((entry) => displayUrl(entry.url).toLowerCase().includes(query))
      : entries

    this.entriesTarget.replaceChildren()

    if (matches.length === 0) {
      const empty = document.createElement("li")
      empty.className = "coldwire-empty"
      // Nothing cached and nothing matching are different problems, and the fix for each is
      // different too.
      empty.textContent = entries.length === 0 ? "None yet." : `No paths matching “${query}”.`
      this.entriesTarget.append(empty)
      return
    }

    this.sortEntries(matches).forEach((entry) => {
      const item = document.createElement("li")
      item.className = "coldwire-entry"

      const text = document.createElement("button")
      text.type = "button"
      text.className = "coldwire-entry-text"
      text.dataset.url = entry.url
      if (entry.cache) text.dataset.cache = entry.cache
      text.dataset.action = "click->coldwire-cache#showDetail"

      const path = document.createElement("div")
      path.className = "coldwire-entry-url"
      path.textContent = displayUrl(entry.url)
      path.title = entry.url

      const meta = document.createElement("div")
      meta.className = "coldwire-entry-meta"
      meta.textContent = entry.timestamp
        ? `${formatBytes(entry.size)} · ${formatCachedAt(entry.timestamp)}`
        : formatBytes(entry.size)
      if (entry.timestamp) meta.title = new Date(entry.timestamp * 1000).toLocaleString()

      text.append(path, meta)
      item.append(text)

      const forget = this.buildForgetButton(entry)
      if (forget) item.append(forget)

      this.entriesTarget.append(item)
    })
  }

  // A row can only ellipsise; the whole URL has to be readable somewhere, and this is it.
  showDetail(event) {
    event.preventDefault()

    const { url, cache } = event.currentTarget.dataset
    if (!url || !this.hasDetailTarget) return

    const entry = (this.entries || []).find((candidate) => candidate.url === url)

    if (this.hasDetailUrlTarget) this.detailUrlTarget.textContent = url
    if (this.hasDetailMetaTarget) {
      this.detailMetaTarget.textContent = entry ? describeEntry(entry) : ""
    }
    if (this.hasDetailForgetTarget) {
      // The same handler the row button uses, so there is one way to remove an entry.
      this.detailForgetTarget.dataset.url = url
      if (cache) this.detailForgetTarget.dataset.cache = cache
      this.detailForgetTarget.disabled = false
    }

    if (typeof this.detailTarget.showModal === "function") {
      this.detailTarget.showModal()
    } else {
      // No <dialog> support: still show it, just without the backdrop and focus handling.
      this.detailTarget.setAttribute("open", "")
    }
  }

  closeDetail() {
    if (!this.hasDetailTarget) return

    if (typeof this.detailTarget.close === "function") {
      this.detailTarget.close()
    } else {
      this.detailTarget.removeAttribute("open")
    }
  }

  // A modal <dialog> is supposed to close itself on Escape, and mostly does — but it depends
  // on the browser firing `cancel`, which is not something to rest a way out of a modal on.
  // Checking the key here rather than with Stimulus's `keydown.esc` filter keeps this working
  // on older Stimulus too.
  closeDetailOnEscape(event) {
    if (event.key !== "Escape") return

    event.preventDefault()
    this.closeDetail()
  }

  // A modal dialog fills the viewport with its backdrop, so a click outside the panel still
  // lands on the dialog itself. Anything inside stops at the child that was clicked.
  closeDetailOnBackdrop(event) {
    if (event.target === this.detailTarget) this.closeDetail()
  }

  buildForgetButton(entry) {
    if (!this.hasForgetTemplateTarget) return null

    const button = this.forgetTemplateTarget.content.firstElementChild.cloneNode(true)
    button.dataset.url = entry.url
    if (entry.cache) button.dataset.cache = entry.cache
    // Unlabelled but for its shape, and there is one per row — so the path goes in the label
    // rather than a bare "Remove", which would read as a column of identical buttons.
    button.setAttribute("aria-label", `Delete ${displayUrl(entry.url)} from the cache`)
    button.title = "Delete from the cache"

    return button
  }

  // No confirmation: one entry is a small, self-repairing loss, since anything the manifest
  // lists comes back on the next sync. Reached from the row's icon and the dialog alike.
  async forgetEntry(event) {
    event.preventDefault()

    const button = event.currentTarget
    const { url, cache } = button.dataset
    if (!url) return

    button.disabled = true

    try {
      await this.forgetUrl(url, cache)
      // Whether this came from the row or the dialog, the entry it was describing is gone.
      this.closeDetail()
      this.setStatus(`Deleted ${displayUrl(url)}.`)
      await this.renderCache()
    } catch (error) {
      button.disabled = false
      this.setStatus(error.message || "Could not delete that entry")
    }
  }

  async forgetUrl(url, name) {
    // The page can reach the cache directly, exactly as listing does — but only when the row
    // knew which cache it came from. Guessing a name would silently delete nothing, so with
    // no name the worker decides: it is the one that knows what it configured.
    if (name && "caches" in window) {
      const cache = await caches.open(name)
      await cache.delete(new Request(url), { ignoreVary: true, ignoreSearch: true })
      return
    }

    await sendToWorker("forget", { url, cache: name }, 5000)
  }

  // Sorted on a copy: `entries` is the cache as it was read, and re-sorting it in place would
  // make the order depend on whatever was picked last.
  sortEntries(entries) {
    const byPath = (a, b) => displayUrl(a.url).localeCompare(displayUrl(b.url))
    const order = this.hasSortTarget ? this.sortTarget.value : "recent"

    if (order === "alphabetical") return entries.slice().sort(byPath)

    if (order === "largest") {
      return entries.slice().sort((a, b) => (b.size || 0) - (a.size || 0) || byPath(a, b))
    }

    // Newest first, and paths alphabetically within a second — a sync stamps everything it
    // fetched at almost the same moment, so without the tiebreak the order looks arbitrary
    // and shuffles between renders.
    return entries.slice().sort((a, b) => (b.timestamp || 0) - (a.timestamp || 0) || byPath(a, b))
  }

  async listCaches() {
    if ("caches" in window) {
      const names = await caches.keys()
      const result = []
      for (const name of names) {
        const cache = await caches.open(name)
        const keys = await cache.keys()

        // In lanes rather than one at a time. Every entry costs a `match`, and the ones with
        // no Content-Length — proxied images, anything streamed — cost a body read on top, so
        // a cache of a few hundred spent that serially and the list sat there empty.
        const entries = new Array(keys.length)
        const queue = keys.map((request, index) => ({ request, index }))
        const lanes = Math.min(8, Math.max(1, queue.length))

        await Promise.all(Array.from({ length: lanes }, async () => {
          while (queue.length) {
            const { request, index } = queue.shift()
            const response = await cache.match(request, { ignoreVary: true })
            entries[index] = await describeCached(request, response)
          }
        }))

        result.push({ name, entries })
      }
      return result
    }

    const response = await sendToWorker("listCache", {}, 5000)
    return response.caches || []
  }

  async clearCaches() {
    if ("caches" in window) {
      const names = await caches.keys()
      await Promise.all(names.map((name) => caches.delete(name)))
      sendToWorker("clearCache", {}, 5000).catch(() => {})
      return { ok: true, cleared: names.length }
    }

    return sendToWorker("clearCache", {}, 5000)
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
