package dev.lidrop

import android.graphics.Bitmap
import android.os.Build
import android.os.Bundle
import android.view.WindowManager
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.foundation.Image
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.grid.items
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.gestures.detectDragGestures
import androidx.compose.foundation.gestures.detectDragGesturesAfterLongPress
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.graphics.asComposeRenderEffect
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.foundation.systemGestureExclusion
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.hapticfeedback.HapticFeedbackType
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.layout.positionInRoot
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalHapticFeedback
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.lifecycle.lifecycleScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

/** File(s) handed to the app via Share → lidrop or "Pick file…"; only the first is sent in v0. */
object Shared {
    /** Selection / share tray: dragging the tray tile (or a selected cell) sends all of these, in order. */
    val items = mutableStateListOf<Item>()
    var resumeTick by mutableIntStateOf(0)
    var receivedTick by mutableIntStateOf(0)
    var showReceived by mutableStateOf(false)
    var demoTick by mutableIntStateOf(0)   // bumped to play the debug light demo
    var demoSender = false
    var paired by mutableStateOf(false)    // a computer has allowed this phone: the gallery opens at once, for good
    var gate by mutableStateOf(false)      // the first-pairing ceremony is on screen
}

class MainActivity : ComponentActivity() {
    private lateinit var client: MacClient
    private lateinit var connector: Connector

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        Looks.load(this)
        LocalPxPerMm.value = resources.displayMetrics.xdpi / 25.4f
        applyLightExtras(intent)
        client = MacClient(this, lifecycleScope)
        if (savedInstanceState == null) Shared.paired = client.token().isNotEmpty()
        connector = Connector(applicationContext, lifecycleScope, client)
        setContent {
            MaterialTheme(colorScheme = lidropColors()) {
                Surface(Modifier.fillMaxSize(), color = Color(0xFF101114), contentColor = Color.White) { App(client, connector) }
            }
        }
    }

    // test hook: adb shell am start -n dev.lidrop/.MainActivity --es connect HOST[:PORT]
    override fun onNewIntent(intent: android.content.Intent) {
        super.onNewIntent(intent)
        intent.getStringExtra("connect")?.let { connector.connectManual(it) }
        applyLightExtras(intent)
    }

    // test hook: adb shell am start -n dev.lidrop/.MainActivity --es look A|B|C --ez fxdemo true --ez fallback true
    private fun applyLightExtras(i: android.content.Intent?) {
        i ?: return
        i.getStringExtra("look")?.let { Looks.save(this, it) }
        Shared.demoSender = i.getBooleanExtra("fxsender", false)
        if (i.hasExtra("fallback")) Looks.forceFallback = i.getBooleanExtra("fallback", false)
        if (i.getBooleanExtra("fxdemo", false)) { Shared.demoTick++; i.removeExtra("fxdemo") }
    }

    override fun onResume() { super.onResume(); Shared.resumeTick++ }

    override fun onStart() { super.onStart(); connector.onForeground(); intent.getStringExtra("connect")?.let { connector.connectManual(it); intent.removeExtra("connect") } }
    override fun onStop() { connector.onBackground(); super.onStop() }

    override fun onDestroy() {
        client.disconnect()
        super.onDestroy()
    }
}

