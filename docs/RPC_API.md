# DoubleCmdRPC API

All examples omit the transport LF terminator. Requests use JSON-RPC 2.0 and require an `id`:

```json
{"jsonrpc":"2.0","id":1,"method":"dc.ping","params":{},"timeout_ms":5000}
```

`timeout_ms` may be a top-level member or an object parameter. Its range is 1–300000 ms; the default is 5000 ms. GUI methods are marshalled to the Lazarus main thread. Standard errors include parse error `-32700`, invalid request `-32600`, method not found `-32601`, invalid params `-32602`, and internal error `-32603`. Service errors include timeout `-32001`, unavailable state/plugin `-32002`, and assertion-related failures in the `-32010` range.

Panel parameters accept `active`, `left`, or `right`. Unless noted, `panel` defaults to `active`.

## Double Commander methods

### `dc.ping`

No parameters. Returns service identity, PID, pipe name, and timestamp. This method does not touch GUI state.

### `dc.getInfo`

Returns Double Commander version/revision/commit, target, PID, pipe, uptime, and JSONL path.

### `dc.getState`

Returns active panel plus left/right panel state: directory, real directory, file source, view mode, tab index/count, loading/idle status, selected item, and selected files.

### `dc.navigate`

Parameters:

```json
{"panel":"left","path":"wfx://RemoteThumbnail/Pictures","activate":true,"test_id":"case-1","photo_uuid":"optional"}
```

`path` (or `remote_path`) is required. The implementation delegates to Double Commander's existing `ChooseFileSource`, so local and WFX URI behavior remains unchanged.

### `dc.setViewMode`

```json
{"panel":"left","mode":"thumbnails","activate":true}
```

`mode`: `details`/`columns`, `brief`, or `thumbnails`. Calling it with the current mode is idempotent and does not toggle away.

### `dc.refresh`

Queues a forced reload for the requested panel.

### `dc.getSelectedFiles`

Returns cloned selection entries (`name`, `path`, `full_path`, `is_directory`, `size`).

### `dc.waitForIdle`

Polls main-thread view state until both panels have no active file-view work, reload timer, pending-files timer, or queued request. Uses `timeout_ms`.

## Plug-in and WFX methods

### `plugin.getLoaded`

Returns configured WFX plug-ins and whether a matching module is already loaded. It never loads a plug-in as a side effect.

### `plugin.getExports`

```json
{"name":"RemoteThumbnailWFX"}
```

or select an already loaded module with `path`. Returns a fixed allow-list of WFX/optional diagnostics export-presence booleans, including `FsGetPreviewBitmapW` and `FsGetPreviewBitmap`. No arbitrary symbol name is accepted.

### `wfx.getStats`

Optional filters: `test_id`, `path`/`remote_path`, `photo_uuid`. Returns callback counts split by Unicode/ANSI entry, resolver query/hit/miss, plug-in cache hit/miss, enqueued thumbnail fetches, decode and HBITMAP return success/failure counts, host receipt, invalidation, UI draw, errors, latest source, and timing aggregates.

### `wfx.getLastCalls`

Same filters plus `limit` (1–1000). Returns newest-first WFX events with sequence, timestamp, test/call IDs, stage, path, duration, result, error, status code, and detail.

### `wfx.getErrors`

Same filters and limit. Returns newest-first error events across the correlated pipeline.

### `wfx.getConnectionState`

Optional panel selector. Reports whether that panel uses `IWfxPluginFileSource`, its root/module/load state, and a snapshot of pending preview paths. It does not claim protocol-level SFTP connectivity when that state is not observable.

## Thumbnail methods

### `thumbnail.getStats`

Alias of the correlated statistics query used by `wfx.getStats`.

### `thumbnail.getPending`

Returns paths whose latest relevant state is begun/missed and has not later reached success/draw or error.

### `thumbnail.invalidate`

```json
{"path":"\\Camera\\IMG_001.jpg"}
```

Invalidates the matching path in every open thumbnail view and clears its bounded in-memory native cache. Omit `path` to invalidate all. It never deletes RemoteThumbnailPC's content-addressed disk cache.

### `thumbnail.clearCache`

Same safe in-memory behavior as `thumbnail.invalidate` with no path. The result explicitly reports `disk_cache_deleted:false`.

### `thumbnail.waitForCompletion`

Waits for correlated preview success/error. At least one `test_id`, `path`, or `photo_uuid` filter is required. Set `require_draw:true` to require an observed paint.

## Test methods

### `test.openRemoteDirectory`

Equivalent to `dc.navigate`, but requires `test_id` and registers both the requested URI and resulting file-source path/UUID for correlation.

### `test.switchToThumbnailView`

Idempotently selects thumbnail mode. Optional `test_id` registration is retained for the current directory.

### `test.triggerPreview`

```json
{
  "test_id":"case-1",
  "panel":"left",
  "path":"\\Camera\\IMG_001.jpg",
  "photo_uuid":"uuid",
  "force":true
}
```

Requires an existing thumbnail view. With `force:true` (default), clears the item's current tag/cache entry, selects it, and queues visible display-property work.

### `test.waitForPreview`

Requires `test_id`, waits for completion, and requires a real `TThumbDrawGrid.DrawCell` bitmap paint by default. Set `require_draw:false` only when testing a non-visible pipeline stage.

### `test.assertPreviewSource`

Requires `test_id` and `source`, with optional path/UUID filters. Known observed labels include `wfx_hbitmap`, `wfx_local_file`, `wfx_provider`, and `host_native_cache`. Returns `passed`, expected, actual, and a stable failure code rather than fabricating source information.

### `test.getReport`

Requires `test_id`; accepts path/UUID filters and `event_limit`. Returns stage verdicts, statistics, and correlated events. Stable failure categories cover:

- `wfx_callback_not_triggered`
- `resolver_lookup_failed`
- `webp_file_missing`
- `webp_file_invalid`
- `webp_file_not_cached`
- `bitmap_decode_failed`
- `hbitmap_return_failed`
- `dc_host_not_received`
- `host_received_not_displayed`
- `thumbnail_cache_not_updated`

`visual_verified:true` means the host observed `Canvas.StretchDraw` for the target bitmap. This is stronger than callback receipt or redraw scheduling, but external screenshot/UI automation remains recommended for pixel-level acceptance.

## Logs

### `log.getRecent`

Parameters: optional `test_id`, `limit` (1–2000). Returns newest-first in-memory JSONL entries and the persisted log path.
