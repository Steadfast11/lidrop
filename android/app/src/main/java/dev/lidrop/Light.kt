package dev.lidrop

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapShader
import android.graphics.Canvas
import android.graphics.Matrix
import android.graphics.Paint
import android.graphics.PorterDuff
import android.graphics.PorterDuffXfermode
import android.graphics.RadialGradient
import android.graphics.RectF
import android.graphics.RenderNode
import android.graphics.RuntimeShader
import android.graphics.Shader
import android.graphics.SweepGradient
import android.os.Build
import android.os.SystemClock
import android.util.Log
import androidx.annotation.RequiresApi
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.size
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.runtime.withFrameMillis
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.drawscope.DrawScope
import androidx.compose.ui.graphics.drawscope.drawIntoCanvas
import androidx.compose.ui.graphics.nativeCanvas
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.delay
import kotlin.math.PI
import kotlin.math.abs
import kotlin.math.exp
import kotlin.math.sin
import kotlin.math.sqrt
import kotlin.random.Random

/** Frame clock for the light effects (ms). Only read in draw lambdas, so a tick redraws without recomposing. */
object FxClock {
    var now by mutableLongStateOf(0L)
}

/** One switchable look of the light field. Keep in step with `LightLook.all` in mac/Sources/lidrop/Effects.swift. */
class FxLook(
    val gain: Float, val sat: Float, val contrast: Float, val disp: Float, val warp: Float, val grain: Float, val dim: Float,
    val bloom: Float, val bloomR: Float, val pale: Float, val streak: Float, val flash: Float, val flashTau: Float, val flashHold: Float, val reach: Float,
    val dissolve: Float,
)

/** The look in use: "Light" chip in the app, or `adb shell am start -n dev.lidrop/.MainActivity --es look A`. */
object Looks {
    private val all = mapOf(
        "A" to FxLook(0.62f, 0.52f, 1.4f, 0.7f, 0.8f, 1.2f, 0.18f, 0.55f, 0.20f, 0.55f, 0f, 2.0f, 0.08f, 0.08f, 0.80f, 1.0f),
        "B" to FxLook(0.85f, 0.50f, 1.5f, 1.0f, 1.0f, 1.6f, 0.62f, 0.90f, 0.26f, 0.80f, 0.04f, 4.0f, 0.09f, 0.12f, 0.96f, 1.2f),
        "C" to FxLook(1.90f, 0.84f, 1.9f, 1.5f, 1.2f, 2.2f, 0.76f, 1.50f, 0.34f, 0.90f, 0.20f, 7.0f, 0.10f, 0.16f, 1.15f, 1.5f),
    )
    var name by mutableStateOf("B")
        private set
    var cur = all.getValue("B")
        private set
    var forceFallback = false // debug: draw the API < 33 gradients on any device

    fun load(ctx: Context) { pick(ctx.getSharedPreferences("light", 0).getString("look", "B") ?: "B") }
    fun pick(n: String) { all[n]?.let { cur = it; name = n } }
    fun save(ctx: Context, n: String) { pick(n); ctx.getSharedPreferences("light", 0).edit().putString("look", name).apply() }
    fun next(ctx: Context) = save(ctx, when (name) { "A" -> "B"; "B" -> "C"; else -> "A" })
}

/** The Mac's screen in mm (from `welcome`): the dome is one physical circle, so on the phone it overflows the screen. */
object Seam {
    @Volatile var macW = 300f
    @Volatile var macH = 195f
    @Volatile var macEdge: String? = null // the Mac edge the phone sits at, from `welcome`
}

/** Pixels per real millimetre of this display; set once by the activity. */
object LocalPxPerMm { @Volatile var value = 16f }

/** Critically damped spring, integrated exactly so any frame time is stable. ω = 3.9 / T settles 90 % of the way in T. */
class Spring {
    var x = 0f
    private var v = 0f
    fun reset() { x = 0f; v = 0f }
    fun step(to: Float, w: Float, dt: Float) {
        val d = x - to; val c = v + w * d; val e = exp(-w * dt)
        x = to + (d + c * dt) * e
        v = (c - w * (d + c * dt)) * e
    }
}

