// hud.metal — the HUD's SDF pass (wayfinder #356). A port of the WebGL fragment shader in
// prototypes/hud-micro-motion/index.html: every mark is a rounded box, unioned with a
// polynomial smooth-min (the "goo") and wrapped in an exponential soft glow. One
// full-screen triangle, uniforms via setFragmentBytes (no buffers).
#include <metal_stdlib>
using namespace metal;

#define MAXP 48

// Must match `Uniforms` in main.zig byte for byte (1760 bytes).
struct U {
    float2 res;       // drawable size, px
    float  px;        // px per pt (backing scale)
    int    count;     // live shapes
    float  k;         // smooth-union blend radius, pt (0 = hard union)
    float  glow;      // glow strength (0 = off)
    float2 pad;
    float4 geo[MAXP]; // centre (pt, y down), size (pt)
    float4 col[MAXP]; // straight sRGB + final alpha
    float  fade[MAXP];// content alpha — fading shapes also shrink
};

struct VOut { float4 pos [[position]]; };

vertex VOut vs(uint vid [[vertex_id]]) {
    float2 p = float2((vid << 1) & 2, vid & 2);   // (0,0) (2,0) (0,2)
    VOut o;
    o.pos = float4(p * 2.0 - 1.0, 0.0, 1.0);
    return o;
}

static float sdRoundBox(float2 p, float2 b, float r) {
    float2 q = abs(p) - b + r;
    return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - r;
}

fragment float4 fs(VOut in [[stage_in]], constant U& u [[buffer(0)]]) {
    float2 p = in.pos.xy / u.px;                  // Metal's origin is top-left: already y down
    float d = 1e5;
    float4 col = float4(0.0);
    for (int i = 0; i < u.count; i++) {
        float4 g = u.geo[i];
        float4 c = u.col[i];
        float2 b = max(g.zw * 0.5, float2(0.001));
        float di = sdRoundBox(p - g.xy, b, min(b.x, b.y)) + (1.0 - u.fade[i]) * 1.2;
        if (u.k < 0.01) {
            if (di < d) { d = di; col = c; }
        } else {
            float h = clamp(0.5 + 0.5 * (di - d) / u.k, 0.0, 1.0);
            d = mix(di, d, h) - u.k * h * (1.0 - h);
            col = mix(c, col, h);
        }
    }
    float cov = clamp(0.5 - d * u.px, 0.0, 1.0);
    float a = col.a * cov;
    float glow = u.glow * col.a * exp(-max(d, 0.0) / 3.5) * 0.6;
    float outA = a + glow * (1.0 - a);
    return float4(col.rgb * outA, outA);          // premultiplied, as CAMetalLayer expects
}
