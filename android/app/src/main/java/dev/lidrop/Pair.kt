package dev.lidrop

import android.content.ClipboardManager
import android.graphics.Paint
import android.graphics.RenderNode
import android.graphics.RuntimeShader
import android.os.Build
import android.os.SystemClock
import android.util.Log
import androidx.annotation.RequiresApi
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.runtime.withFrameMillis
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.drawscope.DrawScope
import androidx.compose.ui.graphics.drawscope.drawIntoCanvas
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.graphics.nativeCanvas
import androidx.compose.ui.hapticfeedback.HapticFeedbackType
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalHapticFeedback
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import org.json.JSONObject
import kotlin.math.exp

/**
 * The connect ceremony (docs/PROTOCOL.md "Connect ceremony"), seen once, the first time a computer allows this phone: a
 * drop of liquid glass on a dark screen. It fills by itself while the link comes up, and the wave only leaves the seam once
 * the computer has really answered. The Mac draws the same lens and wave (mac/Sources/lidrop/Glass.swift) in the same millimetres. Lengths here are in screen widths.
 * Output is premultiplied, so the gallery shows through once the wave opens the screen.
 */
private const val PAIR_AGSL = """
uniform float2 size, drop, seam;
uniform float dropR, fill, jelly, time, front, fade, men;
float3 backdrop(float2 p, float asp) {
    float v = length(p - float2(0.5, asp * 0.4));
    float3 c = mix(float3(0.085, 0.09, 0.1), float3(0.016, 0.017, 0.02), smoothstep(0.0, 1.25, v));
    float2 a = p - float2(0.2, asp * 0.2), b = p - float2(0.85, asp * 0.72);
    return c + float3(0.75, 0.85, 1.0) * (0.045 * exp(-dot(a, a) / 0.2) + 0.03 * exp(-dot(b, b) / 0.16));
}
float3 shade(float2 q, float R, float3 under) {
    float2 nq = q / max(R, length(q));   // outside the glass stays on its rim, or the highlight runs to infinity
    float z = sqrt(max(1.0 - dot(nq, nq), 0.0));
    float3 n = float3(nq, z);
    float fres = pow(1.0 - z, 3.0);
    float3 c = under + float3(0.92, 0.95, 1.0) * (0.03 + 0.42 * fres);
    float s = max(dot(n, normalize(float3(-0.42, -0.62, 0.66))), 0.0);
    c += 0.75 * pow(s, 70.0) + 0.1 * pow(s, 6.0);
    float b = max(dot(n, normalize(float3(0.4, 0.7, 0.35))), 0.0);
    return c + float3(0.8, 0.88, 1.0) * 0.14 * pow(b, 5.0);
}
half4 main(float2 c) {
    float2 p = c / size.x;
    float asp = size.y / size.x, t = time, px = 1.5 / size.x;
    float3 bg = backdrop(p, asp), col = bg;
    float2 q;
    if (men > 0.0) {
        q = p - seam;
        col = mix(shade(q, men, bg), col, smoothstep(-px, px, length(q) - men));
    }
    q = p - drop;
    float a = atan(q.y, q.x);
    float R = dropR * (1.0 + 0.1 * fill) * (1.0 + jelly * (0.03 * sin(2.0 * a + t * 2.3) + 0.02 * sin(3.0 * a - t * 1.9) + 0.012 * sin(5.0 * a + t * 1.3)));
    float sd = length(q) - R;
    float2 sq = q - float2(0.0, 0.03);
    float sh = max(length(sq) - R, 0.0) / 0.09;
    col *= 1.0 - 0.5 * exp(-sh * sh);
    float2 nq = q / max(R, length(q));   // outside the glass stays on its rim, or the highlight runs to infinity
    float z = sqrt(max(1.0 - dot(nq, nq), 0.0));
    float3 under = backdrop(p - nq * R * 0.3 * (1.0 - z), asp);
    float lvl = R * (1.0 - 2.0 * fill) + 0.007 * sin(q.x * 34.0 + t * 3.1) + 0.004 * sin(q.x * 61.0 - t * 2.3);
    float liq = smoothstep(lvl - 0.003, lvl + 0.003, q.y) * step(0.001, fill);
    under = mix(under, float3(0.78, 0.83, 0.9), liq * (0.13 + 0.14 * clamp((q.y - lvl) / R, 0.0, 1.0)));
    float line = (q.y - lvl) / 0.005;
    under += 0.14 * exp(-line * line) * step(0.001, fill) * step(fill, 0.995);
    col = mix(shade(q, R, under), col, smoothstep(-px, px, sd));
    float alpha = 1.0;
    if (front >= 0.0) {
        float x = length(p - seam) - front, w = 0.037 + 0.05 * front;
        alpha = smoothstep(-w, w * 0.3, x);
        float r = x / (w * 0.7);
        float rim = exp(-r * r) * fade;
        col = col * alpha + rim * 0.42 * float3(0.92, 0.95, 1.0);
        alpha = max(alpha, rim * 0.42);
    }
    float n = fract(52.9829189 * fract(dot(c, float2(0.06711056, 0.00583715)))) - 0.5;
    return half4(max(col + n / 255.0, float3(0.0)), clamp(alpha, 0.0, 1.0));
}
"""

