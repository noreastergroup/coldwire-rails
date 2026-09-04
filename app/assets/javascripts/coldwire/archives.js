// The download rows: what each one says, and what it looks like mid-download.

export function renderArchiveStatus(row, status) {
  const label = row.querySelector("[data-archive-status]")
  const download = row.querySelector("[data-archive-download-label]")
  const remove = row.querySelector("[data-archive-remove]")

  if (!status || !status.ok) {
    label.textContent = "Not downloaded"
    remove.hidden = true
    download.textContent = "Download"
    return
  }

  remove.hidden = status.chunks === 0
  download.textContent = status.complete ? "Download again" : status.chunks ? "Resume" : "Download"

  if (status.complete) {
    label.textContent = status.cachedAt
      ? `${formatBytes(status.bytes)} · downloaded ${formatCachedAt(status.cachedAt)}`
      : `${formatBytes(status.bytes)} · on this device`
  } else if (status.chunks) {
    // Partly downloaded is worth saying plainly: it is not broken, it stopped, and asking
    // again carries on from there.
    const share = status.expected ? Math.round((status.chunks / status.expected) * 100) : null
    const stopped = status.cachedAt ? `, stopped ${formatCachedAt(status.cachedAt)}` : ""
    label.textContent = share
      ? `${formatBytes(status.bytes)} of ${formatBytes(status.total)} · ${share}%${stopped}`
      : `${formatBytes(status.bytes)} downloaded · not finished${stopped}`
  } else {
    label.textContent = "Not downloaded"
  }
}
export function renderArchiveProgress(row, done, total) {
  const progress = row.querySelector("[data-archive-progress]")
  const bar = row.querySelector("[data-archive-bar]")
  const label = row.querySelector("[data-archive-progress-label]")

  progress.hidden = false
  const percent = total ? Math.round((done / total) * 100) : 0
  bar.style.width = `${percent}%`
  bar.classList.remove("coldwire-pulse")
  progress.setAttribute("aria-valuenow", String(percent))
  label.textContent = `${done} of ${total} pieces`
}
export function toggleArchiveBusy(row, busy) {
  row.querySelector("[data-archive-spinner]").hidden = !busy
  row.querySelectorAll("button").forEach((button) => { button.disabled = busy })
  if (!busy) row.querySelector("[data-archive-progress]").hidden = true
}
