import Foundation

/// Compiled when the app starts, like mac/Sources/lidrop/Effects.swift, so building needs no Metal toolchain.
/// Must stay the same formulas as the AGSL in android/.../Light.kt and the Metal source in mac/Sources/lidrop/Effects.swift.
/// Output is premultiplied: added light in rgb, wallpaper occlusion in alpha.
enum FxShaders {
    static let source = """
    #include <metal_stdlib>
    using namespace metal;

    struct VOut { float4 position [[position]]; };

    vertex VOut fx_vertex(uint i [[vertex_id]]) {
        float2 p = float2((i << 1) & 2, i & 2);
        return { float4(p * 2.0 - 1.0, 0.0, 1.0) };
    }

    struct LightU {
        float2 size, origin;
        float side, along, k, head, wid, fan, pale, reach, bloom, bloomR, dimK, flash, front, ring, veil, tail, cool, sat, contrast, disp, warp, grain, streak, time, seed;
    };

    static float wob(float x, float t) {
        return (sin(x + t * 0.31) + 0.7 * sin(x * 2.17 - t * 0.23 + 1.3) + 0.45 * sin(x * 4.31 + t * 0.17 + 4.1)) / 2.15;
    }

    static float shafts(float th, float r, float t, float warp, float contrast) {
        float w = th + warp * (0.05 * sin(r * 2.7 - t * 0.19 + th * 5.0) + 0.025 * sin(r * 5.9 + t * 0.13 - th * 11.0));
        float broad = 0.5 + 0.5 * wob(w * 6.0, t);
        float fine = 0.5 + 0.5 * wob(w * 13.0 + 1.7, t * 1.4);
        return 0.45 + 1.3 * pow(broad * (0.55 + 0.45 * fine), contrast);
    }

    static float3 spectrum(float a) {
        return 0.5 + 0.5 * cos(6.2832 * (0.72 * a - 0.09 - float3(0.0, 0.3333, 0.6667)));
    }

    static float hash(float2 p) {
        p = fract(p * float2(0.1031, 0.1030));
        p += dot(p, p.yx + 33.33);
        return fract((p.x + p.y) * p.x);
    }

    fragment float4 light_fragment(VOut in [[stage_in]], constant LightU &u [[buffer(0)]]) {
        float2 p = in.position.xy;
        float2 uv = p / u.size;
        float2 q = u.side < 0.5 ? uv : u.side < 1.5 ? float2(1.0 - uv.x, uv.y) : u.side < 2.5 ? float2(1.0 - uv.y, uv.x) : uv.yx;
        float x = q.x * 1.6, y = q.y, t = u.time;
        float2 r = float2(x, y) - u.origin;
        float rad = length(r), th = 2.6 * atan2(r.x, r.y);
        float dx = 1.6 - x, dy = (y - u.along) * u.k;
        float d = sqrt(dx * dx + dy * dy);
        th += u.ring * 0.05 * exp(-(d - u.front) * (d - u.front) / 0.05);
        float da = 0.012 * u.disp, dr = 0.05 * u.disp;
        float3 S = float3(shafts(th - da, rad * (1.0 + dr), t, u.warp, u.contrast), shafts(th, rad, t, u.warp, u.contrast), shafts(th + da, rad * (1.0 - dr), t, u.warp, u.contrast));
        float3 D = d * (1.0 + 0.035 * u.disp * float3(-1.0, 0.0, 1.0));
        float a = (th - (u.head - u.wid)) / u.wid + 0.05 * u.warp * wob(th * 6.0, t);
        float win = smoothstep(-0.55, 0.25, a) * (1.0 - u.tail * smoothstep(0.55, 1.5, a));
        float3 col = mix(float3(1.0), spectrum(a), u.sat);
        col = mix(col, float3(1.0, 0.98, 0.95), u.pale * smoothstep(0.7, 1.25, a));
        col = mix(col, float3(0.60, 0.86, 1.0), u.cool);
        float haze = 0.78 + 0.22 * wob(rad * 3.0 + th * 2.0, t * 0.7);
        float nearF = 1.0 - smoothstep(u.reach - 0.65, u.reach + 0.45, d);
        float band = 0.16 + 0.84 * exp(-(y - u.along) * (y - u.along) / 0.16);
        float3 X = col * S * u.fan * win * nearF * haze * band;
        float R2 = u.bloomR * u.bloomR;
        X += u.bloom * (0.72 * exp(-D * D / R2) + 0.5 * exp(-D * D / (R2 * 0.16))) * float3(1.0, 0.98, 0.95);
        X += u.streak * u.bloom * exp(-dy * dy / 0.01) * exp(-dx * dx / 0.9) * float3(0.62, 0.78, 1.0);
        float3 over = max(D - u.front, float3(0.0));
        float fe = 0.05 + 0.1 * u.front;
        X += u.flash * exp(-over * over / (fe * fe)) + u.veil;
        float3 rr = (d * (1.0 + 0.028 * u.disp * float3(-1.0, 0.0, 1.0)) - u.front) / (0.02 + 0.03 * u.front);
        X += u.ring * exp(-rr * rr);
        float3 L = 1.0 - exp(-X);
        float peak = max(L.r, max(L.g, L.b));
        float cover = mix(dot(L, float3(0.2126, 0.7152, 0.0722)), peak, 0.8);
        cover = pow(cover, 1.0 + 0.9 * u.tail);
        float T = (1.0 - u.dimK * (1.0 - 0.8 * nearF) * (1.0 - peak)) * (1.0 - cover);
        float n = hash(p + u.seed * float2(37.0, 17.0)) + hash(p.yx + u.seed * float2(11.0, 53.0)) - 1.0;
        L += n * (1.0 + u.grain * sqrt(peak)) / 255.0;
        return float4(max(L, float3(0.0)), clamp(1.0 - T + n / 255.0, 0.0, 1.0));
    }

    struct PairU { float2 size, drop, seam; float dropR, fill, jelly, time, front, fade, men; };

    static float3 backdrop(float2 p, float asp) {
        float v = length(p - float2(0.5, asp * 0.4));
        float3 c = mix(float3(0.085, 0.09, 0.1), float3(0.016, 0.017, 0.02), smoothstep(0.0, 1.25, v));
        float2 a = p - float2(0.2, asp * 0.2), b = p - float2(0.85, asp * 0.72);
        return c + float3(0.75, 0.85, 1.0) * (0.045 * exp(-dot(a, a) / 0.2) + 0.03 * exp(-dot(b, b) / 0.16));
    }

    static float3 shade(float2 q, float R, float3 under) {
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

    /// The connect ceremony: a drop of liquid glass, see PAIR_AGSL in android/.../Pair.kt. Lengths in screen widths.
    fragment float4 pair_fragment(VOut in [[stage_in]], constant PairU &u [[buffer(0)]]) {
        float2 c = in.position.xy;
        float2 p = c / u.size.x;
        float asp = u.size.y / u.size.x, t = u.time, px = 1.5 / u.size.x, fill = u.fill;
        float3 bg = backdrop(p, asp), col = bg;
        float2 q;
        if (u.men > 0.0) {
            q = p - u.seam;
            col = mix(shade(q, u.men, bg), col, smoothstep(-px, px, length(q) - u.men));
        }
        q = p - u.drop;
        float a = atan2(q.y, q.x);
        float R = u.dropR * (1.0 + 0.1 * fill) * (1.0 + u.jelly * (0.03 * sin(2.0 * a + t * 2.3) + 0.02 * sin(3.0 * a - t * 1.9) + 0.012 * sin(5.0 * a + t * 1.3)));
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
        if (u.front >= 0.0) {
            float x = length(p - u.seam) - u.front, w = 0.037 + 0.05 * u.front;
            alpha = smoothstep(-w, w * 0.3, x);
            float r = x / (w * 0.7);
            float rim = exp(-r * r) * u.fade;
            col = col * alpha + rim * 0.42 * float3(0.92, 0.95, 1.0);
            alpha = max(alpha, rim * 0.42);
        }
        float n = fract(52.9829189 * fract(dot(c, float2(0.06711056, 0.00583715)))) - 0.5;
        return float4(max(col + n / 255.0, float3(0.0)), clamp(alpha, 0.0, 1.0));
    }
    """
}
