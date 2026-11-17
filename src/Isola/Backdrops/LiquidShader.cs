using System.Numerics;
using System.Runtime.InteropServices;

namespace Isola.Backdrops;

/// <summary>Constant buffer of the Liquido shader (5 × float4).</summary>
[StructLayout(LayoutKind.Sequential)]
internal struct LiquidParams
{
    /// <summary>Body x0, y0, x1, y1 in pixels of the backdrop window.</summary>
    public Vector4 Body;

    /// <summary>Top radius, notch flare, bottom radius, DPI scale.</summary>
    public Vector4 Radii;

    /// <summary>1/width, 1/height of the captured image, width, height.</summary>
    public Vector4 Texel;

    /// <summary>Refraction strength, bezel width (DIP), blur level (mip), chromatic aberration (DIP).</summary>
    public Vector4 Look;

    /// <summary>Tint amount, highlight strength, saturation, attached-to-top (1 = notch/strip).</summary>
    public Vector4 Look2;
}

/// <summary>HLSL of the Liquido glass, compiled at runtime with D3DCompiler.</summary>
internal static class LiquidShader
{
    public const string Source = """
cbuffer P : register(b0)
{
    float4 Body;   // x0 y0 x1 y1 (px)
    float4 Radii;  // rTop, flare, rBottom, scale
    float4 Texel;  // 1/w 1/h w h
    float4 Look;   // strength, bezel (dip), blur mip, aberration (dip)
    float4 Look2;  // tint, highlight, saturation, attachedTop
};

Texture2D Src : register(t0);
SamplerState Lin : register(s0);

struct VSOut { float4 pos : SV_Position; };

VSOut VS(uint id : SV_VertexID)
{
    float2 uv = float2((id << 1) & 2, id & 2);
    VSOut o;
    o.pos = float4(uv * float2(2, -2) + float2(-1, 1), 0, 1);
    return o;
}

// Rounded box, different radius for the top and bottom corners.
float sdBody(float2 p)
{
    float2 lo = Body.xy, hi = Body.zw;
    if (Look2.w > 0.5) lo.y -= 400;              // attached to the top edge: no top rim
    float2 c = (lo + hi) * 0.5, he = (hi - lo) * 0.5;
    float2 q0 = p - c;
    float r = (q0.y < 0) ? (Look2.w > 0.5 ? 0 : Radii.x) : Radii.z;
    float2 q = abs(q0) - he + r;
    return min(max(q.x, q.y), 0) + length(max(q, 0)) - r;
}

// Concave notch flares at the top corners (outside a circle, inside a box).
float sdFlare(float2 p, float side)
{
    float f = Radii.y;
    float x = side > 0 ? Body.z : Body.x;
    float2 boxLo = float2(side > 0 ? x : x - f, Body.y);
    float2 boxHi = float2(side > 0 ? x + f : x, Body.y + f);
    float2 bc = (boxLo + boxHi) * 0.5, bh = (boxHi - boxLo) * 0.5;
    float2 q = abs(p - bc) - bh;
    float dBox = length(max(q, 0)) + min(max(q.x, q.y), 0);
    float2 cc = float2(x + side * f, Body.y + f);
    return max(dBox, f - length(p - cc));
}

float sdShape(float2 p)
{
    float d = sdBody(p);
    if (Radii.y > 0.01) d = min(d, min(sdFlare(p, 1), sdFlare(p, -1)));
    return d;
}

float3 Blurred(float2 px, float lod)
{
    float2 uv = px * Texel.xy;
    float2 o = Texel.xy * exp2(lod) * 0.7;
    float3 c = Src.SampleLevel(Lin, uv, lod).rgb * 4;
    c += Src.SampleLevel(Lin, uv + float2( o.x,  o.y), lod).rgb;
    c += Src.SampleLevel(Lin, uv + float2(-o.x,  o.y), lod).rgb;
    c += Src.SampleLevel(Lin, uv + float2( o.x, -o.y), lod).rgb;
    c += Src.SampleLevel(Lin, uv + float2(-o.x, -o.y), lod).rgb;
    c += Src.SampleLevel(Lin, uv + float2( o.x * 1.6, 0), lod).rgb;
    c += Src.SampleLevel(Lin, uv + float2(-o.x * 1.6, 0), lod).rgb;
    c += Src.SampleLevel(Lin, uv + float2(0,  o.y * 1.6), lod).rgb;
    c += Src.SampleLevel(Lin, uv + float2(0, -o.y * 1.6), lod).rgb;
    return c / 12;
}

float4 PS(VSOut i) : SV_Target
{
    float2 p = i.pos.xy;
    float s = Radii.w;
    float d = sdShape(p);
    float alpha = saturate(0.5 - d);
    if (alpha <= 0) return 0;

    // Outward normal from the distance field.
    float e = 0.75;
    float2 n = float2(sdShape(p + float2(e, 0)) - sdShape(p - float2(e, 0)),
                      sdShape(p + float2(0, e)) - sdShape(p - float2(0, e)));
    n = length(n) > 1e-4 ? normalize(n) : float2(0, -1);

    float depth = max(0, -d);                    // px from the edge, inwards
    float bezel = Look.y * s;
    float t = saturate(1 - depth / bezel);       // 1 at the rim, 0 inside
    float bend = t * t * t;

    // Refraction: near the rim read the image further out, like the thick edge of a lens.
    float2 shift = n * bend * Look.x * bezel;
    float2 q = p + shift;

    // Light blur everywhere, a little sharper right at the rim; chromatic split at the rim.
    float lod = Look.z * (1 - 0.35 * bend);
    float ca = Look.w * s * bend;
    float3 col;
    col.r = Blurred(q + n * ca, lod).r;
    col.g = Blurred(q, lod).g;
    col.b = Blurred(q - n * ca, lod).b;

    // Vibrancy, then a dark veil so white text stays readable. The veil adapts: over a bright
    // background (measured on a very blurred copy) it gets darker, like Apple's glass does.
    float l = dot(col, float3(0.2126, 0.7152, 0.0722));
    col = lerp(l.xxx, col, Look2.z);
    float bg = dot(Src.SampleLevel(Lin, p * Texel.xy, 5).rgb, float3(0.2126, 0.7152, 0.0722));
    float veil = saturate(Look2.x + 0.38 * smoothstep(0.3, 0.9, bg));
    col = lerp(col, float3(0.03, 0.03, 0.04), veil);

    // Lighting: specular rim lit from above, a softer bounce at the bottom, an inner glow.
    float2 L = normalize(float2(-0.25, -1));
    float facing = saturate(dot(n, L));
    float back = saturate(dot(n, -L));
    float rim = exp(-depth / (0.9 * s));
    float glow = exp(-depth / (7 * s));
    float hl = Look2.y;
    col += hl * (rim * (0.55 * facing + 0.18 * back + 0.10) + glow * (0.10 * facing + 0.04 * back));

    // Faint top sheen on the upper part of the body (not when attached to the top).
    if (Look2.w < 0.5)
    {
        float h = Body.w - Body.y;
        float v = saturate((p.y - Body.y) / max(1, h));
        col += hl * 0.05 * saturate(1 - v * 2.2);
    }

    col = saturate(col);
    return float4(col * alpha, alpha);
}
""";
}