@Composable
fun App(client: MacClient, connector: Connector) {
    val ctx = LocalContext.current
    val density = LocalDensity.current
    val scope = rememberCoroutineScope()
    val ctrl = remember {
        DragController(ctx, client, scope, with(density) { TILE_DP.dp.toPx() }, with(density) { 56.dp.toPx() })
    }
    val receiver = remember { Receiver(ctx, scope, client, ctrl).also { ctrl.receiver = it; client.rx = it } }
    val conn by client.conn.collectAsState()
    val up = conn is Conn.Up
    val activity = ctx as ComponentActivity
    val fxActive = ctrl.light.running || receiver.fx.running
    var demo by remember { mutableStateOf(false) }
    LaunchedEffect(Shared.demoTick) {
        if (Shared.demoTick > 0) {
            demo = true
            lightDemo(if (Shared.demoSender) ctrl.light else receiver.fx, ctrl.screenW, ctrl.screenH, ctrl.tilePx, Shared.demoSender)
            demo = false
        }
    }
    LaunchedEffect(fxActive) { if (fxActive) while (true) withFrameNanos { FxClock.now = it / 1_000_000 } }

    val macName = (conn as? Conn.Up)?.mac
    LaunchedEffect(macName) { if (macName != null) publishShareTarget(ctx, macName) }
    val shownMac = macName ?: remember { ctx.getSharedPreferences("lidrop", 0) }.getString("lastName", null) ?: "Computer"
    val haptic = androidx.compose.ui.platform.LocalHapticFeedback.current
    val armedAt = ctrl.light.armedAt.coerceAtLeast(receiver.fx.armedAt)
    val landedAt = ctrl.light.burstAt.coerceAtLeast(receiver.fx.burstAt)
    LaunchedEffect(armedAt) { if (armedAt > 0) haptic.performHapticFeedback(HapticFeedbackType.TextHandleMove) }
    LaunchedEffect(landedAt) { if (landedAt > 0) haptic.performHapticFeedback(HapticFeedbackType.LongPress) }

    DisposableEffect(up) {
        if (up) activity.window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        onDispose { activity.window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON) }
    }

    Box(Modifier.fillMaxSize().onSizeChanged { ctrl.screenW = it.width.toFloat(); ctrl.screenH = it.height.toFloat() }) {
        // lifting a file softens and darkens everything behind it
        val lifted by androidx.compose.animation.core.animateFloatAsState(if (ctrl.drag != null || receiver.busy) 1f else 0f, androidx.compose.animation.core.tween(if (ctrl.drag != null || receiver.busy) 220 else 160))
        if (Shared.paired) Box(Modifier.fillMaxSize().graphicsLayer {
            if (Build.VERSION.SDK_INT >= 31 && lifted > 0.01f) renderEffect = android.graphics.RenderEffect.createBlurEffect(36f * lifted, 36f * lifted, android.graphics.Shader.TileMode.CLAMP).asComposeRenderEffect()
        }) { Gallery(ctrl, shownMac, up) }
        if (up) {
            Box(Modifier.align(Alignment.CenterStart).fillMaxHeight().width(32.dp).systemGestureExclusion())
            Box(Modifier.align(Alignment.CenterEnd).fillMaxHeight().width(32.dp).systemGestureExclusion())
        }

        if (lifted > 0.01f) Box(Modifier.fillMaxSize().graphicsLayer { alpha = lifted }.background(Color(0x8C000000)))
        if (demo) DemoBackdrop()
        LightOverlay(ctrl.light, ctrl.tilePx)
        LightOverlay(receiver.fx, ctrl.tilePx)

        DragTile(ctrl)

        receiver.cur?.let { inc ->
            Box(
                Modifier.size(TILE_DP.dp).graphicsLayer {
                    val w = size.width
                    val depth = inc.depth * w
                    val sw = ctrl.screenW; val sh = ctrl.screenH
                    when (inc.side) {
                        Side.LEFT -> { translationX = -w + depth; translationY = inc.along * sh - w / 2 }
                        Side.RIGHT -> { translationX = sw - depth; translationY = inc.along * sh - w / 2 }
                        Side.TOP -> { translationY = -w + depth; translationX = inc.along * sw - w / 2 }
                        Side.BOTTOM -> { translationY = sh - depth; translationX = inc.along * sw - w / 2 }
                    }
                    val inward = if (inc.side == Side.LEFT || inc.side == Side.RIGHT) sw else sh
                    val th = receiver.fx.thrust(0.42f * inward / w) * w // the wave carries it deep into the screen
                    rotationZ = -4f * (receiver.fx.thrust(1f).coerceIn(0f, 1f))
                    when (inc.side) {
                        Side.LEFT -> translationX += th
                        Side.RIGHT -> translationX -= th
                        Side.TOP -> translationY += th
                        Side.BOTTOM -> translationY -= th
                    }
                    alpha = inc.alpha
                    val sc = 1f
                    scaleX = sc; scaleY = sc
                }
            ) {
                StackTile(inc.bmp, inc.count, Modifier.fillMaxSize())
                if (inc.committed && inc.totalSize > 0) {
                    LinearProgressIndicator(
                        progress = { (inc.received.toFloat() / inc.totalSize).coerceIn(0f, 1f) },
                        modifier = Modifier.align(Alignment.BottomCenter).fillMaxWidth().padding(14.dp),
                    )
                }
            }
        }

        LightPrewarm()
        if (!Shared.paired || Shared.gate) {
            LaunchedEffect(Unit) { Shared.gate = true }
            PairGate(connector, client, onOpen = { Shared.paired = true }, onDone = { Shared.gate = false })
        }
        ctrl.toast?.let { msg ->
            // above the bottom controls, where the thumb is not covering it
            val inset = if (!Shared.paired) 128.dp else if (Shared.items.isEmpty()) 76.dp else if (Shared.items.any { it.date == 0L }) 164.dp else 130.dp
            Row(
                Modifier.align(Alignment.BottomCenter).navigationBarsPadding().padding(start = 16.dp, end = 16.dp, bottom = inset)
                    .background(Color(0xF0222428), CircleShape).padding(horizontal = 18.dp, vertical = 8.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Text(msg, color = Color.White, maxLines = 2)
                ctrl.toastLabel?.let { l ->
                    TextButton(onClick = { ctrl.toastAction?.invoke() }) { Text(l) }
                }
            }
        }
    }
}

