package dev.lidrop

import android.content.Context
import android.os.Build
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.launch
import org.json.JSONObject
import java.io.BufferedInputStream
import java.io.BufferedOutputStream
import java.io.DataInputStream
import java.io.DataOutputStream
import java.net.InetSocketAddress
import java.net.Socket
import java.util.UUID
import java.util.concurrent.atomic.AtomicInteger

const val DEMO_MAC_IP = "10.198.144.176"
const val PORT = 7777

const val DENIED = "Not allowed on the computer"

sealed interface Conn {
    data object Idle : Conn
    data object Connecting : Conn
    data class Up(val mac: String) : Conn
    data class Failed(val msg: String) : Conn
}

sealed interface MacEvent {
    data class Saved(val id: String, val path: String, val index: Int = 0) : MacEvent
    data class Error(val id: String?, val msg: String) : MacEvent
}

/** Plain-socket client speaking docs/PROTOCOL.md framing: u32 BE len · u8 type · payload. */
class MacClient(ctx: Context, private val scope: CoroutineScope, private val role: String = "main") {
    private val prefs = ctx.getSharedPreferences("lidrop", 0)
    private val _conn = MutableStateFlow<Conn>(Conn.Idle)
    val conn: StateFlow<Conn> = _conn
    val wantBlock = AtomicInteger(-1) // block the Mac's player is waiting for
    @Volatile var pingAt = 0L  // connect ceremony: when the last ping left
    @Volatile var pairRtt = 0L // and the fastest answer, in ms
    private val _ticket = MutableStateFlow(prefs.getString("ticket", null))
    val ticket: StateFlow<String?> = _ticket
    private val deviceId = prefs.getString("id", null) ?: UUID.randomUUID().toString().also { prefs.edit().putString("id", it).apply() }

    fun token(): String = prefs.getString("token", "") ?: ""

    fun saveTicket(t: String) {
        prefs.edit().putString("ticket", t).apply()
        _ticket.value = t
    }

    private val _events = MutableSharedFlow<MacEvent>(extraBufferCapacity = 16)
    val events: SharedFlow<MacEvent> = _events

    @Volatile var rx: Rx? = null
    @Volatile private var socket: Socket? = null
    @Volatile private var out: DataOutputStream? = null
    private val lock = Any()

    fun connect(addr: String, port0: Int = PORT) {
        val ip = addr.substringBeforeLast(":", addr).trim()
        val port = if (addr.count { it == ':' } == 1) addr.substringAfter(":").trim().toIntOrNull() ?: port0 else port0
        disconnect()
        _conn.value = Conn.Connecting
        scope.launch(Dispatchers.IO) {
            val s = Socket()
            try {
                s.connect(InetSocketAddress(ip.trim(), port), 1500)
                s.tcpNoDelay = true
                s.sendBufferSize = 1024 * 1024
                socket = s
                out = DataOutputStream(BufferedOutputStream(s.getOutputStream(), 128 * 1024))
                // a tunnel whose far end is unreachable stays silent: give up on it rather than hang
                s.soTimeout = if (ip == "127.0.0.1") 12_000 else 0
                sendJson(JSONObject().put("t", "hello").put("name", Build.MODEL).put("v", 0).put("id", deviceId).put("role", role).put("token", prefs.getString("token", "")))
                readLoop(s, DataInputStream(BufferedInputStream(s.getInputStream(), 1024 * 1024)))
                if (socket === s) _conn.value = Conn.Failed("Mac closed the connection")
            } catch (e: Exception) {
                if (socket === s || socket == null) {
                    _conn.value = Conn.Failed(e.message ?: e.javaClass.simpleName)
                }
            } finally {
                runCatching { s.close() }
                if (socket === s) { socket = null; out = null }
                rx?.onDisconnected()
            }
        }
    }

    fun disconnect() {
        val s = socket
        socket = null
        out = null
        runCatching { s?.close() }
        _conn.value = Conn.Idle
    }

    private fun readLoop(s: Socket, inp: DataInputStream) {
        while (true) {
            val len = inp.readInt()
            val type = inp.readUnsignedByte()
            val payload = ByteArray(len - 1)
            inp.readFully(payload)
            if (type != 1) { rx?.onChunk(payload); continue }
            val j = JSONObject(String(payload, Charsets.UTF_8))
            when (j.optString("t")) {
                "welcome" -> {
                    j.optJSONArray("screen_mm")?.let { Seam.macW = it.optDouble(0, 300.0).toFloat(); Seam.macH = it.optDouble(1, 195.0).toFloat() }
                    j.optString("token").takeIf { it.isNotEmpty() }?.let { prefs.edit().putString("token", it).apply() }
                    j.optString("edge").takeIf { it.isNotEmpty() }?.let { Seam.macEdge = it; prefs.edit().putString("edge", it).apply() }
                    pairRtt = 0
                    s.soTimeout = 0
                    _conn.value = Conn.Up(j.optString("name", "Mac"))
                    j.optString("ticket").takeIf { it.isNotEmpty() }?.let { saveTicket(it) }
                }
                "ticket" -> saveTicket(j.optString("ticket"))
                "want" -> wantBlock.set(j.optInt("block", -1))
                "pair" -> if (j.optString("state") == "pong") {
                    val rtt = android.os.SystemClock.uptimeMillis() - pingAt
                    if (pairRtt == 0L || rtt < pairRtt) pairRtt = rtt
                }
                "denied" -> throw java.io.IOException(DENIED)
                "saved" -> _events.tryEmit(MacEvent.Saved(j.optString("id"), j.optString("path"), j.optInt("index", 0)))
                "error" -> {
                    val id = j.optString("id").takeIf { it.isNotEmpty() && it != "null" }
                    rx?.onMacError(id)
                    _events.tryEmit(MacEvent.Error(id, j.optString("msg")))
                }
                else -> rx?.onJson(j)
            }
        }
    }

    fun sendJson(o: JSONObject) {
        val b = o.toString().toByteArray(Charsets.UTF_8)
        frame(1, b, b.size)
    }

    fun sendRaw(buf: ByteArray, n: Int) = frame(1, buf, n)

    fun sendChunk(buf: ByteArray, n: Int) = frame(2, buf, n)

    fun sendBlock(buf: ByteArray, n: Int) = frame(3, buf, n)

    private fun frame(type: Int, buf: ByteArray, n: Int) {
        val o = out ?: throw java.io.IOException("not connected")
        try {
            synchronized(lock) {
                o.writeInt(n + 1)
                o.writeByte(type)
                o.write(buf, 0, n)
                o.flush()
            }
        } catch (e: java.io.IOException) {
            runCatching { socket?.close() }
            throw e
        }
    }
}
