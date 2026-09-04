// Wording for the cached list and for a finished sync.

import { formatBytes, formatCachedAt } from "coldwire/format"

// The worker stamps this on the request it stores under; the Cache API keeps no date
// of its own.
export const TIMESTAMP_HEADER = "timestamp"

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

// Headers before body: blob() on hundreds of entries makes listing the cache a multi-second
// job. Note that `get` answers null for a missing header and Number(null) is 0, which sailed
// through the guard and reported Active Storage's streamed blobs as empty.
async function entrySize(response) {
  if (!response) return 0

  const declared = response.headers.get("Content-Length")
  const bytes = declared === null ? NaN : Number(declared)
  if (Number.isFinite(bytes) && bytes >= 0) return bytes

  return (await response.clone().blob()).size
}
