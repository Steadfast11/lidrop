package dev.lidrop

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.spring
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.slideInVertically
import androidx.compose.animation.slideOutVertically
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.items
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.*
import androidx.compose.material3.pulltorefresh.PullToRefreshBox
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.graphics.vector.addPathNodes
import androidx.compose.ui.hapticfeedback.HapticFeedbackType
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalHapticFeedback
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

val Accent = Color(0xFF4DA3FF)
val DimText = Color(0xFF9AA0AA)
private val Glass = Color(0xEB26282D)
private val GlassEdge = Color(0x1AFFFFFF)

/** Same colours as the iPhone app: the buttons are its blue, not Material's default lavender. */
fun lidropColors() = darkColorScheme(primary = Color(0xFF0A84FF), onPrimary = Color.White)

private fun glyph(d: String) = ImageVector.Builder(defaultWidth = 24.dp, defaultHeight = 24.dp, viewportWidth = 24f, viewportHeight = 24f)
    .addPath(addPathNodes(d), fill = SolidColor(Color.Black)).build()

/** The few icons the app needs: the full icon library is far too large for them. */
object Glyphs {
    val Add = glyph("M19,13h-6v6h-2v-6H5v-2h6V5h2v6h6v2z")
    val Close = glyph("M19,6.41L17.59,5 12,10.59 6.41,5 5,6.41 10.59,12 5,17.59 6.41,19 12,13.41 17.59,19 19,17.59 13.41,12z")
    val Check = glyph("M9,16.17L4.83,12l-1.42,1.41L9,19 21,7l-1.41,-1.41z")
    val Expand = glyph("M16.59,8.59L12,13.17 7.41,8.59 6,10l6,6 6,-6z")
    val Video = glyph("M17,10.5V7c0,-0.55 -0.45,-1 -1,-1H4c-0.55,0 -1,0.45 -1,1v10c0,0.55 0.45,1 1,1h12c0.55,0 1,-0.45 1,-1v-3.5l4,4v-11l-4,4z")
    val Photos = glyph("M22,16V4c0,-1.1 -0.9,-2 -2,-2H8c-1.1,0 -2,0.9 -2,2v12c0,1.1 0.9,2 2,2h12c1.1,0 2,-0.9 2,-2zM11,12l2.03,2.71L16,11l4,5H8l3,-4zM2,6v14c0,1.1 0.9,2 2,2h14v-2H4V6H2z")
    val Inbox = glyph("M19,3H4.99c-1.11,0 -1.98,0.89 -1.98,2L3,19c0,1.1 0.88,2 1.99,2H19c1.1,0 2,-0.9 2,-2V5c0,-1.11 -0.9,-2 -2,-2zM19,15h-4c0,1.66 -1.35,3 -3,3s-3,-1.34 -3,-3H4.99V5H19v10zM16,10h-2V7h-4v3H8l4,4 4,-4z")
    val File = glyph("M6,2c-1.1,0 -1.99,0.9 -1.99,2L4,20c0,1.1 0.89,2 1.99,2H18c1.1,0 2,-0.9 2,-2V8l-6,-6H6zM13,9V3.5L18.5,9H13z")
}

