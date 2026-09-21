#include "common.glsl"

// Position the FragCoord origin to the upper left
// so as to align with our texture's directionality.
layout(origin_upper_left) in vec4 gl_FragCoord;

layout(binding = 0) uniform sampler2D image;

flat in vec4 bg_color;
flat in vec2 offset;
flat in vec2 scale;
flat in float opacity;
flat in uint repeat;
flat in uint nv12;

layout(location = 0) out vec4 out_FragColor;

// Chroma is interleaved in the lower third of the R8 texture. Interpolate
// U and V independently so filtering never mixes the two components.
vec2 media_chroma(ivec2 p, ivec2 extent) {
    p = clamp(p, ivec2(0), extent / 2 - 1);
    ivec2 uv = ivec2(p.x * 2, extent.y + p.y);
    return vec2(texelFetch(image, uv, 0).r, texelFetch(image, uv + ivec2(1, 0), 0).r);
}

void main() {
    bool use_linear_blending = (bools & USE_LINEAR_BLENDING) != 0;

    // Our texture coordinate is based on the screen position, offset by the
    // dest rect origin, and scaled by the ratio between the dest rect size
    // and the original texture size, which effectively scales the original
    // size of the texture to the dest rect size.
    vec2 tex_coord = (gl_FragCoord.xy - offset) * scale;

    vec2 tex_size = textureSize(image, 0);
    if (nv12 != 0u) tex_size.y *= 2.0 / 3.0;

    // If we need to repeat the texture, wrap the coordinates.
    if (repeat != 0) {
        tex_coord = mod(mod(tex_coord, tex_size) + tex_size, tex_size);
    }

    vec4 rgba;
    // If we're out of bounds, we have no color,
    // otherwise we sample the texture for it.
    if (any(lessThan(tex_coord, vec2(0.0))) ||
            any(greaterThan(tex_coord, tex_size)))
    {
        rgba = vec4(0.0);
    } else {
        // We divide by the texture size to normalize for sampling.
        if (nv12 != 0u) {
            float y = texture(image, clamp(tex_coord, vec2(0.5), tex_size - 0.5) / vec2(textureSize(image, 0))).r;
            vec2 chroma_pos = tex_coord * 0.5 - 0.5;
            ivec2 base = ivec2(floor(chroma_pos));
            vec2 fraction = fract(chroma_pos);
            vec2 chroma = mix(
                mix(media_chroma(base, ivec2(tex_size)), media_chroma(base + ivec2(1, 0), ivec2(tex_size)), fraction.x),
                mix(media_chroma(base + ivec2(0, 1), ivec2(tex_size)), media_chroma(base + ivec2(1, 1), ivec2(tex_size)), fraction.x),
                fraction.y) - vec2(128.0 / 255.0);
            float u = chroma.x;
            float v = chroma.y;
            rgba = vec4(clamp(vec3(y + 1.5748 * v, y - 0.187324 * u - 0.468124 * v, y + 1.8556 * u), 0.0, 1.0), 1.0);
            if (use_linear_blending) rgba = linearize(rgba);
        } else {
            rgba = texture(image, tex_coord / tex_size);
        }

        if (nv12 == 0u && !use_linear_blending) {
            rgba = unlinearize(rgba);
        }

        rgba.rgb *= rgba.a;
    }

    // Multiply it by the configured opacity, but cap it at
    // the value that will make it fully opaque relative to
    // the background color alpha, so it isn't overexposed.
    rgba *= min(opacity, 1.0 / bg_color.a);

    // Blend it on to a fully opaque version of the background color.
    rgba += max(vec4(0.0), vec4(bg_color.rgb, 1.0) * vec4(1.0 - rgba.a));

    // Multiply everything by the background color alpha.
    rgba *= bg_color.a;

    out_FragColor = rgba;
}
