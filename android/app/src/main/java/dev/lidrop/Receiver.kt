package dev.lidrop

import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.net.Uri
import android.os.Build
import android.provider.MediaStore
import android.util.Base64
import android.util.Log
import androidx.compose.animation.core.animate
import androidx.compose.animation.core.tween
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import org.json.JSONObject
import java.io.OutputStream

data class FileMeta(val name: String, val size: Long, val mime: String)

/** Mac → phone tile currently shown on the phone. Fields are Compose state, read only in layer/draw lambdas. */
class Incoming(val id: String, val files: List<FileMeta>, val bmp: Bitmap?, val side: Side) {
    val count get() = files.size
    val totalSize = files.sumOf { maxOf(it.size, 0L) }
    var depth by mutableFloatStateOf(0f)   // fraction of the tile that is on screen (0..1)
    var along by mutableFloatStateOf(0.5f)
    var alpha by mutableFloatStateOf(1f)
    var received by mutableLongStateOf(0L) // bytes across all files
    var committed by mutableStateOf(false)
}

/** Called from the socket reader thread (already off the main thread), so file IO happens right here. */
interface Rx {
    fun onJson(j: JSONObject)
    fun onChunk(b: ByteArray)
    fun onDisconnected()
    fun onMacError(id: String?)
}

class Receiver(
    private val ctx: Context,
    private val scope: CoroutineScope,
    private val client: MacClient,
    private val ctrl: DragController,
) : Rx {
    var cur by mutableStateOf<Incoming?>(null)
    val fx = FxState()
    val busy get() = cur != null

    private var ignoredId: String? = null
    private var uri: Uri? = null
    private var out: OutputStream? = null
    private var fileReceived = 0L
    private var savedCount = 0

    private fun opposite(macEdge: String) = when (macEdge) {
        "left" -> Side.RIGHT; "top" -> Side.BOTTOM; "bottom" -> Side.TOP; else -> Side.LEFT
    }

    private fun parseFiles(j: JSONObject): List<FileMeta> {
        val arr = j.optJSONArray("files")
        if (arr != null && arr.length() > 0) {
            return (0 until arr.length()).map {
                val f = arr.getJSONObject(it)
                FileMeta(f.optString("name", "file"), f.optLong("size", -1), f.optString("mime", "application/octet-stream"))
            }
        }
        return listOf(FileMeta(j.optString("name", "file"), j.optLong("size", -1), j.optString("mime", "application/octet-stream")))
    }

    override fun onJson(j: JSONObject) {
        val id = j.optString("id")
        when (j.optString("t")) {
            "mdrag_start" -> {
                if (ctrl.drag != null || ctrl.sending || cur != null) { ignoredId = id; Log.d(TAG, "mdrag_start ignored (busy)"); return }
                ignoredId = null
                val bmp = runCatching {
                    val b = Base64.decode(j.optString("thumb"), Base64.DEFAULT)
                    BitmapFactory.decodeByteArray(b, 0, b.size)
                }.getOrNull()
                val files = parseFiles(j)
                Log.d(TAG, "mdrag_start ${files.size} file(s) first=${files[0].name} edge=${j.optString("edge")} thumb=${bmp != null}")
                savedCount = 0
                val side = opposite(j.optString("edge", "right"))
                cur = Incoming(id, files, bmp, side)
                fx.strong = true
                fx.begin(side)
            }
            "mdrag_move" -> cur?.takeIf { it.id == id }?.let {
                it.depth = j.optDouble("overhang", 0.0).toFloat().coerceIn(0f, 1f)
                it.along = j.optDouble("along", 0.5).toFloat().coerceIn(0f, 1f)
                fx.over(it.depth, 0.83f); fx.along = it.along
                fx.placeEntering(it.side, it.depth, it.along, ctrl.screenW, ctrl.screenH, ctrl.tilePx)
            }
            "mdrag_end" -> cur?.takeIf { it.id == id }?.let { inc ->
                if (j.optBoolean("commit")) {
                    inc.committed = true
                    fx.placeEntering(inc.side, 1f, inc.along, ctrl.screenW, ctrl.screenH, ctrl.tilePx)
                    val g = fx.commit()
                    scope.launch { delay(fx.endMs()); if (fx.stillCurrent(g)) fx.running = false }
                    scope.launch { animate(inc.depth, 1f, animationSpec = tween(150)) { v, _ -> inc.depth = v } }
                } else {
                    val g = fx.cancel()
                    scope.launch { delay(650); if (fx.stillCurrent(g)) fx.running = false }
                    scope.launch {
                        animate(inc.depth, 0f, animationSpec = tween(160)) { v, _ -> inc.depth = v }
                        if (cur === inc) cur = null
                    }
                }
            }
            "file_begin" -> {
                val inc = cur
                val index = j.optInt("index", 0)
                if (inc != null && inc.id == id && inc.committed) open(inc, index)
                else if (id == ignoredId) client.sendJson(JSONObject().put("t", "error").put("id", id).put("msg", "phone busy"))
            }
            "file_end" -> cur?.takeIf { it.id == id }?.let { finish(it, j.optInt("index", 0)) }
        }
    }

    override fun onChunk(b: ByteArray) {
        val o = out ?: return
        try { o.write(b); fileReceived += b.size; cur?.let { it.received += b.size } }
        catch (e: Exception) { fail(e.message ?: "write failed", 0) }
    }

    override fun onDisconnected() {
        abortFile()
        scope.launch { cur = null; fx.running = false }
    }

    /** The Mac gave up on what it was sending: the file is not coming, so the tile must not wait for it. */
    override fun onMacError(id: String?) {
        val inc = cur ?: return
        if (id != null && id != inc.id) return
        abortFile()
        scope.launch {
            val g = fx.cancel()
            launch { delay(650); if (fx.stillCurrent(g)) fx.running = false }
            animate(inc.depth, 0f, animationSpec = tween(160)) { v, _ -> inc.depth = v }
            if (cur === inc) cur = null
        }
    }

    private fun open(inc: Incoming, index: Int) {
        try {
            if (Build.VERSION.SDK_INT < 29) throw IllegalStateException("Android 10+ required to save")
            val meta = inc.files.getOrNull(index) ?: inc.files[0]
            val safe = meta.name.substringAfterLast('/').ifBlank { "file" }
            val cv = ContentValues().apply {
                put(MediaStore.Downloads.DISPLAY_NAME, safe)
                put(MediaStore.Downloads.MIME_TYPE, meta.mime)
                put(MediaStore.Downloads.RELATIVE_PATH, "Download/lidrop")
                put(MediaStore.Downloads.IS_PENDING, 1)
            }
            val u = ctx.contentResolver.insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, cv) ?: error("insert failed")
            uri = u
            fileReceived = 0
            out = java.io.BufferedOutputStream(ctx.contentResolver.openOutputStream(u) ?: error("open failed"), 256 * 1024)
            Log.d(TAG, "receiving [$index] ${meta.name} (${meta.size} bytes)")
        } catch (e: Exception) { fail(e.message ?: "cannot save", index) }
    }

    private fun finish(inc: Incoming, index: Int) {
        val u = uri
        try {
            out?.close(); out = null
            if (u == null) return
            val meta = inc.files.getOrNull(index) ?: inc.files[0]
            if (meta.size >= 0 && fileReceived != meta.size) throw IllegalStateException("size mismatch $fileReceived/${meta.size}")
            ctx.contentResolver.update(u, ContentValues().apply { put(MediaStore.Downloads.IS_PENDING, 0) }, null, null)
            val finalName = ctx.contentResolver.query(u, arrayOf(MediaStore.Downloads.DISPLAY_NAME), null, null, null)
                ?.use { if (it.moveToFirst()) it.getString(0) else null } ?: meta.name
            val path = "/storage/emulated/0/Download/lidrop/$finalName"
            Log.d(TAG, "saved [$index] $path ($fileReceived bytes)")
            client.sendJson(JSONObject().put("t", "saved").put("id", inc.id).put("index", index).put("path", path))
            uri = null
            savedCount++
            Shared.receivedTick++
            if (index >= inc.count - 1) done(inc, u, finalName, meta.mime)
        } catch (e: Exception) { fail(e.message ?: "save failed", index) }
    }

    private fun done(inc: Incoming, lastUri: Uri, lastName: String, mime: String) {
        scope.launch {
            if (inc.count == 1) {
                ctrl.showToast("Received ✓ $lastName", "Open", 6000) {
                    runCatching {
                        ctx.startActivity(
                            Intent(Intent.ACTION_VIEW).setDataAndType(lastUri, mime)
                                .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_ACTIVITY_NEW_TASK)
                        )
                    }.onFailure { ctrl.showToast("No app to open this file") }
                }
            } else {
                ctrl.showToast("Received ${inc.count} files ✓", "Show", 6000) { Shared.showReceived = true }
            }
            delay(400)
            animate(1f, 0f, animationSpec = tween(250)) { v, _ -> inc.alpha = v }
            if (cur === inc) cur = null
        }
    }

    private fun abortFile() {
        runCatching { out?.close() }; out = null
        uri?.let { runCatching { ctx.contentResolver.delete(it, null, null) } }; uri = null
    }

    private fun fail(msg: String, index: Int) {
        Log.w(TAG, "receive failed: $msg")
        val id = cur?.id
        abortFile()
        if (id != null) runCatching { client.sendJson(JSONObject().put("t", "error").put("id", id).put("index", index).put("msg", msg)) }
        scope.launch { ctrl.showToast("Receive failed: $msg"); cur = null }
    }
}

