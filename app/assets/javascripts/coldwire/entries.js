// Wording for the cached list and for a finished sync.

export function describeEntry(entry) {
  const parts = [ formatBytes(entry.size) ]
  if (entry.timestamp) parts.push(`cached ${formatCachedAt(entry.timestamp)}`)
  if (entry.cache) parts.push(`in “${entry.cache}”`)

  return parts.join(" · ")
}
export async function describeCached(request, response) {
  const seconds = Number(request.headers.get(TIMESTAMP_HEADER))

  return {
    url: request.url,
    size: await entrySize(response),
    timestamp: Number.isFinite(seconds) && seconds > 0 ? seconds : null
  }
}
export function describeFinishedSync(data) {
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