/** Light-effects state for one drag (sender or receiver). All fields are read in the draw phase only. */
class FxState {
    var overhang by mutableFloatStateOf(0f)
    var along by mutableFloatStateOf(0.5f)
    var side by mutableStateOf(Side.LEFT)
    var cx by mutableFloatStateOf(0f)   // tile centre, used by the burst
    var cy by mutableFloatStateOf(0f)
    var burstAt by mutableLongStateOf(-1L) // uptime ms of the commit, -1 = none
    var cancelAt by mutableLongStateOf(-1L)
    var running by mutableStateOf(false)
    var strong = true // receiving screen: full v4; sending phone: subtle accompaniment
    private var gen = 0
    // spring-smoothed charge p (0..1); plain fields advanced from the draw loop (not snapshot state, so no invalidation)
    val charge = Spring()
    var startT = 0L
    var seed = 0f
    var peak = 0f   // highest charge of this drag, read by the commit
    val energy = Spring() // 0..1, how fast the drag is moving right now
    var lastO = 0f
    var pxPerMm = 16f // set from the display, so the dome matches the Mac's in real millimetres
    var lastA = 0.5f
    private var armed = false
    var armedAt by mutableLongStateOf(-1L) // uptime ms the drag crossed the commit line; also drives the haptic
    var lastT = 0L

    fun begin(s: Side): Int {
        side = s; overhang = 0f; burstAt = -1; cancelAt = -1; running = true; charge.reset(); energy.reset(); peak = 0f; armed = false; armedAt = -1
        FxClock.now = SystemClock.uptimeMillis(); lastT = FxClock.now; startT = lastT
        return ++gen
    }
    /** Sets the overhang and notices the commit line (0.5 for a phone drag, 0.83 for the Mac's edge zone). */
    fun over(v: Float, line: Float = 0.5f) {
        overhang = v
        if (!armed && v >= line && burstAt < 0) { armed = true; armedAt = SystemClock.uptimeMillis() }
        else if (armed && v < line - 0.08f) { armed = false; armedAt = -1 }
    }
    fun commit(): Int { burstAt = SystemClock.uptimeMillis(); return ++gen }
    fun cancel(): Int { cancelAt = SystemClock.uptimeMillis(); return ++gen }
    fun stillCurrent(g: Int) = g == gen
    /** How long the overlay must stay up after a commit for the field to finish dissolving. */
    fun endMs() = (Looks.cur.dissolve * 1000).toLong() + 150

    /** Commit, in tile sizes along the inward axis: the wave carries the receiver's tile deep in; the sender's leaves through the seam. */
    fun thrust(flight: Float): Float {
        val b = burstAt
        if (b < 0) return 0f
        val since = (FxClock.now - b) / 1000f
        if (!strong) return -1.2f * (1f - exp(-since / 0.05f)) // keeps going through the seam, no pause
        return flight * (1f - exp(-since * 9f) * (1f + since * 9f))
    }

    /** The sender's tile is gone once the wave reaches the seam. */
    fun tileAlpha(): Float {
        val b = burstAt
        if (b < 0) return 1f
        return 1f - ((FxClock.now - b - 50) / 70f).coerceIn(0f, 1f)
    }

    /** Where the entering tile's centre is, for the receiver's burst (depth = visible fraction of the tile). */
    fun placeEntering(s: Side, depth: Float, alongF: Float, sw: Float, sh: Float, w: Float) {
        val d = depth * w
        when (s) {
            Side.LEFT -> { cx = -w / 2 + d; cy = alongF * sh }
            Side.RIGHT -> { cx = sw + w / 2 - d; cy = alongF * sh }
            Side.TOP -> { cy = -w / 2 + d; cx = alongF * sw }
            Side.BOTTOM -> { cy = sh + w / 2 - d; cx = alongF * sw }
        }
    }
}