data class RecvFile(val uri: Uri, val name: String, val size: Long, val mime: String)

/** Last [limit] files in Download/lidrop (what this app received), newest first. */
fun queryReceived(ctx: Context, limit: Int = 20): List<RecvFile> {
    if (Build.VERSION.SDK_INT < 29) return emptyList()
    val res = ArrayList<RecvFile>()
    ctx.contentResolver.query(
        MediaStore.Downloads.EXTERNAL_CONTENT_URI,
        arrayOf(MediaStore.Downloads._ID, MediaStore.Downloads.DISPLAY_NAME, MediaStore.Downloads.SIZE, MediaStore.Downloads.MIME_TYPE),
        "${MediaStore.Downloads.RELATIVE_PATH} LIKE ? AND ${MediaStore.Downloads.IS_PENDING} = 0", arrayOf("Download/lidrop%"),
        "${MediaStore.Downloads.DATE_ADDED} DESC, ${MediaStore.Downloads._ID} DESC",
    )?.use { c ->
        while (c.moveToNext() && res.size < limit) {
            res += RecvFile(
                android.content.ContentUris.withAppendedId(MediaStore.Downloads.EXTERNAL_CONTENT_URI, c.getLong(0)),
                c.getString(1) ?: "file", c.getLong(2), c.getString(3) ?: "application/octet-stream",
            )
        }
    }
    return res
}
