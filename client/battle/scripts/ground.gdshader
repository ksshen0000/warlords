shader_type spatial;
render_mode diffuse_burley;

uniform sampler2D soil : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D cover : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D relief : hint_normal, filter_linear_mipmap, repeat_enable;
uniform sampler2D cover_relief : hint_normal, filter_linear_mipmap, repeat_enable;
uniform vec4 soil_tint : source_color;
uniform vec4 cover_tint : source_color;
uniform vec4 far_tint : source_color;
uniform vec2 tile_size = vec2(2.6, 2.1);
uniform float exposure = 0.58;
uniform bool blend_cover = true;
uniform bool village = false;

float tone(vec3 color) {
	return dot(color, vec3(0.299, 0.587, 0.114));
}

void fragment() {
	// Vertex colours carry broad, irregular patches. The photos supply the fine detail.
	float patch_light = mix(0.81, 1.18, COLOR.g);
	vec3 far_ground = far_tint.rgb * (exposure * 0.68 * patch_light);
	ROUGHNESS = 0.95;
	SPECULAR = 0.12;
	if (COLOR.b >= 0.995) {
		ALBEDO = far_ground;
	} else {
		float near_detail = 1.0 - smoothstep(24.0, 88.0, length(VERTEX));
		vec3 base = soil_tint.rgb * patch_light;
		vec3 dirt = texture(soil, UV / tile_size.x).rgb;
		float grain = tone(dirt);
		float mask = 0.0;
		vec2 grass_uv = vec2(UV.x * 0.8 - UV.y * 0.6, UV.x * 0.6 + UV.y * 0.8) / tile_size.y;
		if (blend_cover) {
			// Rotate the two layers relative to each other so their repeats don't line up.
			vec3 grass = texture(cover, grass_uv).rgb;
			mask = smoothstep(0.24, 0.72, COLOR.r + (tone(grass) - grain) * 0.27);
			grain = mix(grain, tone(grass), mask);
			base = mix(soil_tint.rgb, cover_tint.rgb, mask) * patch_light;
		}
		if (village) {
			float edge = (COLOR.g - 0.5) * 0.40 + (tone(dirt) - 0.52) * 0.15;
			float clearing = 1.0 - smoothstep(0.75, 1.05, length(UV / vec2(14.0, 11.5)) + edge);
			float lane_x = UV.x - sin(UV.y * 0.09) * 1.12;
			float lane = (1.0 - smoothstep(1.8, 3.3, abs(lane_x) + edge * 1.9))
				* smoothstep(2.0, 10.0, UV.y) * (1.0 - smoothstep(49.0, 57.5, UV.y));
			float walked = max(clearing, lane);
			base = mix(base, vec3(0.57, 0.47, 0.33) * patch_light, walked);
			grain = mix(grain, tone(dirt), walked);
			mask *= 1.0 - walked;
		}
		ALBEDO = mix(base * exposure * mix(1.0, 0.46 + grain * 1.32, mix(0.20, 0.86, near_detail)),
			far_ground, COLOR.b);
		if (near_detail > 0.01) {
			NORMAL_MAP = texture(relief, UV / tile_size.x).rgb;
			if (mask > 0.01) {
				vec3 grass_normal = texture(cover_relief, grass_uv).rgb;
				vec2 slope = grass_normal.xy - 0.5;
				grass_normal.xy = vec2(slope.x * 0.8 + slope.y * 0.6, -slope.x * 0.6 + slope.y * 0.8) + 0.5;
				NORMAL_MAP = mix(NORMAL_MAP, grass_normal, mask);
			}
			NORMAL_MAP_DEPTH = near_detail * 0.46;
		}
	}
}
