shader_type canvas_item;
// Campaign-map terrain from two small textures sent by the server:
//   heights: R8, 0..99 = water depth, 100..255 = land elevation (linear filtered)
//   biomes : R8, terrain code (nearest filtered)
// codes: 0 deep 1 water 2 beach 3 plains 4 meadow 5 forest 6 hills 7 mountain
//        8 snow 9 taiga 10 desert 11 dunes 12 steppe 13 marsh

uniform sampler2D heights : filter_linear, repeat_disable;
uniform sampler2D biomes : filter_nearest, repeat_disable;
uniform vec2 grid = vec2(300.0, 200.0);


float hash(vec2 p) { return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453); }
float noise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	vec2 u = f * f * (3.0 - 2.0 * f);
	return mix(mix(hash(i), hash(i + vec2(1.0, 0.0)), u.x), mix(hash(i + vec2(0.0, 1.0)), hash(i + vec2(1.0, 1.0)), u.x), u.y);
}
float fbm(vec2 p) {
	float v = 0.0;
	float a = 0.5;
	for (int i = 0; i < 4; i++) { v += a * noise(p); p *= 2.03; a *= 0.5; }
	return v;
}

float H(vec2 uv) { return texture(heights, uv).r * 255.0; }

vec3 land_color(int b, vec2 c, float elev) {
	float n = fbm(c * 0.7);
	float fine = noise(c * 6.0);
	vec3 col;
	if (b == 2) { col = vec3(0.86, 0.80, 0.60); }
	else if (b == 3) { col = mix(vec3(0.58, 0.64, 0.36), vec3(0.66, 0.66, 0.40), n); }
	else if (b == 4) { col = mix(vec3(0.42, 0.62, 0.32), vec3(0.50, 0.68, 0.36), n); }
	else if (b == 5) {
		float canopy = smoothstep(0.35, 0.75, noise(c * 3.2) * 0.6 + fine * 0.4);
		col = mix(vec3(0.16, 0.32, 0.23), vec3(0.28, 0.44, 0.28), canopy);
	}
	else if (b == 6) { col = mix(vec3(0.55, 0.52, 0.36), vec3(0.47, 0.50, 0.33), n); }
	else if (b == 7) {
		col = mix(vec3(0.46, 0.44, 0.42), vec3(0.58, 0.56, 0.53), fine);
		float snowline = smoothstep(232.0, 252.0, elev + n * 18.0);
		col = mix(col, vec3(0.93, 0.95, 0.97), snowline);
	}
	else if (b == 8) { col = mix(vec3(0.88, 0.91, 0.94), vec3(0.97, 0.98, 1.0), n); }
	else if (b == 9) {
		float canopy = smoothstep(0.4, 0.8, noise(c * 3.0) * 0.6 + fine * 0.4);
		col = mix(vec3(0.82, 0.86, 0.88), vec3(0.20, 0.33, 0.28), canopy);
	}
	else if (b == 10) { col = mix(vec3(0.82, 0.70, 0.47), vec3(0.88, 0.76, 0.52), n); }
	else if (b == 11) {
		float dune = 0.5 + 0.5 * sin(c.x * 1.4 + c.y * 0.6 + n * 6.0);
		col = mix(vec3(0.86, 0.72, 0.46), vec3(0.95, 0.83, 0.56), dune);
	}
	else if (b == 12) { col = mix(vec3(0.70, 0.68, 0.42), vec3(0.62, 0.64, 0.38), n); }
	else if (b == 13) {
		col = mix(vec3(0.33, 0.42, 0.30), vec3(0.38, 0.47, 0.32), n);
		if (noise(c * 2.2) > 0.68) { col = mix(col, vec3(0.30, 0.42, 0.45), 0.7); }
	}
	else { col = vec3(0.6, 0.65, 0.4); }
	return col * (0.94 + 0.12 * fine);
}

void fragment() {
	vec2 uv = UV;
	vec2 c = uv * grid;
	float h = H(uv);
	float close_detail = 1.0 - smoothstep(0.13, 0.46, length(fwidth(c)));
	vec3 col;
	if (h < 99.5) {
		float depth = clamp(h / 99.0, 0.0, 1.0);
		vec3 open_sea = vec3(21.0, 47.0, 62.0) / 255.0;
		col = mix(open_sea, vec3(0.27, 0.49, 0.49), depth * depth);
		float drift = noise(c * vec2(0.5, 1.8) + vec2(TIME * 0.035, -TIME * 0.06));
		float stipple = smoothstep(0.67, 0.87, drift) * close_detail;
		col += vec3(0.075, 0.095, 0.08) * stipple * (0.32 + depth * 0.68);
		float shore = smoothstep(84.0, 99.5, h);
		float foam = smoothstep(97.0, 99.5, h + noise(c * 3.8) * 1.7);
		col = mix(col, vec3(0.49, 0.65, 0.56), shore * 0.26);
		col = mix(col, vec3(0.77, 0.82, 0.69), foam * 0.52);
		vec2 border = min(c, grid - c);
		col = mix(open_sea, col, smoothstep(0.0, 2.3, min(border.x, border.y)));
	} else {
		vec2 jitter = (vec2(fbm(c * 0.8), fbm(c * 0.8 + 31.7)) - 0.5) * 1.8;
		int b = int(texture(biomes, (c + jitter) / grid).r * 255.0 + 0.5);
		if (b <= 1) { b = 2; }
		col = land_color(b, c, h);
		// hill shading from the height field
		vec2 px = 1.0 / grid;
		float dx = H(uv + vec2(px.x, 0.0)) - H(uv - vec2(px.x, 0.0));
		float dy = H(uv + vec2(0.0, px.y)) - H(uv - vec2(0.0, px.y));
		vec3 nrm = normalize(vec3(-dx * 0.09, -dy * 0.09, 1.0));
		float light = dot(nrm, normalize(vec3(-0.55, -0.65, 0.55)));
		col *= 0.65 + 0.47 * clamp(light, 0.0, 1.2);
		if (b == 6 || b == 7) {
			float contour = 1.0 - smoothstep(0.035, 0.12, abs(fract(h / 11.0) - 0.5));
			col *= 1.0 - contour * close_detail * 0.10;
		}
		// soft dark rim along the coast
		col *= mix(0.86, 1.0, smoothstep(100.0, 106.0, h));
	}
	COLOR = vec4(col, 1.0);
}
