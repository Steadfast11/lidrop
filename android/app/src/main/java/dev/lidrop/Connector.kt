package dev.lidrop

import android.content.Context
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.util.Log
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch

data class Found(val name: String, val host: String, val port: Int)

/**
 * Finds Macs advertising `_lidrop._tcp` with NsdManager (one resolve at a time), picks which one to connect to
 * (last-used if present, else the only one, else the user taps), and reconnects whenever the link is down.
 */
class Connector(private val ctx: Context, private val scope: CoroutineScope, val client: MacClient) {
    private val nsd = ctx.getSystemService(NsdManager::class.java)
    private val prefs = ctx.getSharedPreferences("lidrop", 0)

    private val _found = MutableStateFlow<List<Found>>(emptyList())
    val found: StateFlow<List<Found>> = _found
    private val _target = MutableStateFlow<String?>(null) // name (or IP) currently being connected to
    val target: StateFlow<String?> = _target

    @Volatile private var fixedHost: String? = null
    @Volatile private var foreground = false
    private var disc: NsdManager.DiscoveryListener? = null
    private val pending = ArrayDeque<NsdServiceInfo>()
    private var resolving = false

    init {
        scope.launch {
            client.conn.collect { c -> if (c is Conn.Up) _target.value?.let { if (fixedHost == null) prefs.edit().putString("lastName", it).apply() } }
        }
        scope.launch {
            client.conn.collect { if (it is Conn.Up) tunnelTries = 0 }
        }
        // the first pairing arrives over the LAN: move to the tunnel at once, it is the faster path
        scope.launch {
            client.ticket.collect { if (it != null && client.conn.value is Conn.Up && !viaTunnel && fixedHost == null) client.disconnect() }
        }
        scope.launch {
            while (true) { delay(700); if (foreground) evaluate() }
        }
    }

    private var viaTunnel = false
    private var tunnelTries = 0

    fun onForeground() { foreground = true; stopDiscovery(); startDiscovery(); evaluate() }
    fun onBackground() { foreground = false; stopDiscovery(); forgetRefusal() }

    /** Asks the computer again after it said no. */
    fun retry() { forgetRefusal(); evaluate() }

    private fun forgetRefusal() { if ((client.conn.value as? Conn.Failed)?.msg == DENIED) client.disconnect() }

    /** The phone's edge that faces the Mac, the opposite of the Mac edge it last told us. */
    fun seamSide(): Side = when (Seam.macEdge ?: prefs.getString("edge", null)) {
        "left" -> Side.RIGHT; "top" -> Side.BOTTOM; "bottom" -> Side.TOP; else -> Side.LEFT
    }

    fun connectManual(ip: String) {
        if (ip.trim().startsWith("endpoint")) { fixedHost = null; client.saveTicket(ip.trim()); return } // Mac's "Copy pairing code"
        fixedHost = ip.trim(); _target.value = ip.trim()
        prefs.edit().putString("ip", ip.trim()).apply()
        client.connect(ip)
    }

    private var failTicks = 0

    private fun evaluate() {
        val c = client.conn.value
        if (c is Conn.Up || c is Conn.Connecting) { failTicks = 0; return }
        if (c is Conn.Failed && c.msg == DENIED) return // asking again now would put the same question straight back on the computer
        // link is down: retry every tick; every ~3 s also restart NSD so a Mac that came back (maybe on a new address) is re-resolved
        if (++failTicks % 4 == 0) { stopDiscovery(clear = false); startDiscovery() }
        viaTunnel = false
        fixedHost?.let { client.connect(it); return }
        val list = _found.value
        val last = prefs.getString("lastName", null)
        val pick = list.firstOrNull { it.name == last } ?: list.singleOrNull()
        val ticket = client.ticket.value
        // the tunnel is preferred everywhere; the plain LAN path only covers a same-Wi-Fi network with no internet
        if (ticket != null && (pick == null || tunnelTries++ % 6 < 4)) {
            Tunnel.up(ctx, ticket)
            viaTunnel = true
            last?.let { _target.value = it }
            client.connect("127.0.0.1", Tunnel.LOCAL_PORT)
            return
        }
        pick ?: return
        _target.value = pick.name
        client.connect(pick.host, pick.port)
    }

    private fun startDiscovery() {
        if (disc != null) return
        val l = object : NsdManager.DiscoveryListener {
            override fun onDiscoveryStarted(t: String) { Log.d(TAG, "NSD discovery started") }
            override fun onDiscoveryStopped(t: String) {}
            override fun onStartDiscoveryFailed(t: String, e: Int) { Log.w(TAG, "NSD start failed $e"); disc = null }
            override fun onStopDiscoveryFailed(t: String, e: Int) {}
            override fun onServiceFound(i: NsdServiceInfo) {
                Log.d(TAG, "NSD found ${i.serviceName}")
                synchronized(this@Connector) { pending.add(i) }
                pump()
            }
            override fun onServiceLost(i: NsdServiceInfo) {
                Log.d(TAG, "NSD lost ${i.serviceName}")
                _found.update { l -> l.filterNot { it.name == i.serviceName } }
            }
        }
        disc = l
        runCatching { nsd.discoverServices("_lidrop._tcp", NsdManager.PROTOCOL_DNS_SD, l) }
            .onFailure { Log.w(TAG, "discoverServices", it); disc = null }
    }

    private fun stopDiscovery(clear: Boolean = true) {
        disc?.let { runCatching { nsd.stopServiceDiscovery(it) } }
        disc = null
        synchronized(this) { pending.clear(); resolving = false }
        if (clear) _found.value = emptyList()
    }

    /** NsdManager only allows one resolveService at a time: queue and run them serially. */
    private fun pump() {
        val next = synchronized(this) {
            if (resolving) return
            val n = pending.removeFirstOrNull() ?: return
            resolving = true
            n
        }
        val done = { synchronized(this) { resolving = false }; pump() }
        runCatching {
            @Suppress("DEPRECATION")
            nsd.resolveService(next, object : NsdManager.ResolveListener {
                override fun onResolveFailed(i: NsdServiceInfo, e: Int) {
                    Log.w(TAG, "NSD resolve failed ${i.serviceName} $e")
                    if (e == NsdManager.FAILURE_ALREADY_ACTIVE) synchronized(this@Connector) { pending.add(i) }
                    scope.launch { delay(if (e == NsdManager.FAILURE_ALREADY_ACTIVE) 500 else 0); done() }
                }
                override fun onServiceResolved(i: NsdServiceInfo) {
                    @Suppress("DEPRECATION") val h = i.host?.hostAddress
                    Log.d(TAG, "NSD resolved ${i.serviceName} -> $h:${i.port}")
                    if (h != null) _found.update { l -> l.filterNot { it.name == i.serviceName } + Found(i.serviceName, h, i.port) }
                    done()
                }
            })
        }.onFailure { Log.w(TAG, "resolveService", it); done() }
    }
}
