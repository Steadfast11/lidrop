package dev.lidrop

import android.content.Context
import android.graphics.Bitmap
import android.os.SystemClock
import android.util.Log
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withTimeoutOrNull
import org.json.JSONObject
import androidx.compose.runtime.withFrameMillis
import kotlin.math.roundToInt
import java.io.FileInputStream
import java.nio.ByteBuffer
import java.util.UUID

enum class Side(val wire: String) { LEFT("left"), RIGHT("right"), TOP("top"), BOTTOM("bottom") }

const val TAG = "lidrop"
const val CHUNK = 256 * 1024
const val TILE_DP = 192
private const val REACH = 1.8f

class ActiveDrag(val items: List<Item>, val bmp: Bitmap?, val id: String, val startScale: Float) {
    val item get() = items.first()
    var extras by mutableStateOf<List<Bitmap>>(emptyList()) // the next files of a group, fanned out behind the first
    // read only inside graphicsLayer / draw lambdas, so a move never recomposes anything
    var x by mutableFloatStateOf(0f)
    var y by mutableFloatStateOf(0f)
    var glow by mutableFloatStateOf(0f)
    var side by mutableStateOf(Side.LEFT)
    // read by the sender thread
    @Volatile var alongQ = 0   // along * 10000, rounded
    @Volatile var overhangQ = 0
    @Volatile var sideWire = "left"
    @Volatile var overhang = 0f
    var t0 = 0L
    var lastMove = 0L
    var lastFx = 0f
    var lastFy = 0f
    var vx = 0f // finger speed, px/ms
    var vy = 0f
    var flung = false
    var f0x = 0f; var f0y = 0f // where the finger picked it up
    val end = CompletableDeferred<Boolean?>() // true = release, null = cancel
}