/** Must stay the same formula as the Metal shader in mac/Sources/lidrop/Effects.swift. Output is premultiplied: added light in rgb, wallpaper occlusion in alpha. */
private const val AGSL = """
uniform float2 size;
uniform float2 origin;
uniform float side;
uniform float along, k, head, wid, fan, pale, reach, bloom, bloomR, dimK, flash, front, ring, veil, tail, cool, sat, contrast, disp, warp, grain, streak, time, seed;
float wob(float x, float t) {
    return (sin(x + t * 0.31) + 0.7 * sin(x * 2.17 - t * 0.23 + 1.3) + 0.45 * sin(x * 4.31 + t * 0.17 + 4.1)) / 2.15;
}
float shafts(float th, float r, float t) {
    float w = th + warp * (0.05 * sin(r * 2.7 - t * 0.19 + th * 5.0) + 0.025 * sin(r * 5.9 + t * 0.13 - th * 11.0));
    float broad = 0.5 + 0.5 * wob(w * 6.0, t);
    float fine = 0.5 + 0.5 * wob(w * 13.0 + 1.7, t * 1.4);
    return 0.45 + 1.3 * pow(broad * (0.55 + 0.45 * fine), contrast);
}
float3 spectrum(float a) {
    return 0.5 + 0.5 * cos(6.2832 * (0.72 * a - 0.09 - float3(0.0, 0.3333, 0.6667)));
}
float hash(float2 p) {
    p = fract(p * float2(0.1031, 0.1030));
    p += dot(p, p.yx + 33.33);
    return fract((p.x + p.y) * p.x);
}
half4 main(float2 p) {
    float2 uv = p / size;
    float2 q = side < 0.5 ? uv : side < 1.5 ? float2(1.0 - uv.x, uv.y) : side < 2.5 ? float2(1.0 - uv.y, uv.x) : uv.yx;
    float x = q.x * 1.6, y = q.y, t = time;
    float2 r = float2(x, y) - origin;
    float rad = length(r), th = 2.6 * atan(r.x, r.y);
    float dx = 1.6 - x, dy = (y - along) * k;
    float d = sqrt(dx * dx + dy * dy);
    th += ring * 0.05 * exp(-(d - front) * (d - front) / 0.05);
    float da = 0.012 * disp, dr = 0.05 * disp;
    float3 S = float3(shafts(th - da, rad * (1.0 + dr), t), shafts(th, rad, t), shafts(th + da, rad * (1.0 - dr), t));
    float3 D = d * (1.0 + 0.035 * disp * float3(-1.0, 0.0, 1.0));
    float a = (th - (head - wid)) / wid + 0.05 * warp * wob(th * 6.0, t);
    float win = smoothstep(-0.55, 0.25, a) * (1.0 - tail * smoothstep(0.55, 1.5, a));
    float3 col = mix(float3(1.0), spectrum(a), sat);
    col = mix(col, float3(1.0, 0.98, 0.95), pale * smoothstep(0.7, 1.25, a));
    col = mix(col, float3(0.60, 0.86, 1.0), cool);
    float haze = 0.78 + 0.22 * wob(rad * 3.0 + th * 2.0, t * 0.7);
    float nearF = 1.0 - smoothstep(reach - 0.65, reach + 0.45, d);
    float band = 0.16 + 0.84 * exp(-(y - along) * (y - along) / 0.16);
    float3 X = col * S * fan * win * nearF * haze * band;
    float R2 = bloomR * bloomR;
    X += bloom * (0.72 * exp(-D * D / R2) + 0.5 * exp(-D * D / (R2 * 0.16))) * float3(1.0, 0.98, 0.95);
    X += streak * bloom * exp(-dy * dy / 0.01) * exp(-dx * dx / 0.9) * float3(0.62, 0.78, 1.0);
    float3 over = max(D - front, float3(0.0));
    float fe = 0.05 + 0.1 * front;
    X += flash * exp(-over * over / (fe * fe)) + veil;
    float3 rr = (d * (1.0 + 0.028 * disp * float3(-1.0, 0.0, 1.0)) - front) / (0.02 + 0.03 * front);
    X += ring * exp(-rr * rr);
    float3 L = 1.0 - exp(-X);
    float peak = max(L.r, max(L.g, L.b));
    float cover = mix(dot(L, float3(0.2126, 0.7152, 0.0722)), peak, 0.8);
    cover = pow(cover, 1.0 + 0.9 * tail);
    float T = (1.0 - dimK * (1.0 - 0.8 * nearF) * (1.0 - peak)) * (1.0 - cover);
    float n = hash(p + seed * float2(37.0, 17.0)) + hash(p.yx + seed * float2(11.0, 53.0)) - 1.0;
    L += n * (1.0 + grain * sqrt(peak)) / 255.0;
    return half4(max(L, float3(0.0)), clamp(1.0 - T + n / 255.0, 0.0, 1.0));
}
"""