/** Glow strip along a screen edge; side/strength are read in the draw phase so changes never recompose. */
@Composable
fun EdgeGlow(side: () -> Side, strength: () -> Float) {
    Box(
        Modifier.fillMaxSize().drawBehind {
            val g = strength().coerceIn(0f, 1f)
            val c = Color(0xFF4DA3FF).copy(alpha = 0.25f + 0.6f * g)
            val clear = Color(0x004DA3FF)
            val t = 28.dp.toPx()
            when (side()) {
                Side.LEFT -> drawRect(Brush.horizontalGradient(listOf(c, clear), 0f, t), size = androidx.compose.ui.geometry.Size(t, size.height))
                Side.RIGHT -> drawRect(Brush.horizontalGradient(listOf(clear, c), size.width - t, size.width), Offset(size.width - t, 0f), androidx.compose.ui.geometry.Size(t, size.height))
                Side.TOP -> drawRect(Brush.verticalGradient(listOf(c, clear), 0f, t), size = androidx.compose.ui.geometry.Size(size.width, t))
                Side.BOTTOM -> drawRect(Brush.verticalGradient(listOf(clear, c), size.height - t, size.height), Offset(0f, size.height - t), androidx.compose.ui.geometry.Size(size.width, t))
            }
        }
    )
}

/** A tile, drawn as a small stack with a count badge when it stands for several files. */
@Composable
fun StackTile(bmp: Bitmap?, count: Int, modifier: Modifier = Modifier, step: Dp = 6.dp, corner: Dp = 16.dp) {
    Box(modifier) {
        if (count > 1) {
            for (k in 2 downTo 1) {
                Box(
                    Modifier.fillMaxSize().offset(step * k, step * k).clip(RoundedCornerShape(corner))
                        .background(Color(0xFF4A505B).copy(alpha = 0.9f - 0.2f * k)),
                )
            }
        }
        Tile(bmp, Modifier.fillMaxSize(), corner)
        if (count > 1) {
            Text(
                "$count",
                Modifier.align(Alignment.TopEnd).padding(step).background(Accent, CircleShape)
                    .padding(horizontal = step + 2.dp, vertical = 1.dp),
                color = Color.Black, style = MaterialTheme.typography.labelSmall,
            )
        }
    }
}

