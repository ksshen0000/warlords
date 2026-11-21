shader_type sky;

uniform sampler2D cloud_map : filter_linear_mipmap, repeat_enable;
uniform vec4 zenith : source_color;
uniform vec4 horizon : source_color;
uniform vec4 lower_air : source_color;
uniform vec4 cloud_top : source_color;
uniform vec4 cloud_base : source_color;
uniform vec3 light_dir = vec3(0.37, 0.76, 0.54);
uniform vec2 cloud_shift = vec2(0.0);
uniform float cloud_threshold = 0.5;
uniform bool night = false;

float hash_cell(vec2 cell) {
	return fract(sin(dot(cell, vec2(127.1, 311.7))) * 43758.5453);
}

void sky() {
	float elevation = max(EYEDIR.y, 0.0);
	float facing_light = max(dot(EYEDIR, light_dir), 0.0);
	vec3 air = mix(horizon.rgb, zenith.rgb, pow(elevation, 0.55));
	if (EYEDIR.y < 0.0) {
		air = mix(air, lower_air.rgb, smoothstep(0.0, 0.42, -EYEDIR.y));
	}
	if (AT_CUBEMAP_PASS) {
		COLOR = air;
	} else {
		// Project a static sheet of clouds above the battlefield. Two mipmapped
		// samples supply the silhouette and the shading towards the sun.
		vec2 cloud_uv = EYEDIR.xz * vec2(0.29, 0.21) / (elevation + 0.21) + cloud_shift;
		float density = texture(cloud_map, cloud_uv).r;
		float light_edge = density - texture(cloud_map, cloud_uv - light_dir.xz * 0.021).r;
		float clouds = smoothstep(cloud_threshold, cloud_threshold + 0.17, density);
		clouds *= smoothstep(0.018, 0.18, elevation);
		vec3 cloud_color = mix(cloud_base.rgb, cloud_top.rgb, clamp(0.67 + light_edge * 5.7, 0.0, 1.0));
		air += (night ? vec3(0.039, 0.055, 0.086) : vec3(0.15, 0.094, 0.055)) * pow(facing_light, 9.0);
		float disk = smoothstep(0.99990, 0.99995, facing_light) * smoothstep(0.0, 0.025, elevation);
		air += (night ? vec3(0.62, 0.74, 0.92) : vec3(0.96, 0.81, 0.60)) * disk;
		if (night) {
			vec2 stars = SKY_COORDS * vec2(480.0, 240.0);
			float brightness = smoothstep(0.992, 1.0, hash_cell(floor(stars)));
			float dot_mask = 1.0 - smoothstep(0.07, 0.24, length(fract(stars) - 0.5));
			air += vec3(0.55, 0.65, 0.82) * brightness * dot_mask * smoothstep(0.04, 0.27, elevation);
		}
		COLOR = mix(air, cloud_color, clouds * (night ? 0.57 : 0.94));
	}
}
