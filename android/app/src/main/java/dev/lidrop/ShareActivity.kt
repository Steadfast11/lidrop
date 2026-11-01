package dev.lidrop

import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.view.WindowManager
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.widthIn
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.OutlinedButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.runtime.withFrameNanos
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.unit.dp
import androidx.core.content.pm.ShortcutManagerCompat
import androidx.lifecycle.lifecycleScope
import kotlinx.coroutines.delay

/** Share target: a see-through window over whatever app the file came from. The throw happens there, then it closes. */
class ShareActivity : ComponentActivity() {
    private lateinit var client: MacClient
    private lateinit var connector: Connector

    @Suppress("DEPRECATION")
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        val uris: List<Uri> = when (intent.action) {
            Intent.ACTION_SEND -> listOfNotNull(if (Build.VERSION.SDK_INT >= 33) intent.getParcelableExtra(Intent.EXTRA_STREAM, Uri::class.java) else intent.getParcelableExtra(Intent.EXTRA_STREAM))
            Intent.ACTION_SEND_MULTIPLE -> (if (Build.VERSION.SDK_INT >= 33) intent.getParcelableArrayListExtra(Intent.EXTRA_STREAM, Uri::class.java) else intent.getParcelableArrayListExtra<Uri>(Intent.EXTRA_STREAM)) ?: emptyList()
            else -> emptyList()
        }
        if (uris.isEmpty()) { finish(); return }
        Looks.load(this)
        LocalPxPerMm.value = resources.displayMetrics.xdpi / 25.4f
        window.addFlags(WindowManager.LayoutParams.FLAG_DIM_BEHIND)
        window.setDimAmount(0.45f)
        if (Build.VERSION.SDK_INT >= 31) {
            window.addFlags(WindowManager.LayoutParams.FLAG_BLUR_BEHIND)
            window.attributes = window.attributes.apply { blurBehindRadius = 70 }
        }
        ShortcutManagerCompat.reportShortcutUsed(this, MAC_SHORTCUT)
        val items = uris.map { describe(this, it) }
        client = MacClient(this, lifecycleScope, "share")
        connector = Connector(applicationContext, lifecycleScope, client)
        setContent { MaterialTheme(colorScheme = lidropColors()) { ShareScreen(items, client) { finish() } } }
    }

    override fun onStart() { super.onStart(); if (::connector.isInitialized) connector.onForeground() }
    override fun onStop() { if (::connector.isInitialized) connector.onBackground(); super.onStop() }
    override fun onDestroy() { if (::client.isInitialized) client.disconnect(); super.onDestroy() }
}

@Composable
private fun ShareScreen(items: List<Item>, client: MacClient, onDone: () -> Unit) {
    val ctx = LocalContext.current
    val density = LocalDensity.current
    val scope = rememberCoroutineScope()
    val ctrl = remember { DragController(ctx, client, scope, with(density) { TILE_DP.dp.toPx() }, with(density) { 56.dp.toPx() }) }
    val conn by client.conn.collectAsState()
    val up = conn is Conn.Up
    (conn as? Conn.Up)?.mac?.let { mac -> LaunchedEffect(mac) { publishShareTarget(ctx, mac) } }
    val busy = ctrl.drag != null || ctrl.linger != null || ctrl.sending
    LaunchedEffect(ctrl.light.running) { if (ctrl.light.running) while (true) withFrameNanos { FxClock.now = it / 1_000_000 } }
    var sent by remember { mutableStateOf(false) }
    LaunchedEffect(ctrl.pending) {
        if (ctrl.pending.isNotEmpty()) sent = true
        else if (sent) { delay(700); onDone() }
    }
    BoxWithConstraints(Modifier.fillMaxSize().onSizeChanged { ctrl.screenW = it.width.toFloat(); ctrl.screenH = it.height.toFloat() }) {
        val tile = minOf(TILE_DP.dp, maxWidth * 0.52f)
        val tileY = maxHeight * 0.56f - tile / 2 // a little below the middle, under the thumb
        LightOverlay(ctrl.light, ctrl.tilePx)
        // the source stays composed while dragging, invisible: removing it would cancel the gesture it owns
        // the link comes up by itself; until it does the tile only waits, a little dimmer
        Source(items.first(), { items }, ctrl, Modifier.align(Alignment.TopCenter).offset(y = tileY).size(tile).graphicsLayer { alpha = if (busy) 0f else if (up) 1f else 0.6f }, instant = true) { bmp ->
            StackTile(bmp, items.size, Modifier.fillMaxSize())
        }
        if (!busy) OutlinedButton(onDone, Modifier.align(Alignment.BottomCenter).navigationBarsPadding().padding(bottom = 16.dp).widthIn(min = 120.dp).heightIn(min = 48.dp)) { Text("Cancel", color = Color.White) }
        DragTile(ctrl)
    }
}