/** Shaders/paints are created once and reused every frame (no per-frame allocation). */
private object Fx {
    val m = Matrix()
    val rect = RectF()
    val dim = Paint().apply { color = 0xFF000000.toInt() }
    val paint = Paint()
    val add = Paint(Paint.ANTI_ALIAS_FLAG).apply { xfermode = PorterDuffXfermode(PorterDuff.Mode.ADD) }
    val glow = RadialGradient(0f, 0f, 1f, intArrayOf(0xFFFFFFFF.toInt(), 0x88FFFFFF.toInt(), 0x00FFFFFF), floatArrayOf(0f, 0.5f, 1f), Shader.TileMode.CLAMP)
    val sweep = SweepGradient(0f, 0f,
        intArrayOf(0x00CFEFFF, 0x8868DDF0.toInt(), 0x8878EEB4.toInt(), 0x88E4F2A0.toInt(), 0x88FFC88C.toInt(), 0x88FF9C9C.toInt(), 0x88EAA8E6.toInt(), 0x00EAA8E6),
        floatArrayOf(0f, 0.016f, 0.03f, 0.044f, 0.06f, 0.076f, 0.092f, 0.115f))
    // full-size grain tile: the field itself renders at 1/3 size, where grain would blur away and bands could show
    val grainMatrix = Matrix()
    val grain = Paint().apply {
        xfermode = PorterDuffXfermode(PorterDuff.Mode.ADD)
        val rng = Random(7)
        val px = IntArray(256 * 256) { (rng.nextInt(9) shl 24) or 0xFFFFFF }
        shader = BitmapShader(Bitmap.createBitmap(px, 256, 256, Bitmap.Config.ARGB_8888), Shader.TileMode.REPEAT, Shader.TileMode.REPEAT)
    }
}

@RequiresApi(33)
private object Rays {
    val shader: RuntimeShader? = runCatching { RuntimeShader(AGSL) }.onFailure { Log.e("lidrop", "light shader failed, using gradients", it) }.getOrNull()
    val node = RenderNode("lidrop-rays").apply { setUseCompositingLayer(true, null) }
}
private const val LAYER = 3f
private const val BEAT = 0.09f // seconds of inhale after the commit
private const val RISE = 0.22f // the tile flies first: the dome only opens as it arrives

private fun smooth(a: Float, b: Float, x: Float): Float { val t = ((x - a) / (b - a)).coerceIn(0f, 1f); return t * t * (3f - 2f * t) }
private fun lerp(a: Float, b: Float, t: Float) = a + (b - a) * t

private fun tone(x: Float) = 1f - exp(-x)

/**
 * Light effects v5 (docs/PROTOCOL.md). The charge `p` follows proximity on a critically damped spring (90 % in ~350 ms up,
 * ~450 ms down) and only moves a dozen scalars; the picture is one continuous per-pixel light field: spectral shafts from
 * a single point beyond the screen, bloom at the tile and the landing flash, tone mapped so highlights roll off.
 * The sending phone (`strong` = false) stays subtle so its UI stays readable.
 */