@Composable
fun Tile(bmp: Bitmap?, modifier: Modifier = Modifier, corner: Dp = 16.dp) {
    Box(
        modifier.shadow(corner, RoundedCornerShape(corner)).clip(RoundedCornerShape(corner))
            .background(Color(0xFF3A3F47)),
        contentAlignment = Alignment.Center,
    ) {
        if (bmp != null) Image(bmp.asImageBitmap(), null, Modifier.fillMaxSize(), contentScale = ContentScale.Crop)
        else Text("FILE", color = Color.White)
    }
}

const val MAC_SHORTCUT = "mac"

/** The picked-up tile, drawn the same in the app and over other apps. */
@Composable
fun DragTile(ctrl: DragController) {
    (ctrl.drag ?: ctrl.linger)?.let { d ->
        val lift = remember(d.id) { androidx.compose.animation.core.Animatable(d.startScale) }
        LaunchedEffect(d.id) { lift.animateTo(1f, androidx.compose.animation.core.tween(120)) }
        // it flies from under the finger to the middle of the screen, where it waits to be thrown
        val fly = remember(d.id) { androidx.compose.animation.core.Animatable(0f) }
        LaunchedEffect(d.id) { fly.animateTo(1f, androidx.compose.animation.core.spring(dampingRatio = 0.72f, stiffness = 380f)) }
        val spread = remember(d.id) { androidx.compose.animation.core.Animatable(0f) }
        LaunchedEffect(d.id) { spread.animateTo(1f, androidx.compose.animation.core.spring(dampingRatio = 0.62f, stiffness = 320f)) }
        val many = d.items.size > 1
        val shape = if (many) 1f else d.bmp?.let { it.width.toFloat() / it.height.coerceAtLeast(1) } ?: 1f // a single tile keeps the file's own shape
        Box(
            Modifier.size(TILE_DP.dp).graphicsLayer {
                val th = ctrl.light.thrust(0f) * size.width // leaves through the seam as the wave arrives
                val away = 1f - fly.value
                translationX = d.x - when (ctrl.light.side) { Side.LEFT -> -th; Side.RIGHT -> th; else -> 0f } + (d.f0x - ctrl.screenW / 2) * away
                translationY = d.y - when (ctrl.light.side) { Side.TOP -> -th; Side.BOTTOM -> th; else -> 0f } + (d.f0y - ctrl.screenH / 2) * away
                val sc = lift.value
                scaleX = sc; scaleY = sc
                alpha = ctrl.light.tileAlpha()
            },
            contentAlignment = Alignment.Center,
        ) {
            // a group: the selected tiles fan out behind the one in the hand
            d.extras.forEachIndexed { i, b ->
                val dir = if (i == 0) 1f else -1f
                Tile(b, Modifier.fillMaxSize(0.94f).graphicsLayer {
                    rotationZ = 8f * dir * spread.value; translationX = 16.dp.toPx() * dir * spread.value; alpha = spread.value.coerceIn(0f, 1f)
                })
            }
            Tile(d.bmp, Modifier.aspectRatio(shape, matchHeightConstraintsFirst = shape < 1f))
            if (many) Text(
                "${d.items.size}", Modifier.align(Alignment.TopEnd).padding(8.dp).background(Accent, CircleShape).padding(horizontal = 10.dp, vertical = 3.dp),
                color = Color.Black, style = MaterialTheme.typography.labelLarge,
            )
        }
    }
}

/** Puts this Mac in the share sheet's Direct Share row. The system ranks that row; recent use moves it up. */
fun publishShareTarget(ctx: android.content.Context, mac: String) {
    val icon = androidx.core.graphics.drawable.IconCompat.createWithResource(ctx, R.drawable.ic_lidrop)
    val info = androidx.core.content.pm.ShortcutInfoCompat.Builder(ctx, MAC_SHORTCUT)
        .setShortLabel(mac).setLongLived(true).setRank(0)
        .setIcon(icon)
        .setPerson(androidx.core.app.Person.Builder().setName(mac).setKey(MAC_SHORTCUT).setIcon(icon).setImportant(true).build())
        .setCategories(setOf("dev.lidrop.category.SEND"))
        .setIntent(android.content.Intent(ctx, MainActivity::class.java).setAction(android.content.Intent.ACTION_MAIN))
        .build()
    runCatching { androidx.core.content.pm.ShortcutManagerCompat.pushDynamicShortcut(ctx, info) }
}