@Composable
fun Gallery(ctrl: DragController, macName: String, up: Boolean) {
    val ctx = LocalContext.current
    val perms = if (Build.VERSION.SDK_INT >= 33)
        arrayOf(Manifest.permission.READ_MEDIA_IMAGES, Manifest.permission.READ_MEDIA_VIDEO)
    else arrayOf(Manifest.permission.READ_EXTERNAL_STORAGE)
    fun granted() = perms.all { ctx.checkSelfPermission(it) == PackageManager.PERMISSION_GRANTED }
    var ok by remember { mutableStateOf(granted()) }
    val askPerms = rememberLauncherForActivityResult(ActivityResultContracts.RequestMultiplePermissions()) { ok = granted() }
    var items by remember { mutableStateOf<List<Item>>(emptyList()) }
    val tray = Shared.items
    val picker = rememberLauncherForActivityResult(ActivityResultContracts.OpenMultipleDocuments()) { uris ->
        if (uris.isNotEmpty()) { tray.clear(); tray.addAll(uris.map { describe(ctx, it) }) }
    }
    LaunchedEffect(Unit) { if (!ok) askPerms.launch(perms) }
    var refreshing by remember { mutableStateOf(false) }
    // reload the media list on start, on returning to the foreground, and on pull-down
    LaunchedEffect(ok, Shared.resumeTick) { if (ok) items = withContext(Dispatchers.IO) { queryMedia(ctx) } }
    var received by remember { mutableStateOf<List<RecvFile>>(emptyList()) }
    LaunchedEffect(Shared.showReceived, Shared.receivedTick, Shared.resumeTick) {
        if (Shared.showReceived) received = withContext(Dispatchers.IO) { queryReceived(ctx) }
    }
    val scope = rememberCoroutineScope()
    val density = LocalDensity.current
    var controlsPx by remember { mutableIntStateOf(0) }
    val controls = with(density) { controlsPx.toDp() }

    Box(Modifier.fillMaxSize()) {
        Column(Modifier.fillMaxSize().statusBarsPadding()) {
            Header(macName, up)
            when {
                Shared.showReceived -> ReceivedList(received, controls)
                !ok -> NoAccess(controls) { askPerms.launch(perms) }
                else -> PullToRefreshBox(
                    isRefreshing = refreshing,
                    onRefresh = { scope.launch { refreshing = true; items = withContext(Dispatchers.IO) { queryMedia(ctx) }; refreshing = false } },
                    modifier = Modifier.fillMaxSize(),
                ) {
                    // big tiles that scale with the screen: two on any phone, more on a foldable
                    LazyVerticalGrid(
                        GridCells.Adaptive(140.dp), Modifier.fillMaxSize().padding(horizontal = 16.dp),
                        horizontalArrangement = Arrangement.spacedBy(10.dp), verticalArrangement = Arrangement.spacedBy(10.dp),
                        contentPadding = PaddingValues(top = 8.dp, bottom = controls + 12.dp),
                    ) {
                        items(items, key = { it.uri.toString() }) { item -> Cell(item, ctrl) }
                    }
                }
            }
        }
        BottomControls(ctrl, Modifier.align(Alignment.BottomCenter).onSizeChanged { controlsPx = it.height }) { picker.launch(arrayOf("*/*")) }
    }
}