fun DrawScope.drawLight(fx: FxState, dens: Float, tilePx: Float) {
    val now = FxClock.now // read → redraw every frame while the overlay is running
    val w = size.width; val h = size.height
    val lk = Looks.cur
    fx.pxPerMm = LocalPxPerMm.value

    // ---- charge p ----
    val dt = (now - fx.lastT).coerceIn(0L, 64L) / 1000f; fx.lastT = now
    val burstAt = fx.burstAt
    val since = if (burstAt >= 0) (now - burstAt) / 1000f else -1f
    val target: Float; val rate: Float
    if (burstAt >= 0) { target = 1f; rate = 30f }
    else if (fx.cancelAt >= 0) { target = 0f; rate = 8.6f }
    else {
        val o = fx.overhang // the sender's light pours across: it peaks early and thins as the receiver's takes over
        target = if (fx.strong) smooth(0f, 0.5f, o) else smooth(0f, 0.25f, o) * (1f - 0.55f * smooth(0.25f, 1f, o))
        rate = if (target > fx.charge.x) 3.9f else 8.6f
    }
    fx.charge.step(target, rate, dt)
    val pv = fx.charge.x
    val moved = (abs(fx.overhang - fx.lastO) + abs(fx.along - fx.lastA)) / dt.coerceAtLeast(0.001f)
    fx.lastO = fx.overhang; fx.lastA = fx.along
    fx.energy.step((moved * 0.35f).coerceAtMost(1f), 6f, dt)
    val energy = fx.energy.x
    if (pv > fx.peak) fx.peak = pv
    val burst = since >= 0f
    if (pv < 0.004f && !burst) return
    if (since > lk.dissolve) return

    val along0 = fx.along
    val tt0 = (now - fx.startT) / 1000f + 3f
    val breath = sin(tt0 * 1.9f)
    val q = if (burst) maxOf(fx.peak, 0.6f) else pv
    val bigP = smooth(0f, 1f, q)
    var head = -0.05f + 0.74f * bigP + 0.25f * (along0 - 0.5f)
    var wid = 0.95f - 0.42f * bigP
    var fan = lk.gain * smooth(0.05f, 0.35f, q) * (1f + 0.1f * breath) * (1f + 0.5f * energy)
    var pale = lk.pale * smooth(0.4f, 1f, q)
    var reach = 1.9f - 0.8f * bigP
    var bloom = lk.bloom * bigP * (0.4f + 0.6f * bigP) * (1f + 0.08f * sin(tt0 * 1.9f + 0.6f))
    var bloomR = 0.2f + lk.bloomR * bigP
    var dim = lk.dim * smooth(0.08f, 0.9f, q)
    var flash = 0f; var front = 0f; var ring = 0f; var veil = 0f; var tail = 0f; var cool = 0f
    var k = if (fx.strong) 1f else 0.55f // the sender only accompanies the drag
    if (!burst && fx.armedAt >= 0) { // crossing the commit line: one quiet pulse says "you can let go"
        val age = (now - fx.armedAt) / 1000f
        val e = smooth(0f, 0.04f, age) * exp(-age / 0.42f)
        bloom *= 1f + 0.9f * e
        ring = 0.35f * e
        front = 0.05f + 0.95f * (1f - exp(-age / 0.3f))
    }
    if (burst) { // both screens show the same dome, centred on the seam, at the same physical size
        val tEnd = lk.dissolve; val hold = lk.flashHold
        val end = 1f - smooth(0.55f * tEnd, tEnd, since)
        val t = (since - BEAT - RISE).coerceAtLeast(0f) // the same instant on both screens: one circle
        val side = fx.side == Side.LEFT || fx.side == Side.RIGHT
        val phoneMm = (if (side) w else h) / fx.pxPerMm
        val scale = (if (side) Seam.macW else Seam.macH) / phoneMm
        front = (0.04f + lk.reach * (1f - exp(-t / 0.22f))) * scale // the rim keeps travelling, slowing down
        flash = lk.flash * smooth(0f, 0.05f, t) * exp(-(t - hold).coerceAtLeast(0f) / lk.flashTau) * end
        ring = 0.7f * smooth(0f, 0.03f, t) * exp(-(t - 0.22f).coerceAtLeast(0f) / 0.2f) * end
        veil = 0.14f * lk.flash / 4f * smooth(0f, 0.03f, t) * exp(-t / 0.09f)
    }
    if (burst && !fx.strong) { // the light drains into the seam and the bands leave through it
        val end = 1f - smooth(0.385f, 0.7f, since)
        head += 0.5f * smooth(0f, 0.5f, since)
        fan *= exp(-since / 0.22f) * end
        bloom *= exp(-since / 0.16f) * end
        dim *= exp(-since / 0.25f) * end
        k = lerp(k, 1f, smooth(0f, 0.08f, since))
    } else if (burst) { // inhale for one beat, then the tile leaves and the fan swings away as the dome opens
        val tEnd = lk.dissolve; val hold = lk.flashHold
        val end = 1f - smooth(0.55f * tEnd, tEnd, since)
        val pre = smooth(0f, BEAT, since) * (1f - smooth(BEAT, BEAT + 0.05f, since))
        bloomR *= 1f - 0.45f * pre
        bloom *= 1f + 0.6f * pre
        dim *= 1f + 0.25f * pre
        val t = (since - BEAT).coerceAtLeast(0f)
        head -= 0.95f * smooth(0.03f, 0.75f, t)
        tail = smooth(0.04f, 0.35f, t)
        cool = smooth(0.2f, 0.5f, t)
        pale *= 1f - smooth(0f, 0.2f, t)
        wid = lerp(wid, 0.34f, smooth(0.1f, 0.7f, t))
        fan *= exp(-(t - 0.6f * hold).coerceAtLeast(0f) / (0.3f * tEnd)) * end
        reach = lerp(reach, 2.4f, smooth(0f, 0.2f, t))
        bloom *= exp(-(t - hold).coerceAtLeast(0f) / 0.2f) * end
        dim *= (1f - 0.45f * smooth(0f, 0.15f, t)) * exp(-(t - 0.5f * hold).coerceAtLeast(0f) / (0.25f * tEnd)) * end
    }

    val s = fx.side
    val horiz = s == Side.LEFT || s == Side.RIGHT
    val ln = if (horiz) w else h // inward length
    val lc = if (horiz) h else w // edge length
    val along = ((if (horiz) fx.cy else fx.cx) / lc).coerceIn(0f, 1f)
    val shape = lc / (ln / 1.6f)
    val tt = tt0
    fx.seed = if (fx.seed >= 251f) 0f else fx.seed + 1f
    val rays = if (Build.VERSION.SDK_INT >= 33 && !Looks.forceFallback) Rays.shader else null

    drawIntoCanvas { cv ->
        val c = cv.nativeCanvas
        if (rays != null && Build.VERSION.SDK_INT >= 33) {
            val u = rays
            u.setFloatUniform("origin", 0.42f * 1.6f + 0.02f * sin(tt * 0.3f), -2.1f)
            u.setFloatUniform("side", when (s) { Side.RIGHT -> 0f; Side.LEFT -> 1f; Side.TOP -> 2f; else -> 3f })
            u.setFloatUniform("along", along); u.setFloatUniform("k", shape)
            u.setFloatUniform("head", head); u.setFloatUniform("wid", wid)
            u.setFloatUniform("fan", fan * k); u.setFloatUniform("pale", pale); u.setFloatUniform("reach", reach)
            u.setFloatUniform("bloom", bloom * (0.5f + 0.5f * k)); u.setFloatUniform("bloomR", bloomR)
            u.setFloatUniform("dimK", dim * k)
            u.setFloatUniform("flash", flash * k); u.setFloatUniform("front", front); u.setFloatUniform("ring", ring * k)
            u.setFloatUniform("veil", veil * k); u.setFloatUniform("tail", tail); u.setFloatUniform("cool", cool)
            u.setFloatUniform("sat", lk.sat); u.setFloatUniform("contrast", lk.contrast); u.setFloatUniform("disp", lk.disp)
            u.setFloatUniform("warp", lk.warp * (1f + 1.5f * energy)); u.setFloatUniform("grain", 0f); u.setFloatUniform("streak", lk.streak)
            u.setFloatUniform("time", tt * 2.6f); u.setFloatUniform("seed", fx.seed)
            // the field has no fine detail: rasterise at 1/3 size in a layer and scale up, a full 90 Hz screen costs too much
            val lw = (w / LAYER).toInt().coerceAtLeast(1); val lh = (h / LAYER).toInt().coerceAtLeast(1)
            u.setFloatUniform("size", lw.toFloat(), lh.toFloat())
            val node = Rays.node
            if (node.width != lw || node.height != lh) node.setPosition(0, 0, lw, lh)
            Fx.paint.shader = u
            val rec = node.beginRecording(lw, lh)
            rec.drawRect(0f, 0f, lw.toFloat(), lh.toFloat(), Fx.paint)
            node.endRecording()
            c.save(); c.scale(w / lw, h / lh); c.drawRenderNode(node); c.restore()
            Fx.grainMatrix.setTranslate(fx.seed * 61f, fx.seed * 37f)
            Fx.grain.shader.setLocalMatrix(Fx.grainMatrix)
            Fx.grain.alpha = (255 * (lk.grain / 2.2f) * (tone(fan + bloom + flash) * k).coerceAtMost(1f)).toInt()
            c.drawRect(0f, 0f, w, h, Fx.grain)
        } else {
            drawFallback(c, w, h, s, along, head, tone(fan) * k, bloomR, tone(bloom) * (0.5f + 0.5f * k), dim * k, front, tone(flash) * k, ln)
        }
    }
}