/** Where a file is while it travels: a dashed outline and a small blue ring. */
@Composable
fun PendingSlot() {
    Box(Modifier.fillMaxSize().drawBehind {
        val dash = androidx.compose.ui.graphics.PathEffect.dashPathEffect(floatArrayOf(5.dp.toPx(), 4.dp.toPx()))
        drawRoundRect(Color(0xCCFFFFFF), cornerRadius = androidx.compose.ui.geometry.CornerRadius(16.dp.toPx()), style = androidx.compose.ui.graphics.drawscope.Stroke(1.5.dp.toPx(), pathEffect = dash))
    }) {
        CircularProgressIndicator(Modifier.align(Alignment.TopEnd).padding(8.dp).size(14.dp), color = Accent, strokeWidth = 2.dp)
    }
}

fun humanSize(b: Long) = when {
    b >= 1 shl 30 -> "%.1f GB".format(b / 1073741824.0)
    b >= 1 shl 20 -> "%.1f MB".format(b / 1048576.0)
    b >= 1 shl 10 -> "%.0f KB".format(b / 1024.0)
    else -> "$b B"
}

private suspend fun androidx.compose.ui.input.pointer.PointerInputScope.dragGestures(
    instant: Boolean, onDragStart: (Offset) -> Unit, onDrag: (androidx.compose.ui.input.pointer.PointerInputChange, Offset) -> Unit,
    onDragEnd: () -> Unit, onDragCancel: () -> Unit,
) {
    if (instant) detectDragGestures(onDragStart, onDragEnd, onDragCancel, onDrag)
    else detectDragGesturesAfterLongPress(onDragStart, onDragEnd, onDragCancel, onDrag)
}

/** A long-press-draggable source cell: long-press picks up the tile, which follows the finger. */
@Composable
fun Source(
    first: Item, provider: () -> List<Item>, ctrl: DragController, modifier: Modifier,
    onTap: (() -> Unit)? = null, instant: Boolean = false, content: @Composable (Bitmap?) -> Unit,
) {
    val ctx = LocalContext.current
    val haptic = LocalHapticFeedback.current
    val bmp by produceState<Bitmap?>(null, first.uri) { value = withContext(Dispatchers.IO) { thumbnail(ctx, first) } }
    var pos by remember { mutableStateOf(Offset.Zero) }
    var cellPx by remember { mutableStateOf(0f) }
    var suppressTapUntil by remember { mutableStateOf(0L) }
    val tapMod = if (onTap == null) Modifier else Modifier.pointerInput(first.uri) {
        detectTapGestures(onTap = { if (android.os.SystemClock.uptimeMillis() > suppressTapUntil) onTap() })
    }
    Box(
        modifier.onGloballyPositioned { pos = it.positionInRoot(); cellPx = it.size.width.toFloat() }
            .then(tapMod)
            .pointerInput(first.uri) {
                dragGestures(
                    instant,
                    onDragStart = { o ->
                        haptic.performHapticFeedback(HapticFeedbackType.LongPress)
                        ctrl.start(provider(), bmp, pos.x + o.x, pos.y + o.y, cellPx)
                    },
                    onDrag = { c, _ -> c.consume(); ctrl.move(pos.x + c.position.x, pos.y + c.position.y) },
                    onDragEnd = { suppressTapUntil = android.os.SystemClock.uptimeMillis() + 400; ctrl.end() },
                    onDragCancel = { suppressTapUntil = android.os.SystemClock.uptimeMillis() + 400; ctrl.cancel() },
                )
            }
    ) { content(bmp) }
}