@RequiresApi(33)
private object PairFx {
    val shader: RuntimeShader? = runCatching { RuntimeShader(PAIR_AGSL) }.onFailure { Log.e("lidrop", "pair shader failed, using a plain circle", it) }.getOrNull()
    val node = RenderNode("lidrop-pair").apply { setUseCompositingLayer(true, Paint(Paint.FILTER_BITMAP_FLAG)) } // smooth when scaled up
    val paint = Paint()
}

private const val LAYER = 0.67f
private const val DROP_R = 0.2f
private const val DROP_Y = 0.62f // of the screen height: in the lower half, where the thumb rests

private fun smooth(a: Float, b: Float, x: Float): Float { val t = ((x - a) / (b - a)).coerceIn(0f, 1f); return t * t * (3f - 2f * t) }

/** The lens and the wave, in mm: must stay the same as `GlassFX.lensMm` / `frontMm` on the Mac, or the screens stop matching. */
private fun lensMm(p: Float) = 10f + 24f * p
private fun frontMm(t: Float) = 0.66f * Seam.macW * (1f - exp(-t / 0.3f))

private fun DrawScope.drawField(fill: Float, jelly: Float, link: Float, burst: Float, time: Float, side: Side) {
    val w = size.width; val h = size.height; val asp = h / w
    val mmW = w / LocalPxPerMm.value
    val u = if (Build.VERSION.SDK_INT >= 33) PairFx.shader else null
    if (u != null && Build.VERSION.SDK_INT >= 33) {
        val lw = (w * LAYER).toInt(); val lh = (h * LAYER).toInt()
        u.setFloatUniform("size", lw.toFloat(), lh.toFloat())
        u.setFloatUniform("drop", 0.5f, asp * DROP_Y)
        when (side) {
            Side.LEFT -> u.setFloatUniform("seam", 0f, asp / 2)
            Side.RIGHT -> u.setFloatUniform("seam", 1f, asp / 2)
            Side.TOP -> u.setFloatUniform("seam", 0.5f, 0f)
            Side.BOTTOM -> u.setFloatUniform("seam", 0.5f, asp)
        }
        u.setFloatUniform("dropR", DROP_R); u.setFloatUniform("fill", fill); u.setFloatUniform("jelly", jelly); u.setFloatUniform("time", time)
        u.setFloatUniform("front", if (burst < 0f) -1f else frontMm(burst) / mmW)
        u.setFloatUniform("fade", 1f - smooth(0.45f, 0.95f, burst))
        u.setFloatUniform("men", link * lensMm(fill) / mmW * (if (burst < 0f) 1f else exp(-burst / 0.08f)))
        val node = PairFx.node
        if (node.width != lw || node.height != lh) node.setPosition(0, 0, lw, lh)
        PairFx.paint.shader = u
        val rec = node.beginRecording(lw, lh)
        rec.drawRect(0f, 0f, lw.toFloat(), lh.toFloat(), PairFx.paint)
        node.endRecording()
        drawIntoCanvas { val c = it.nativeCanvas; c.save(); c.scale(w / lw, h / lh); c.drawRenderNode(node); c.restore() }
    } else { // API < 33: dark screen, a plain glass circle
        val open = if (burst < 0f) 0f else (burst / 0.5f).coerceIn(0f, 1f)
        drawRect(Color(0xFF0B0C0E).copy(alpha = 1f - open))
        drawCircle(Color.White.copy(alpha = (0.08f + 0.2f * fill) * (1f - open)), DROP_R * w, Offset(w / 2, h * DROP_Y))
    }
}