/** API < 33: the same picture from fixed gradients (a sweep fan around the same point, on side edges only). */
private fun drawFallback(c: Canvas, w: Float, h: Float, s: Side, along: Float, head: Float, fan: Float, bloomR: Float, bloom: Float, dim: Float, front: Float, flash: Float, ln: Float) {
    Fx.dim.alpha = (255 * dim * 0.6f).toInt()
    c.drawRect(0f, 0f, w, h, Fx.dim)
    val unit = ln / 1.6f
    if (s == Side.LEFT || s == Side.RIGHT) {
        val right = s == Side.RIGHT
        val deg = (head * 180f / PI.toFloat())
        Fx.m.setScale(if (right) 1f else -1f, 1f)
        Fx.m.preRotate(90f - deg)
        Fx.m.postTranslate(if (right) 0.42f * w else 0.58f * w, -0.5f * h)
        Fx.sweep.setLocalMatrix(Fx.m)
        Fx.add.shader = Fx.sweep; Fx.add.alpha = (255 * fan.coerceAtMost(1f)).toInt()
        c.drawRect(0f, 0f, w, h, Fx.add)
    }
    val ex = when (s) { Side.LEFT -> 0f; Side.RIGHT -> w; else -> along * w }
    val ey = when (s) { Side.TOP -> 0f; Side.BOTTOM -> h; else -> along * h }
    disc(c, ex, ey, bloomR * unit * 2.4f, bloom)
    disc(c, ex, ey, (front + 0.3f) * unit * 1.6f, flash)
}

