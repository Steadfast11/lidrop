package dev.lidrop

import android.content.Context
import android.util.Log
import kotlin.concurrent.thread

/**
 * The bundled iroh tunnel to the Mac: works across networks, direct when the networks allow it, relayed when not,
 * always end-to-end encrypted. The app talks plain framing to a loopback port. Process-wide: both activities share it.
 */
object Tunnel {
    const val LOCAL_PORT = 17777
    private var proc: Process? = null
    private var ticket: String? = null

    @Synchronized
    fun up(ctx: Context, t: String) {
        if (ticket == t && proc?.isAlive == true) return
        proc?.destroy()
        val bin = ctx.applicationInfo.nativeLibraryDir + "/libdumbpipe.so"
        runCatching {
            val p = ProcessBuilder(bin, "connect-tcp", "--addr", "127.0.0.1:$LOCAL_PORT", t).redirectErrorStream(true).start()
            proc = p
            ticket = t
            // destroying the process closes this stream under the reader: that is a normal end, not a crash
            thread(isDaemon = true) { runCatching { p.inputStream.bufferedReader().forEachLine { if ("secret" !in it) Log.d(TAG, "tunnel: $it") } } }
        }.onFailure { Log.w(TAG, "tunnel failed to start", it) }
    }
}