class DragController(
    private val ctx: Context,
    private val client: MacClient,
    private val scope: CoroutineScope,
    val tilePx: Float,
    private val edgeSlackPx: Float,
) {
    var drag by mutableStateOf<ActiveDrag?>(null)
    val light = FxState()
    var pending by mutableStateOf<Set<android.net.Uri>>(emptySet()) // being sent: their cells show a dashed slot
    var lifting by mutableStateOf<Set<android.net.Uri>>(emptySet()) // a group in the hand: its tiles have left the grid
    var linger by mutableStateOf<ActiveDrag?>(null) // tile kept on screen for the burst after a committed drop
    var toast by mutableStateOf<String?>(null)
    var screenW = 1f
    var screenH = 1f
    private var toastGen = 0
    private var lastSide = Side.LEFT

    /** One TCP stream: a new drag_start while a file is streaming would interleave with it, so wait. */
    var sending by mutableStateOf(false)
    private var expectSaved = 0
    private var savedCount = 0

    private var wasUp = false

    /** The link dropped: abandon any drag / transfer in flight and say so instead of leaving "Sending…" up. */
    private fun onLinkLost(quiet: Boolean) {
        val wasSending = sending
        drag?.end?.complete(null); drag = null
        if (light.running) fadeOutFx()
        sending = false; expectSaved = 0; pending = emptySet()
        lifting = emptySet()
        if (wasSending && !quiet) showToast("Send failed", ms = 4000)
    }

    init {
        scope.launch {
            client.conn.collect { c ->
                val up = c is Conn.Up
                if (wasUp && !up) onLinkLost(c is Conn.Idle) // Idle: we let go ourselves, nothing was lost
                wasUp = up
            }
        }
        scope.launch {
            client.events.collect {
                Log.d(TAG, "mac event $it")
                when (it) {
                    is MacEvent.Saved -> {
                        if (expectSaved > 1) {
                            savedCount++
                            if (savedCount >= expectSaved) { expectSaved = 0; pending = emptySet() }
                        } else { expectSaved = 0; pending = emptySet() }
                    }
                    is MacEvent.Error -> { pending = emptySet(); showToast("Mac: ${it.msg}") }
                }
            }
        }
    }

    var toastLabel by mutableStateOf<String?>(null)
    var toastAction: (() -> Unit)? = null
    var receiver: Receiver? = null

    fun showToast(s: String, label: String? = null, ms: Long = 2200, action: (() -> Unit)? = null) {
        toast = s; toastLabel = label; toastAction = action
        val g = ++toastGen
        scope.launch { delay(ms); if (g == toastGen) { toast = null; toastLabel = null } }
    }

    fun start(items: List<Item>, bmp: Bitmap?, fx: Float, fy: Float, cellPx: Float) {
        if (sending) { showToast("Still sending — wait for ✓"); return }
        if (receiver?.busy == true) { showToast("Receiving from Mac…"); return }
        if (client.conn.value !is Conn.Up) { showToast("Open lidrop on your computer"); return }
        val a = ActiveDrag(items, bmp, UUID.randomUUID().toString(), (cellPx / tilePx).coerceIn(0.2f, 1f))
        a.t0 = SystemClock.uptimeMillis()
        Log.d(TAG, "FIRE ${items.size} item(s) first=${items[0].name} video=${items[0].isVideo} bmp=${bmp != null}")
        a.side = lastSide
        a.sideWire = lastSide.wire
        linger = null
        light.strong = false
        light.begin(lastSide)
        a.f0x = fx; a.f0y = fy
        drag = a
        if (items.size > 1) {
            lifting = items.map { it.uri }.toSet()
            scope.launch(Dispatchers.IO) { a.extras = items.drop(1).take(2).mapNotNull { thumbnail(ctx, it) } }
        }
        move(fx, fy)
        scope.launch(Dispatchers.IO) { run(a) }
    }

    /**
     * Tile position for a finger at (fx, fy), allocation-free. Per axis, near a screen edge the finger's anchor
     * slides to the tile's trailing end (+e) so the tile leaves the screen (overhang 1 at distance e) while the
     * finger stays on screen. The reported edge is the one with the largest overhang, with hysteresis.
     */
    fun move(fx: Float, fy: Float) {
        val a = drag ?: return
        // wherever it was picked up, the tile waits in the middle of the screen: from there every direction is as clear,
        // and the finger moves it relatively, a little faster, so an edge is in reach from any corner of the grid
        place(screenW / 2 + (fx - a.f0x) * REACH, screenH / 2 + (fy - a.f0y) * REACH)
    }

    private fun place(fx: Float, fy: Float) {
        val a = drag ?: return
        val now = SystemClock.uptimeMillis()
        if (a.lastMove != 0L && now - a.lastMove > 40) Log.d(TAG, "MAIN-GAP ${now - a.lastMove}ms at ($fx,$fy)")
        val gap = (now - a.lastMove).toFloat()
        if (a.lastMove != 0L && gap > 0f) {
            a.vx += ((fx - a.lastFx) / gap - a.vx) * 0.5f
            a.vy += ((fy - a.lastFy) / gap - a.vy) * 0.5f
        }
        a.lastFx = fx; a.lastFy = fy
        a.lastMove = now
        val w = tilePx; val e = edgeSlackPx; val sw = screenW; val sh = screenH
        val rx = minOf(2 * w, 0.45f * sw); val ry = minOf(2 * w, 0.45f * sh)
        val k = w / 2 + e
        val tl = ((rx - fx) / (rx - e)).coerceIn(0f, 1f); val tr = ((rx - (sw - fx)) / (rx - e)).coerceIn(0f, 1f)
        val tt = ((ry - fy) / (ry - e)).coerceIn(0f, 1f); val tb = ((ry - (sh - fy)) / (ry - e)).coerceIn(0f, 1f)
        val left = fx - (w / 2 + k * tl - k * tr)
        val top = fy - (w / 2 + k * tt - k * tb)
        val oL = (-left / w).coerceIn(0f, 1f); val oR = ((left + w - sw) / w).coerceIn(0f, 1f)
        val oT = (-top / w).coerceIn(0f, 1f); val oB = ((top + w - sh) / w).coerceIn(0f, 1f)
        var best = Side.LEFT; var bv = oL
        if (oR > bv) { best = Side.RIGHT; bv = oR }
        if (oT > bv) { best = Side.TOP; bv = oT }
        if (oB > bv) { best = Side.BOTTOM; bv = oB }
        val cur = a.side
        val cv = when (cur) { Side.LEFT -> oL; Side.RIGHT -> oR; Side.TOP -> oT; Side.BOTTOM -> oB }
        val side = if (bv <= 0f || best == cur || bv < cv + 0.15f) cur else best
        val ov = when (side) { Side.LEFT -> oL; Side.RIGHT -> oR; Side.TOP -> oT; Side.BOTTOM -> oB }
        val along = if (side == Side.LEFT || side == Side.RIGHT) fy / sh else fx / sw
        a.x = left; a.y = top; a.glow = ov
        light.over(ov); light.along = along; light.cx = left + w / 2; light.cy = top + w / 2
        if (side != light.side) light.side = side
        if (side != cur) { a.side = side; a.sideWire = side.wire }
        a.overhang = ov
        a.overhangQ = (ov * 10000f).roundToInt()
        a.alongQ = (along.coerceIn(0f, 1f) * 10000f).roundToInt()
    }

    fun end() {
        val d = drag ?: return
        // a throw: the finger let go early but the tile is flying, so it carries on through the edge on its own
        if (d.overhang < 0.5f && !d.flung && maxOf(kotlin.math.abs(d.vx), kotlin.math.abs(d.vy)) > 1.2f) {
            d.flung = true
            scope.launch {
                var fx = d.lastFx; var fy = d.lastFy; var last = withFrameMillis { it }
                repeat(24) {
                    val now = withFrameMillis { it }
                    fx += d.vx * (now - last); fy += d.vy * (now - last); last = now
                    if (drag === d) place(fx, fy)
                    if (d.overhang >= 0.6f) return@repeat
                }
                if (drag === d) end()
            }
            return
        }
        lastSide = d.side
        d.end.complete(true)
        drag = null
        lifting = emptySet()
        if (d.overhang >= 0.5f) {
            // commit: wrap + burst around the tile, which lingers at the edge while the Mac takes over
            linger = d
            pending = d.items.map { it.uri }.toSet()
            val g = light.commit()
            scope.launch { delay(light.endMs()); if (light.stillCurrent(g)) { light.running = false; linger = null } }
        } else fadeOutFx()
    }
    fun cancel() { drag?.end?.complete(null); drag = null; lifting = emptySet(); fadeOutFx() }

    private fun fadeOutFx() {
        val g = light.cancel()
        scope.launch { delay(650); if (light.stillCurrent(g)) light.running = false }
    }

    private suspend fun run(a: ActiveDrag) {
        fun el() = SystemClock.uptimeMillis() - a.t0
        try {
            Log.d(TAG, "RUN begin +${el()}ms")
            // never hold drag_start back for a thumbnail: wait at most 150 ms for it, then send without
            val bmp = a.bmp ?: withTimeoutOrNull(150) { thumbnail(ctx, a.item, 512) }
            Log.d(TAG, "thumb ready +${el()}ms (loaded=${a.bmp == null})")
            val th = thumbBase64(bmp)
            val dm = ctx.resources.displayMetrics
            val tileMm = (tilePx / dm.xdpi * 25.4f).toDouble()
            val screenWmm = (dm.widthPixels / dm.xdpi * 25.4f).toDouble()
            val screenHmm = (dm.heightPixels / dm.ydpi * 25.4f).toDouble()
            Log.d(TAG, "thumb encoded +${el()}ms len=${th.length}")
            client.sendJson(
                JSONObject().put("t", "drag_start").put("id", a.id).put("name", a.item.name)
                    .put("mime", a.item.mime).put("size", a.item.size)
                    .put("thumb", th).put("tile_dp", TILE_DP).put("count", a.items.size)
                    .put("files", org.json.JSONArray().also { arr -> a.items.forEach { arr.put(JSONObject().put("name", it.name).put("size", it.size).put("mime", it.mime)) } })
                    .put("tile_mm", tileMm).put("screen_mm", org.json.JSONArray().put(screenWmm).put(screenHmm))
            )
            Log.d(TAG, "drag_start sent +${el()}ms")
            var moves = 0
            // drag_move is built by hand into one reusable buffer: no JSONObject / String allocation per message
            val pre = "{\"t\":\"drag_move\",\"id\":\"${a.id}\",\"edge\":\"".toByteArray()
            val mAlong = "\",\"along\":".toByteArray()
            val mOver = ",\"overhang\":".toByteArray()
            val edgeBytes = Side.values().associateWith { it.wire.toByteArray() }
            val buf = ByteArray(pre.size + 96)
            fun put(p: Int, src: ByteArray): Int { System.arraycopy(src, 0, buf, p, src.size); return p + src.size }
            fun putQ(p0: Int, q: Int): Int {
                var p = p0
                if (q >= 10000) { buf[p++] = '1'.code.toByte(); buf[p++] = '.'.code.toByte(); buf[p++] = '0'.code.toByte(); return p }
                buf[p++] = '0'.code.toByte(); buf[p++] = '.'.code.toByte()
                var m = 1000
                var r = q
                while (m > 0) { buf[p++] = ('0'.code + r / m).toByte(); r %= m; m /= 10 }
                return p
            }
            var lastA = -1; var lastO = -1; var lastS = ""
            fun move(): Boolean {
                val al = a.alongQ; val ov = a.overhangQ; val sw = a.sideWire
                if (al == lastA && ov == lastO && sw == lastS) return false
                lastA = al; lastO = ov; lastS = sw
                var p = put(0, pre)
                p = put(p, edgeBytes.getValue(a.side))
                p = put(p, mAlong); p = putQ(p, al)
                p = put(p, mOver); p = putQ(p, ov)
                buf[p++] = '}'.code.toByte()
                client.sendRaw(buf, p)
                if (++moves == 1) Log.d(TAG, "first drag_move sent +${el()}ms")
                return true
            }
            var slow = 0
            while (!a.end.isCompleted && scope.isActive) {
                val t = SystemClock.uptimeMillis()
                if (move()) {
                    val dt = SystemClock.uptimeMillis() - t
                    if (dt > 30) { slow++; Log.d(TAG, "SLOW SEND ${dt}ms (move #$moves)") }
                }
                delay(8)
            }
            move()
            val commit = a.end.await() == true && a.overhang >= 0.5f
            Log.d(TAG, "drag_end commit=$commit moves=$moves slowSends=$slow +${el()}ms")
            client.sendJson(JSONObject().put("t", "drag_end").put("id", a.id).put("commit", commit))
            if (commit) {
                sending = true
                expectSaved = a.items.size; savedCount = 0
                try {
                    a.items.forEachIndexed { i, it ->
                        val begin = JSONObject().put("t", "file_begin").put("id", a.id).put("index", i)
                        if (a.items.size == 1 && it.isVideo && it.size > 0) {
                            client.sendJson(begin.put("stream", true).put("size", it.size).put("mime", it.mime))
                            sendBlocks(it)
                        } else {
                            client.sendJson(begin)
                            streamFile(it)
                        }
                        client.sendJson(JSONObject().put("t", "file_end").put("id", a.id).put("index", i))
                    }
                } finally { sending = false }
                scope.launch { Shared.items.removeAll(a.items.toSet()) }
            }
        } catch (e: Exception) {
            Log.e(TAG, "send failed", e)
            if (client.conn.value is Conn.Up) showToastMain("Send failed: ${e.message}") // else onLinkLost() already said so
        }
    }

    /** Reader and socket writer run as two pipelined coroutines on IO so disk reads never stall the socket. */
    private suspend fun streamFile(item: Item) = coroutineScope {
        val t0 = SystemClock.uptimeMillis()
        val ch = Channel<Pair<ByteArray, Int>>(4)
        var total = 0L
        var writeMs = 0L
        val reader = launch(Dispatchers.IO) {
            ctx.contentResolver.openInputStream(item.uri)?.use { s ->
                while (true) {
                    val buf = ByteArray(CHUNK)
                    var n = 0
                    while (n < buf.size) { val r = s.read(buf, n, buf.size - n); if (r < 0) break; n += r }
                    if (n == 0) break
                    ch.send(buf to n)
                    if (n < buf.size) break
                }
            }
            ch.close()
        }
        try {
            for ((buf, n) in ch) {
                if (client.conn.value !is Conn.Up) throw java.io.IOException("connection lost")
                val t = SystemClock.uptimeMillis()
                client.sendChunk(buf, n)
                writeMs += SystemClock.uptimeMillis() - t
                total += n
            }
        } finally { reader.cancel() }
        val ms = (SystemClock.uptimeMillis() - t0).coerceAtLeast(1)
        Log.d(TAG, "FILE sent $total bytes in ${ms}ms = ${"%.1f".format(total / 1048576.0 / (ms / 1000.0))} MB/s (socket write ${writeMs}ms)")
    }

    /**
     * A video goes as numbered blocks in file order, but the Mac's player can move the read position at any time
     * ("want"): camera videos keep their index at the end, and seeking must not wait for the whole file.
     */
    private fun sendBlocks(item: Item) {
        val t0 = SystemClock.uptimeMillis()
        val count = ((item.size + CHUNK - 1) / CHUNK).toInt()
        val sent = BooleanArray(count)
        var left = count
        var next = 0
        val buf = ByteArray(CHUNK + 4)
        val bb = ByteBuffer.wrap(buf)
        client.wantBlock.set(-1)
        val pfd = ctx.contentResolver.openFileDescriptor(item.uri, "r") ?: throw java.io.IOException("cannot open file")
        pfd.use {
            FileInputStream(it.fileDescriptor).channel.use { ch ->
                while (left > 0) {
                    if (client.conn.value !is Conn.Up) throw java.io.IOException("connection lost")
                    val w = client.wantBlock.getAndSet(-1)
                    if (w in 0 until count) next = w
                    while (sent[next]) next = (next + 1) % count
                    bb.clear()
                    bb.putInt(next)
                    var pos = next.toLong() * CHUNK
                    while (bb.hasRemaining()) { val r = ch.read(bb, pos); if (r < 0) break; pos += r }
                    client.sendBlock(buf, bb.position())
                    sent[next] = true
                    left--
                    next = (next + 1) % count
                }
            }
        }
        val ms = (SystemClock.uptimeMillis() - t0).coerceAtLeast(1)
        Log.d(TAG, "VIDEO sent ${item.size} bytes in ${ms}ms = ${"%.1f".format(item.size / 1048576.0 / (ms / 1000.0))} MB/s")
    }

    private fun showToastMain(s: String) { scope.launch { showToast(s) } }
}