/** The computer's name, and whether the link is up. There is nothing to do here: the link looks after itself. */
@Composable
private fun Header(macName: String, up: Boolean) {
    Row(
        Modifier.padding(horizontal = 16.dp, vertical = 6.dp).clip(CircleShape).background(Color(0x14FFFFFF)).heightIn(min = 44.dp).padding(horizontal = 14.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Box(Modifier.size(8.dp).background(if (up) Color(0xFF34C759) else DimText, CircleShape))
        Spacer(Modifier.width(8.dp))
        Text(macName, maxLines = 1, overflow = TextOverflow.Ellipsis, style = MaterialTheme.typography.bodyMedium, fontWeight = FontWeight.Medium)
    }
}

@Composable
private fun Cell(item: Item, ctrl: DragController) {
    val haptic = LocalHapticFeedback.current
    val tray = Shared.items
    val selected = tray.any { it.uri == item.uri }
    val sendingThis = item.uri in ctrl.pending
    val shape = RoundedCornerShape(16.dp)
    val scale by animateFloatAsState(if (selected) 0.96f else 1f, spring(), label = "select")
    Source(
        // holding any tile while files are selected takes the whole group, this one included
        item, { if (tray.isEmpty()) listOf(item) else { if (!selected) tray.add(item); tray.toList() } }, ctrl,
        Modifier.aspectRatio(1f).graphicsLayer { scaleX = scale; scaleY = scale }.clip(shape),
        onTap = {
            haptic.performHapticFeedback(HapticFeedbackType.TextHandleMove)
            if (selected) tray.removeAll { it.uri == item.uri } else tray.add(item)
        },
    ) { bmp ->
        if (sendingThis) PendingSlot() else if (item.uri in ctrl.lifting) Box(Modifier.fillMaxSize().background(Color(0xFF191B1F))) else Box(Modifier.fillMaxSize().background(Color(0xFF222428))) {
            if (bmp != null) Image(bmp.asImageBitmap(), null, Modifier.fillMaxSize(), contentScale = ContentScale.Crop)
            if (item.isVideo) {
                Box(Modifier.align(Alignment.BottomEnd).padding(6.dp).size(28.dp).background(Color(0x59000000), CircleShape), contentAlignment = Alignment.Center) {
                    Icon(Glyphs.Video, null, Modifier.size(16.dp), tint = Color.White)
                }
            }
            if (selected) {
                Box(Modifier.fillMaxSize().border(3.dp, Accent, shape))
                Box(Modifier.align(Alignment.TopEnd).padding(8.dp).size(26.dp).background(Accent, CircleShape), contentAlignment = Alignment.Center) {
                    Icon(Glyphs.Check, null, Modifier.size(18.dp), tint = Color.Black)
                }
            }
        }
    }
}

/** Everything the thumb needs, floating over the bottom of the grid. */
@Composable
private fun BottomControls(ctrl: DragController, modifier: Modifier, onPick: () -> Unit) {
    val tray = Shared.items
    Column(
        modifier.fillMaxWidth().background(Brush.verticalGradient(listOf(Color.Transparent, Color(0xE6101114))))
            .navigationBarsPadding().padding(start = 16.dp, end = 16.dp, top = 8.dp, bottom = 6.dp),
    ) {
        AnimatedVisibility(tray.isNotEmpty(), enter = fadeIn() + slideInVertically { it / 2 }, exit = fadeOut() + slideOutVertically { it / 2 }) {
            // files picked with + are not in the grid, so they need a tile to hold; selected photos only need a way out
            tray.firstOrNull()?.let { if (tray.any { i -> i.date == 0L }) TrayCard(it, ctrl) else SelectionPill(tray.size) { tray.clear() } }
        }
        Row(
            Modifier.fillMaxWidth().clip(CircleShape).background(Glass).border(0.5.dp, GlassEdge, CircleShape).padding(5.dp),
            verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(4.dp),
        ) {
            DockTab("Photos", Glyphs.Photos, !Shared.showReceived, Modifier.weight(1f)) { Shared.showReceived = false }
            DockTab("Received", Glyphs.Inbox, Shared.showReceived, Modifier.weight(1f)) { Shared.showReceived = true }
            Box(Modifier.size(48.dp).clip(CircleShape).background(MaterialTheme.colorScheme.primary).clickable(onClick = onPick), contentAlignment = Alignment.Center) {
                Icon(Glyphs.Add, "Pick files", Modifier.size(26.dp), tint = Color.White)
            }
        }
    }
}

@Composable
private fun SelectionPill(count: Int, onClear: () -> Unit) {
    Box(Modifier.fillMaxWidth().padding(bottom = 8.dp), contentAlignment = Alignment.Center) {
        Row(
            Modifier.clip(CircleShape).background(Glass).border(0.5.dp, GlassEdge, CircleShape).clickable(onClick = onClear).heightIn(min = 40.dp).padding(start = 16.dp, end = 10.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Text("$count selected", style = MaterialTheme.typography.labelLarge)
            Spacer(Modifier.width(6.dp))
            Icon(Glyphs.Close, "Clear selection", Modifier.size(16.dp), tint = DimText)
        }
    }
}

@Composable
private fun DockTab(title: String, icon: ImageVector, on: Boolean, modifier: Modifier, onClick: () -> Unit) {
    val tint = if (on) Color.White else DimText
    Row(
        modifier.clip(CircleShape).background(if (on) Color(0x29FFFFFF) else Color.Transparent).clickable(onClick = onClick).heightIn(min = 48.dp),
        verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.Center,
    ) {
        Icon(icon, null, Modifier.size(20.dp), tint = tint)
        Spacer(Modifier.width(8.dp))
        Text(title, color = tint, maxLines = 1, style = MaterialTheme.typography.labelLarge, fontSize = 14.sp)
    }
}

@Composable
private fun TrayCard(first: Item, ctrl: DragController) {
    val tray = Shared.items
    val shape = RoundedCornerShape(22.dp)
    Row(
        Modifier.padding(bottom = 8.dp).fillMaxWidth().clip(shape).background(Glass).border(0.5.dp, GlassEdge, shape).padding(start = 10.dp, end = 2.dp, top = 8.dp, bottom = 8.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Source(first, { tray.toList() }, ctrl, Modifier.weight(1f)) { bmp ->
            Row(verticalAlignment = Alignment.CenterVertically) {
                StackTile(bmp, tray.size, Modifier.size(60.dp), step = 3.dp, corner = 12.dp)
                Spacer(Modifier.width(14.dp))
                Column {
                    Text(if (tray.size == 1) first.name else "${tray.size} files", maxLines = 1, overflow = TextOverflow.MiddleEllipsis, style = MaterialTheme.typography.bodyMedium, fontWeight = FontWeight.Medium)
                    Text(humanSize(tray.sumOf { maxOf(it.size, 0L) }), maxLines = 1, style = MaterialTheme.typography.bodySmall, color = DimText)
                }
            }
        }
        IconButton(onClick = { tray.clear() }) { Icon(Glyphs.Close, "Clear selection", Modifier.size(20.dp), tint = DimText) }
    }
}

@Composable
private fun NoAccess(bottom: Dp, onAsk: () -> Unit) {
    Column(Modifier.fillMaxSize().padding(24.dp).padding(bottom = bottom), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.Center) {
        Icon(Glyphs.Photos, null, Modifier.size(44.dp), tint = DimText)
        Spacer(Modifier.height(14.dp))
        Text("Allow access to your photos and videos, or pick files with +", textAlign = TextAlign.Center)
        Spacer(Modifier.height(14.dp))
        Button(onAsk) { Text("Allow photos & videos") }
    }
}

@Composable
private fun ReceivedList(files: List<RecvFile>, bottom: Dp) {
    val ctx = LocalContext.current
    if (files.isEmpty()) {
        Column(Modifier.fillMaxSize().padding(24.dp).padding(bottom = bottom), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.Center) {
            Icon(Glyphs.Inbox, null, Modifier.size(44.dp), tint = DimText)
            Spacer(Modifier.height(12.dp))
            Text("Nothing received yet", style = MaterialTheme.typography.titleMedium)
            Spacer(Modifier.height(4.dp))
            Text("Drag a file from your Mac to the phone.", style = MaterialTheme.typography.bodyMedium, color = DimText)
        }
        return
    }
    LazyColumn(Modifier.fillMaxSize(), contentPadding = PaddingValues(start = 16.dp, end = 16.dp, bottom = bottom + 12.dp)) {
        items(files, key = { it.uri.toString() }) { f ->
            Row(
                Modifier.fillMaxWidth().clickable {
                    runCatching {
                        ctx.startActivity(
                            Intent(Intent.ACTION_VIEW).setDataAndType(f.uri, f.mime)
                                .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_ACTIVITY_NEW_TASK)
                        )
                    }
                }.heightIn(min = 56.dp).padding(vertical = 8.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Icon(Glyphs.File, null, Modifier.size(22.dp), tint = Accent)
                Spacer(Modifier.width(14.dp))
                Text(f.name, Modifier.weight(1f), maxLines = 1, overflow = TextOverflow.MiddleEllipsis, style = MaterialTheme.typography.bodyMedium)
                Spacer(Modifier.width(12.dp))
                Text(humanSize(f.size), style = MaterialTheme.typography.bodySmall, color = DimText)
            }
            HorizontalDivider(Modifier.padding(start = 36.dp), color = Color(0x14FFFFFF))
        }
    }
}