private fun disc(c: Canvas, x: Float, y: Float, r: Float, a: Float) {
    if (a < 0.01f || r < 1f) return
    Fx.m.setScale(r, r); Fx.m.postTranslate(x, y)
    Fx.glow.setLocalMatrix(Fx.m)
    Fx.add.shader = Fx.glow; Fx.add.alpha = (255 * a.coerceAtMost(1f)).toInt()
    Fx.rect.set(x - r, y - r, x + r, y + r)
    c.drawRect(Fx.rect, Fx.add)
}

/** Debug: approach, hold and landing with no Mac attached, the same timeline as mac/tools/light_lab.swift. */
suspend fun lightDemo(fx: FxState, sw: Float, sh: Float, tile: Float, sender: Boolean = false) {
    fx.strong = !sender
    fx.begin(Side.RIGHT)
    val t0 = FxClock.now
    while (true) {
        val t = (withFrameMillis { it } - t0) / 1000f
        if (t >= 2.8f) break
        val over = if (t < 1.6f) 0.8f * t / 1.6f else if (t < 2.6f) 0.8f else 0.8f + (t - 2.6f)
        fx.over(over); fx.along = 0.45f
        fx.placeEntering(Side.RIGHT, over, 0.45f, sw, sh, tile)
    }
    val g = fx.commit()
    delay(fx.endMs())
    if (fx.stillCurrent(g)) fx.running = false
}

/** Debug backdrop for the demo, the colours of mac/tools/backdrop.swift. */
@Composable
fun DemoBackdrop() {
    Box(Modifier.fillMaxSize().background(Brush.verticalGradient(listOf(Color(0xFF29C7E6), Color(0xFF1A809E), Color(0xFF0D2B3D)))))
}

private var warmed = false

/** Compiles the shader on the first frame of the app, so the first drag does not stall ~200 ms on the A17. */
@Composable
fun LightPrewarm() {
    if (warmed || Build.VERSION.SDK_INT < 33) return
    Box(Modifier.size(1.dp).drawBehind {
        val u = Rays.shader ?: return@drawBehind
        warmed = true
        u.setFloatUniform("size", 1f, 1f)
        Fx.paint.shader = u
        drawIntoCanvas { it.nativeCanvas.drawRect(0f, 0f, 1f, 1f, Fx.paint) }
    })
}

@Composable
fun LightOverlay(fx: FxState, tilePx: Float) {
    val dens = LocalDensity.current.density
    if (fx.running) Box(Modifier.fillMaxSize().drawBehind { drawLight(fx, dens, tilePx) })
}