/** What the gate is doing; plain fields, advanced once a frame. */
private class GateState {
    var fill = 0f; var jelly = 0.25f; var link = 0f
    var upAt = -1L; var firedAt = -1L
    var lastSend = 0L; var sends = 0
}

@Composable
fun PairGate(connector: Connector, client: MacClient, onOpen: () -> Unit, onDone: () -> Unit) {
    val ctx = LocalContext.current
    val scope = rememberCoroutineScope()
    val haptic = LocalHapticFeedback.current
    val prefs = remember { ctx.getSharedPreferences("lidrop", 0) }
    val conn by client.conn.collectAsState()
    val found by connector.found.collectAsState()
    var last by remember { mutableStateOf(prefs.getString("lastName", null)) }
    val choosing = found.size > 1 && found.none { it.name == last }
    val name = (conn as? Conn.Up)?.mac ?: if (choosing) null else last ?: found.firstOrNull()?.name

    val g = remember { GateState() }
    val t0 = remember { SystemClock.uptimeMillis() }
    var now by remember { mutableLongStateOf(t0) }
    var startedAt by remember { mutableLongStateOf(t0) }
    var failed by remember { mutableStateOf(false) }
    var denied by remember { mutableStateOf(false) }
    var pairing by remember { mutableStateOf(false) }
    var fade by remember { mutableFloatStateOf(1f) }
    val out = remember { Channel<JSONObject>(Channel.UNLIMITED) } // sockets stay off the main thread, in order
    fun send(state: String, p: Float = 0f) { out.trySend(JSONObject().put("t", "pair").put("state", state).put("p", p.toDouble())) }
    LaunchedEffect(Unit) {
        withContext(Dispatchers.IO) {
            for (m in out) {
                if (m.optString("state") == "ping") client.pingAt = SystemClock.uptimeMillis()
                runCatching { client.sendJson(m) }
            }
        }
    }

    fun fire(t: Long) {
        // both screens start the wave at once: the Mac when "burst" reaches it, we that long after sending it
        val lead = (client.pairRtt / 2).coerceIn(0L, 300L)
        g.firedAt = t + lead
        send("burst")
        haptic.performHapticFeedback(HapticFeedbackType.LongPress)
        scope.launch { delay(lead + 120); onOpen(); delay(1000); onDone() }
    }

    LaunchedEffect(Unit) {
        var prev = SystemClock.uptimeMillis()
        while (true) withFrameMillis {
            val t = SystemClock.uptimeMillis()
            val dt = ((t - prev) / 1000f).coerceAtMost(0.05f); prev = t
            val c = client.conn.value
            val up = c is Conn.Up
            val active = !denied
            g.jelly += ((if (active) 1f else 0.25f) - g.jelly) * (1f - exp(-dt * 8f))
            g.link += ((if (up && active) 1f else 0f) - g.link) * (1f - exp(-dt * 9f))
            if (g.firedAt < 0) {
                if (c is Conn.Failed && c.msg == DENIED) denied = true
                if (up && g.upAt < 0) { g.upAt = t; g.sends = 0; haptic.performHapticFeedback(HapticFeedbackType.TextHandleMove) }
                if (!up) g.upAt = -1
                if (active) {
                    // it can only finish on a live link, and it stays short of full until there is one
                    val cap = if (up) (0.86f + 0.14f * (t - g.upAt) / 450f).coerceAtMost(1f) else 0.86f
                    g.fill = (g.fill + dt / 1.1f).coerceAtMost(cap.coerceAtLeast(g.fill))
                    if (up && t - g.lastSend >= 33) {
                        g.lastSend = t
                        if (g.sends++ % 8 == 0) send("ping") else send("hold", g.fill)
                    }
                    if (up && g.fill >= 1f) fire(t)
                    // it never gives up: the moment the computer appears, the connection goes through
                    failed = !up && connector.found.value.isEmpty() && t - startedAt > 15_000
                } else g.fill = (g.fill - dt / 0.3f).coerceAtLeast(0f)
            } else fade = (fade - dt / 0.2f).coerceAtLeast(0f)
            now = t
        }
    }

    BoxWithConstraints(Modifier.fillMaxSize().drawBehind {
        val b = if (g.firedAt < 0 || now < g.firedAt) -1f else (now - g.firedAt) / 1000f
        drawField(g.fill, g.jelly, g.link, b, (now - t0) / 1000f, connector.seamSide())
    }) {
        val r = maxWidth * DROP_R
        val top = maxHeight * DROP_Y
        if (name != null) Text(
            name, Modifier.fillMaxWidth().offset(y = maxHeight * 0.24f).padding(horizontal = 32.dp).graphicsLayer { alpha = fade },
            color = Color.White, fontSize = 26.sp, fontWeight = FontWeight.SemiBold, textAlign = TextAlign.Center, maxLines = 2,
        )
        if (choosing) Row(Modifier.fillMaxWidth().offset(y = maxHeight * 0.24f).padding(horizontal = 24.dp), horizontalArrangement = Arrangement.Center) {
            found.forEach { f ->
                Text(
                    f.name, Modifier.padding(4.dp).clip(CircleShape).background(Color(0x1FFFFFFF))
                        .clickable { prefs.edit().putString("lastName", f.name).apply(); last = f.name }.padding(horizontal = 14.dp, vertical = 10.dp),
                    color = Color.White, fontSize = 15.sp, maxLines = 1,
                )
            }
        }
        Box(
            Modifier.align(Alignment.TopCenter).offset(y = top - r).size(r * 2).clip(CircleShape).pointerInput(Unit) {
                detectTapGestures(onTap = { if (denied) { denied = false; connector.retry() } })
            },
        )
        Text(
            when {
                denied -> "Not allowed. Tap to ask again"
                failed -> "Open lidrop on your computer"
                choosing -> "Choose your computer"
                found.isNotEmpty() || conn is Conn.Connecting -> "Click Allow on your computer"
                else -> "Looking for your computer"
            },
            Modifier.fillMaxWidth().offset(y = top + r * 1.2f + 18.dp).graphicsLayer { alpha = fade },
            color = Color(0x8CFFFFFF), fontSize = 14.sp, textAlign = TextAlign.Center,
        )
        if (failed) TextButton(onClick = { pairing = true }, Modifier.align(Alignment.BottomCenter).navigationBarsPadding().padding(bottom = 12.dp).heightIn(min = 48.dp)) {
            Text("Use pairing code", color = Color(0x8CFFFFFF))
        }
    }
    if (pairing) {
        var code by remember { mutableStateOf("") }
        val go = { pairing = false; failed = false; startedAt = SystemClock.uptimeMillis(); connector.connectManual(code) }
        AlertDialog(
            onDismissRequest = { pairing = false },
            text = {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    OutlinedTextField(code, { code = it }, Modifier.weight(1f), label = { Text("Pairing code or Mac IP") }, singleLine = true)
                    Spacer(Modifier.width(8.dp))
                    TextButton(onClick = {
                        ctx.getSystemService(ClipboardManager::class.java).primaryClip?.takeIf { it.itemCount > 0 }?.getItemAt(0)?.coerceToText(ctx)?.toString()?.let { code = it }
                    }) { Text("Paste") }
                }
            },
            confirmButton = { TextButton(onClick = { go() }) { Text("Connect") } },
        )
    }
}
