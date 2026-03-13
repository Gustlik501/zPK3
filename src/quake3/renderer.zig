const std = @import("std");
const rl = @import("raylib");
const rlgl = rl.gl;
const archive = @import("archive.zig");
const bsp = @import("bsp.zig");
const tga = @import("tga.zig");

const lightmap_shader_vs: [:0]const u8 =
    \\#version 330
    \\in vec3 vertexPosition;
    \\in vec2 vertexTexCoord;
    \\in vec2 vertexTexCoord2;
    \\in vec4 vertexColor;
    \\in vec3 vertexNormal;
    \\
    \\out vec2 fragTexCoord;
    \\out vec2 fragTexCoord2;
    \\out vec4 fragColor;
    \\
    \\uniform mat4 mvp;
    \\
    \\void main() {
    \\    fragTexCoord = vertexTexCoord;
    \\    fragTexCoord2 = vertexTexCoord2;
    \\    fragColor = vertexColor;
    \\    gl_Position = mvp * vec4(vertexPosition, 1.0);
    \\}
;

const lightmap_shader_fs: [:0]const u8 =
    \\#version 330
    \\in vec2 fragTexCoord;
    \\in vec2 fragTexCoord2;
    \\in vec4 fragColor;
    \\
    \\out vec4 finalColor;
    \\
    \\uniform sampler2D texture0;
    \\uniform sampler2D texture1;
    \\uniform int useLightmap;
    \\uniform float lightmapScale;
    \\uniform float alphaCutoff;
    \\
    \\void main() {
    \\    vec4 albedo = texture(texture0, fragTexCoord) * fragColor;
    \\    if (albedo.a <= alphaCutoff) discard;
    \\    vec3 light = vec3(1.0);
    \\    if (useLightmap == 1) {
    \\        light = texture(texture1, fragTexCoord2).rgb;
    \\        light = pow(light, vec3(0.85)) * lightmapScale;
    \\    }
    \\    finalColor = vec4(albedo.rgb * light, albedo.a);
    \\}
;

pub const SceneStats = struct {
    batch_count: usize = 0,
    face_count: usize = 0,
    vertex_count: usize = 0,
    missing_texture_count: usize = 0,
};

const RenderMode = enum {
    solid,
    alpha,
    additive,
};

const MaterialRule = struct {
    skip: bool = false,
    use_lightmap: bool = true,
    render_mode: RenderMode = .solid,
    double_sided: bool = false,
    alpha_cutoff: f32 = 0.0,
};

const SurfaceBatch = struct {
    model: rl.Model,
    render_mode: RenderMode,
    use_lightmap: bool,
    double_sided: bool,
    alpha_cutoff: f32,
};

const BatchKey = struct {
    texture_name: []const u8,
    lightmap_index: i32,
    rule: MaterialRule,
};

pub const SceneRenderer = struct {
    allocator: std.mem.Allocator,
    batches: []SurfaceBatch,
    stats: SceneStats,
    texture_cache: TextureCache,
    lightmap_cache: LightmapCache,
    lightmap_shader: rl.Shader,
    lightmap_use_loc: i32,
    lightmap_scale_loc: i32,
    alpha_cutoff_loc: i32,
    draw_wireframe: bool = false,
    fullbright: bool = false,
    backface_culling: bool = true,

    pub fn init(allocator: std.mem.Allocator, packs: *archive.Pk3Collection, map: *const bsp.Map) !SceneRenderer {
        var texture_cache = try TextureCache.init(allocator, packs);
        errdefer texture_cache.deinit();

        var lightmap_cache = try LightmapCache.init(allocator, map);
        errdefer lightmap_cache.deinit();

        const lightmap_shader = try createLightmapShader();
        errdefer rl.unloadShader(lightmap_shader);

        var builders: std.ArrayList(MeshBuilder) = .empty;
        defer {
            for (builders.items) |*builder| builder.deinit();
            builders.deinit(allocator);
        }

        var stats: SceneStats = .{};

        for (map.faces) |face| {
            if (face.texture < 0 or @as(usize, @intCast(face.texture)) >= map.textures.len) continue;
            const texture_name = map.textures[@intCast(face.texture)].name;
            const rule = texture_cache.getMaterialRule(texture_name);
            if (rule.skip or shouldSkipTexture(texture_name)) continue;
            const builder = try getOrCreateBuilder(allocator, &builders, .{
                .texture_name = texture_name,
                .lightmap_index = if (rule.use_lightmap) face.lightmap_index else -1,
                .rule = rule,
            });

            switch (face.face_type) {
                1 => try builder.appendMeshFace(map, face, true),
                3 => try builder.appendMeshFace(map, face, false),
                2 => try builder.appendPatchFace(map, face, 8),
                else => continue,
            }
            stats.face_count += 1;
        }

        var batch_list: std.ArrayList(SurfaceBatch) = .empty;
        errdefer {
            for (batch_list.items) |batch| rl.unloadModel(batch.model);
            batch_list.deinit(allocator);
        }

        for (builders.items) |*builder| {
            if (builder.vertex_count == 0) continue;

            const mesh = try builder.toMesh();
            var model = try rl.loadModelFromMesh(mesh);
            const texture = try texture_cache.loadTexture(builder.texture_name);
            const lightmap = lightmap_cache.getTexture(builder.lightmap_index);
            if (texture_cache.was_missing_last_load) {
                stats.missing_texture_count += 1;
            }

            model.materials[0].shader = lightmap_shader;
            model.materials[0].maps[@intFromEnum(rl.MATERIAL_MAP_DIFFUSE)].texture = texture;
            model.materials[0].maps[@intFromEnum(rl.MaterialMapIndex.emission)].texture = lightmap;
            try batch_list.append(allocator, .{
                .model = model,
                .render_mode = builder.rule.render_mode,
                .use_lightmap = builder.rule.use_lightmap,
                .double_sided = builder.rule.double_sided,
                .alpha_cutoff = builder.rule.alpha_cutoff,
            });
            stats.vertex_count += builder.vertex_count;
        }

        stats.batch_count = batch_list.items.len;

        return .{
            .allocator = allocator,
            .batches = try batch_list.toOwnedSlice(allocator),
            .stats = stats,
            .texture_cache = texture_cache,
            .lightmap_cache = lightmap_cache,
            .lightmap_shader = lightmap_shader,
            .lightmap_use_loc = rl.getShaderLocation(lightmap_shader, "useLightmap"),
            .lightmap_scale_loc = rl.getShaderLocation(lightmap_shader, "lightmapScale"),
            .alpha_cutoff_loc = rl.getShaderLocation(lightmap_shader, "alphaCutoff"),
        };
    }

    pub fn deinit(self: *SceneRenderer) void {
        for (self.batches) |batch| {
            rl.unloadModel(batch.model);
        }
        self.allocator.free(self.batches);
        self.texture_cache.deinit();
        self.lightmap_cache.deinit();
        rl.unloadShader(self.lightmap_shader);
        self.* = undefined;
    }

    pub fn draw(self: *SceneRenderer) void {
        if (rl.isKeyPressed(.f1)) {
            self.draw_wireframe = !self.draw_wireframe;
        }
        if (rl.isKeyPressed(.f2)) {
            self.fullbright = !self.fullbright;
        }
        if (rl.isKeyPressed(.f3)) {
            self.backface_culling = !self.backface_culling;
        }

        self.drawBatches(.solid);
        self.drawBatches(.alpha);
        self.drawBatches(.additive);
        rlgl.rlEnableBackfaceCulling();
    }

    fn drawBatches(self: *SceneRenderer, mode: RenderMode) void {
        switch (mode) {
            .solid => {},
            .alpha => rl.beginBlendMode(.alpha),
            .additive => rl.beginBlendMode(.additive),
        }
        defer switch (mode) {
            .solid => {},
            .alpha, .additive => rl.endBlendMode(),
        };

        for (self.batches) |batch| {
            if (batch.render_mode != mode) continue;

            const use_lightmap: i32 = if (self.fullbright or self.draw_wireframe or !batch.use_lightmap) 0 else 1;
            const lightmap_scale: f32 = if (self.fullbright or self.draw_wireframe or !batch.use_lightmap) 1.0 else 2.0;
            rl.setShaderValue(self.lightmap_shader, self.lightmap_use_loc, &use_lightmap, .int);
            rl.setShaderValue(self.lightmap_shader, self.lightmap_scale_loc, &lightmap_scale, .float);
            rl.setShaderValue(self.lightmap_shader, self.alpha_cutoff_loc, &batch.alpha_cutoff, .float);

            if (!self.backface_culling or batch.double_sided) {
                rlgl.rlDisableBackfaceCulling();
            } else {
                rlgl.rlEnableBackfaceCulling();
            }

            if (self.draw_wireframe) {
                rl.drawModel(batch.model, .{ .x = 0, .y = 0, .z = 0 }, 1.0, .white);
                rl.drawModelWires(batch.model, .{ .x = 0, .y = 0, .z = 0 }, 1.0, .green);
            } else {
                rl.drawModel(batch.model, .{ .x = 0, .y = 0, .z = 0 }, 1.0, .white);
            }
        }
    }
};

const TextureCache = struct {
    allocator: std.mem.Allocator,
    packs: *archive.Pk3Collection,
    textures: std.StringHashMap(rl.Texture2D),
    shader_aliases: std.StringHashMap([]const u8),
    material_rules: std.StringHashMap(MaterialRule),
    fallback_paths: std.StringHashMap([]const u8),
    fallback_ambiguous: std.StringHashMap(void),
    image_paths: std.ArrayList([]const u8),
    placeholder: rl.Texture2D,
    was_missing_last_load: bool = false,

    pub fn init(allocator: std.mem.Allocator, packs: *archive.Pk3Collection) !TextureCache {
        const image = rl.genImageChecked(64, 64, 8, 8, .magenta, .black);
        defer rl.unloadImage(image);

        var cache = TextureCache{
            .allocator = allocator,
            .packs = packs,
            .textures = std.StringHashMap(rl.Texture2D).init(allocator),
            .shader_aliases = std.StringHashMap([]const u8).init(allocator),
            .material_rules = std.StringHashMap(MaterialRule).init(allocator),
            .fallback_paths = std.StringHashMap([]const u8).init(allocator),
            .fallback_ambiguous = std.StringHashMap(void).init(allocator),
            .image_paths = .empty,
            .placeholder = try rl.loadTextureFromImage(image),
        };
        errdefer cache.deinit();

        try cache.loadShaderAliases();
        try cache.buildFallbackIndex();
        return cache;
    }

    pub fn deinit(self: *TextureCache) void {
        var it = self.textures.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.*.id != self.placeholder.id) {
                rl.unloadTexture(entry.value_ptr.*);
            }
            self.allocator.free(entry.key_ptr.*);
        }
        self.textures.deinit();

        var alias_it = self.shader_aliases.iterator();
        while (alias_it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.shader_aliases.deinit();

        var rule_it = self.material_rules.iterator();
        while (rule_it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.material_rules.deinit();

        var fallback_it = self.fallback_paths.iterator();
        while (fallback_it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.fallback_paths.deinit();

        for (self.image_paths.items) |path| {
            self.allocator.free(path);
        }
        self.image_paths.deinit(self.allocator);

        var ambiguous_it = self.fallback_ambiguous.iterator();
        while (ambiguous_it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.fallback_ambiguous.deinit();
        rl.unloadTexture(self.placeholder);
    }

    pub fn loadTexture(self: *TextureCache, texture_name: []const u8) !rl.Texture2D {
        self.was_missing_last_load = false;

        if (self.textures.get(texture_name)) |texture| {
            return texture;
        }

        if (try self.tryLoadTexture(texture_name, texture_name, 0)) |texture| {
            return texture;
        }

        self.was_missing_last_load = true;
        const owned_name = try self.allocator.dupe(u8, texture_name);
        try self.textures.put(owned_name, self.placeholder);
        return self.placeholder;
    }

    fn getMaterialRule(self: *const TextureCache, texture_name: []const u8) MaterialRule {
        var rule = self.material_rules.get(texture_name) orelse MaterialRule{};
        if (std.mem.startsWith(u8, texture_name, "models/")) {
            rule.double_sided = true;
        }
        return rule;
    }

    fn tryLoadTexture(self: *TextureCache, cache_key: []const u8, target_name: []const u8, depth: usize) !?rl.Texture2D {
        if (depth > 4) return null;

        if (try self.loadTextureFile(cache_key, target_name)) |texture| {
            return texture;
        }

        if (self.shader_aliases.get(target_name)) |alias| {
            return try self.tryLoadTexture(cache_key, alias, depth + 1);
        }

        if (self.findFallbackPath(target_name)) |fallback_path| {
            if (std.mem.eql(u8, fallback_path, target_name)) return null;
            return try self.tryLoadTexture(cache_key, fallback_path, depth + 1);
        }

        return null;
    }

    fn loadTextureFile(self: *TextureCache, cache_key: []const u8, target_name: []const u8) !?rl.Texture2D {
        if (std.fs.path.extension(target_name).len != 0) {
            const file_data = self.packs.readFileAlloc(self.allocator, target_name) catch return null;
            defer self.allocator.free(file_data);

            const texture = loadTextureFromBytes(self.allocator, std.fs.path.extension(target_name), file_data) catch return null;
            const owned_name = try self.allocator.dupe(u8, cache_key);
            try self.textures.put(owned_name, texture);
            return texture;
        }

        for ([_][]const u8{ ".jpg", ".tga", ".png", ".jpeg", ".bmp" }) |ext| {
            const candidate = try std.mem.concat(self.allocator, u8, &.{ target_name, ext });
            defer self.allocator.free(candidate);

            const file_data = self.packs.readFileAlloc(self.allocator, candidate) catch continue;
            defer self.allocator.free(file_data);

            const texture = loadTextureFromBytes(self.allocator, ext, file_data) catch continue;
            const owned_name = try self.allocator.dupe(u8, cache_key);
            try self.textures.put(owned_name, texture);
            return texture;
        }

        return null;
    }

    fn loadShaderAliases(self: *TextureCache) !void {
        const shader_files = try self.packs.collectFilesWithSuffixAlloc(self.allocator, ".shader");
        defer {
            for (shader_files) |path| self.allocator.free(path);
            self.allocator.free(shader_files);
        }

        for (shader_files) |path| {
            const data = try self.packs.readFileAlloc(self.allocator, path);
            defer self.allocator.free(data);
            try self.parseShaderFile(data);
            try self.parseMaterialRulesFile(data);
        }
    }

    fn buildFallbackIndex(self: *TextureCache) !void {
        inline for ([_][]const u8{ ".jpg", ".tga", ".png", ".jpeg", ".bmp" }) |ext| {
            const paths = try self.packs.collectFilesWithSuffixAlloc(self.allocator, ext);
            defer {
                for (paths) |path| self.allocator.free(path);
                self.allocator.free(paths);
            }

            for (paths) |path| {
                try self.indexFallbackPath(path);
            }
        }
    }

    fn indexFallbackPath(self: *TextureCache, path: []const u8) !void {
        try self.image_paths.append(self.allocator, try self.allocator.dupe(u8, path));

        const basename = std.fs.path.basename(path);
        try self.putFallbackKey(basename, path);

        const stem = basename[0 .. basename.len - std.fs.path.extension(basename).len];
        try self.putFallbackKey(stem, path);

        const normalized_stem = normalizeLookupStem(stem);
        if (!std.mem.eql(u8, normalized_stem, stem)) {
            try self.putFallbackKey(normalized_stem, path);
        }
    }

    fn putFallbackKey(self: *TextureCache, key: []const u8, path: []const u8) !void {
        if (key.len == 0) return;

        const normalized_key = try normalizeOwned(self.allocator, key);
        errdefer self.allocator.free(normalized_key);

        if (self.fallback_ambiguous.contains(normalized_key)) {
            self.allocator.free(normalized_key);
            return;
        }

        if (self.fallback_paths.getEntry(normalized_key)) |entry| {
            if (!std.mem.eql(u8, entry.value_ptr.*, path)) {
                const removed = self.fallback_paths.fetchRemove(normalized_key).?;
                self.allocator.free(removed.key);
                self.allocator.free(removed.value);
                try self.fallback_ambiguous.put(normalized_key, {});
            } else {
                self.allocator.free(normalized_key);
            }
            return;
        }

        try self.fallback_paths.put(normalized_key, try self.allocator.dupe(u8, path));
    }

    fn findFallbackPath(self: *TextureCache, target_name: []const u8) ?[]const u8 {
        const basename = std.fs.path.basename(target_name);
        const ext = std.fs.path.extension(basename);
        const stem = if (ext.len == 0) basename else basename[0 .. basename.len - ext.len];

        const normalized_stem = normalizeOwned(self.allocator, stem) catch return null;
        defer self.allocator.free(normalized_stem);

        if (self.fallback_paths.get(normalized_stem)) |path| {
            return path;
        }

        const simplified_stem = normalizeLookupStem(normalized_stem);
        if (!std.mem.eql(u8, simplified_stem, normalized_stem)) {
            if (self.fallback_paths.get(simplified_stem)) |path| {
                return path;
            }
        }

        if (self.findBestStemMatch(target_name, simplified_stem)) |path| {
            return path;
        }

        return self.findFuzzyFallbackPath(target_name, simplified_stem);
    }

    fn findBestStemMatch(self: *TextureCache, target_name: []const u8, simplified_stem: []const u8) ?[]const u8 {
        const target_dir = std.fs.path.dirname(target_name) orelse "";
        var best_path: ?[]const u8 = null;
        var best_score: usize = 0;
        var ambiguous = false;

        for (self.image_paths.items) |path| {
            const basename = std.fs.path.basename(path);
            const ext = std.fs.path.extension(basename);
            const stem = basename[0 .. basename.len - ext.len];
            const candidate = normalizeLookupStem(stem);
            if (!std.mem.eql(u8, simplified_stem, candidate)) continue;

            const score = commonPrefixLen(target_dir, std.fs.path.dirname(path) orelse "") + stem.len;
            if (score > best_score) {
                best_score = score;
                best_path = path;
                ambiguous = false;
            } else if (score == best_score and best_path != null and !std.mem.eql(u8, best_path.?, path)) {
                ambiguous = true;
            }
        }

        if (ambiguous) return null;
        return best_path;
    }

    fn findFuzzyFallbackPath(self: *TextureCache, target_name: []const u8, simplified_stem: []const u8) ?[]const u8 {
        const target_dir = std.fs.path.dirname(target_name) orelse "";
        var best_path: ?[]const u8 = null;
        var best_score: usize = 0;
        var ambiguous = false;

        for (self.image_paths.items) |path| {
            const basename = std.fs.path.basename(path);
            const ext = std.fs.path.extension(basename);
            const stem = basename[0 .. basename.len - ext.len];
            const candidate = normalizeLookupStem(stem);

            var score = fuzzyScore(simplified_stem, candidate);
            score += commonPrefixLen(target_dir, std.fs.path.dirname(path) orelse "");
            if (score == 0) continue;

            if (score > best_score) {
                best_score = score;
                best_path = path;
                ambiguous = false;
            } else if (score == best_score and best_path != null and !std.mem.eql(u8, best_path.?, path)) {
                ambiguous = true;
            }
        }

        if (ambiguous) return null;
        return best_path;
    }

    fn parseShaderFile(self: *TextureCache, data: []const u8) !void {
        var lines = std.mem.splitScalar(u8, data, '\n');
        var current_name: ?[]const u8 = null;
        var depth: usize = 0;
        var preferred_target: ?[]const u8 = null;
        var editor_target: ?[]const u8 = null;

        while (lines.next()) |raw_line| {
            const line = trimShaderLine(raw_line);
            if (line.len == 0) continue;

            if (current_name == null) {
                if (std.mem.eql(u8, line, "{") or std.mem.eql(u8, line, "}")) continue;
                if (std.mem.indexOfScalar(u8, line, '{')) |brace_index| {
                    const name = std.mem.trim(u8, line[0..brace_index], " \t\r");
                    if (name.len == 0) continue;
                    current_name = name;
                    depth = 1;
                    preferred_target = null;
                    editor_target = null;
                    continue;
                }
                current_name = line;
                preferred_target = null;
                editor_target = null;
                continue;
            }

            if (std.mem.eql(u8, line, "{")) {
                depth += 1;
                continue;
            }

            if (std.mem.eql(u8, line, "}")) {
                if (depth > 0) depth -= 1;
                if (depth == 0) {
                    const resolved = preferred_target orelse editor_target;
                    if (resolved) |target| {
                        try self.putShaderAlias(current_name.?, target);
                    }
                    current_name = null;
                    preferred_target = null;
                    editor_target = null;
                }
                continue;
            }

            if (depth == 0) continue;

            if (preferred_target == null) {
                preferred_target = extractStageTarget(line);
            }
            if (editor_target == null) {
                editor_target = extractEditorTarget(line);
            }
        }
    }

    fn putShaderAlias(self: *TextureCache, shader_name: []const u8, target_name: []const u8) !void {
        const owned_key = try normalizeOwned(self.allocator, shader_name);
        errdefer self.allocator.free(owned_key);

        const owned_value = try normalizeOwned(self.allocator, target_name);
        errdefer self.allocator.free(owned_value);

        if (std.mem.eql(u8, owned_key, owned_value)) {
            self.allocator.free(owned_key);
            self.allocator.free(owned_value);
            return;
        }

        if (self.shader_aliases.getEntry(owned_key)) |entry| {
            self.allocator.free(owned_key);
            self.allocator.free(entry.value_ptr.*);
            entry.value_ptr.* = owned_value;
            return;
        }

        try self.shader_aliases.put(owned_key, owned_value);
    }

    fn parseMaterialRulesFile(self: *TextureCache, data: []const u8) !void {
        var lines = std.mem.splitScalar(u8, data, '\n');
        var current_name: ?[]const u8 = null;
        var depth: usize = 0;
        var rule: MaterialRule = .{};
        var stage: StageState = .{};

        while (lines.next()) |raw_line| {
            const line = trimShaderLine(raw_line);
            if (line.len == 0) continue;

            if (current_name == null) {
                if (std.mem.eql(u8, line, "{") or std.mem.eql(u8, line, "}")) continue;
                if (std.mem.indexOfScalar(u8, line, '{')) |brace_index| {
                    const name = std.mem.trim(u8, line[0..brace_index], " \t\r");
                    if (name.len == 0) continue;
                    current_name = name;
                    depth = 1;
                    rule = .{};
                    stage = .{};
                    continue;
                }
                current_name = line;
                depth = 0;
                rule = .{};
                stage = .{};
                continue;
            }

            if (std.mem.eql(u8, line, "{")) {
                depth += 1;
                if (depth == 2) stage = .{};
                continue;
            }

            if (std.mem.eql(u8, line, "}")) {
                if (depth == 2) {
                    stage.apply(&rule);
                    stage = .{};
                    depth = 1;
                    continue;
                }
                if (depth == 1) {
                    try self.putMaterialRule(current_name.?, rule);
                    current_name = null;
                    depth = 0;
                    rule = .{};
                    stage = .{};
                }
                continue;
            }

            if (depth == 1) {
                applyMaterialKeyword(&rule, line);
            } else if (depth >= 2) {
                stage.consume(line);
            }
        }
    }

    fn putMaterialRule(self: *TextureCache, shader_name: []const u8, rule: MaterialRule) !void {
        const owned_key = try normalizeOwned(self.allocator, shader_name);
        errdefer self.allocator.free(owned_key);

        if (self.material_rules.getEntry(owned_key)) |entry| {
            self.allocator.free(owned_key);
            entry.value_ptr.* = rule;
            return;
        }

        try self.material_rules.put(owned_key, rule);
    }
};

const StageBlend = enum {
    solid,
    filter,
    alpha,
    additive,
};

const StageState = struct {
    is_lightmap: bool = false,
    blend: StageBlend = .solid,
    alpha_cutout: bool = false,

    fn consume(self: *StageState, line: []const u8) void {
        if (extractRawStageTarget(line)) |target| {
            if (std.mem.eql(u8, target, "$lightmap")) {
                self.is_lightmap = true;
            }
            return;
        }

        var tokens = std.mem.tokenizeAny(u8, line, " \t\r");
        const keyword = tokens.next() orelse return;

        if (std.mem.eql(u8, keyword, "blendfunc") or std.mem.eql(u8, keyword, "blendFunc")) {
            if (tokens.next()) |first| {
                if (parseBlendMode(first, tokens.next())) |blend| {
                    self.blend = blend;
                }
            }
            return;
        }

        if (std.mem.eql(u8, keyword, "alphafunc") or std.mem.eql(u8, keyword, "alphaFunc")) {
            self.alpha_cutout = true;
        }
    }

    fn apply(self: StageState, rule: *MaterialRule) void {
        if (self.is_lightmap) return;

        if (self.alpha_cutout) {
            rule.alpha_cutoff = @max(rule.alpha_cutoff, 0.5);
        }

        switch (self.blend) {
            .solid, .filter => {},
            .alpha => {
                if (rule.render_mode != .additive) rule.render_mode = .alpha;
            },
            .additive => {
                rule.render_mode = .additive;
                rule.use_lightmap = false;
            },
        }
    }
};

const LightmapCache = struct {
    allocator: std.mem.Allocator,
    textures: []rl.Texture2D,
    white: rl.Texture2D,

    fn init(allocator: std.mem.Allocator, map: *const bsp.Map) !LightmapCache {
        var textures = try allocator.alloc(rl.Texture2D, map.lightmap_count);
        errdefer allocator.free(textures);

        var built: usize = 0;
        errdefer {
            for (textures[0..built]) |texture| rl.unloadTexture(texture);
        }

        for (0..map.lightmap_count) |index| {
            textures[index] = try createLightmapTexture(map.lightmapPixels(index));
            built += 1;
        }

        const white_image = rl.genImageColor(bsp.lightmap_side, bsp.lightmap_side, .white);
        defer rl.unloadImage(white_image);

        return .{
            .allocator = allocator,
            .textures = textures,
            .white = try rl.loadTextureFromImage(white_image),
        };
    }

    fn deinit(self: *LightmapCache) void {
        for (self.textures) |texture| rl.unloadTexture(texture);
        self.allocator.free(self.textures);
        rl.unloadTexture(self.white);
        self.* = undefined;
    }

    fn getTexture(self: *const LightmapCache, index: i32) rl.Texture2D {
        if (index < 0) return self.white;
        const lightmap_index: usize = @intCast(index);
        if (lightmap_index >= self.textures.len) return self.white;
        return self.textures[lightmap_index];
    }
};

fn createLightmapTexture(bytes: []const u8) !rl.Texture2D {
    const raw = try copyToRaylibAlloc(u8, bytes);
    const image = rl.Image{
        .data = raw,
        .width = bsp.lightmap_side,
        .height = bsp.lightmap_side,
        .mipmaps = 1,
        .format = .uncompressed_r8g8b8,
    };
    defer rl.unloadImage(image);

    const texture = try rl.loadTextureFromImage(image);
    rl.setTextureFilter(texture, .bilinear);
    return texture;
}

fn createLightmapShader() !rl.Shader {
    var shader = try rl.loadShaderFromMemory(lightmap_shader_vs, lightmap_shader_fs);
    shader.locs[@intFromEnum(rl.ShaderLocationIndex.vertex_texcoord02)] =
        rl.getShaderLocationAttrib(shader, "vertexTexCoord2");
    shader.locs[@intFromEnum(rl.ShaderLocationIndex.map_albedo)] =
        rl.getShaderLocation(shader, "texture0");
    shader.locs[@intFromEnum(rl.ShaderLocationIndex.map_emission)] =
        rl.getShaderLocation(shader, "texture1");
    return shader;
}

fn getOrCreateBuilder(
    allocator: std.mem.Allocator,
    builders: *std.ArrayList(MeshBuilder),
    key: BatchKey,
) !*MeshBuilder {
    for (builders.items) |*builder| {
        if (builder.lightmap_index == key.lightmap_index and
            std.mem.eql(u8, builder.texture_name, key.texture_name) and
            builder.rule.render_mode == key.rule.render_mode and
            builder.rule.use_lightmap == key.rule.use_lightmap and
            builder.rule.double_sided == key.rule.double_sided and
            builder.rule.alpha_cutoff == key.rule.alpha_cutoff)
        {
            return builder;
        }
    }

    try builders.append(allocator, MeshBuilder.init(allocator, key.texture_name, key.lightmap_index, key.rule));
    return &builders.items[builders.items.len - 1];
}

const MeshBuilder = struct {
    allocator: std.mem.Allocator,
    texture_name: []const u8,
    lightmap_index: i32,
    rule: MaterialRule,
    positions: std.ArrayList(f32),
    texcoords: std.ArrayList(f32),
    texcoords2: std.ArrayList(f32),
    normals: std.ArrayList(f32),
    colors: std.ArrayList(u8),
    vertex_count: usize = 0,

    fn init(allocator: std.mem.Allocator, texture_name: []const u8, lightmap_index: i32, rule: MaterialRule) MeshBuilder {
        return .{
            .allocator = allocator,
            .texture_name = texture_name,
            .lightmap_index = lightmap_index,
            .rule = rule,
            .positions = .empty,
            .texcoords = .empty,
            .texcoords2 = .empty,
            .normals = .empty,
            .colors = .empty,
        };
    }

    fn deinit(self: *MeshBuilder) void {
        self.positions.deinit(self.allocator);
        self.texcoords.deinit(self.allocator);
        self.texcoords2.deinit(self.allocator);
        self.normals.deinit(self.allocator);
        self.colors.deinit(self.allocator);
    }

    fn appendMeshFace(self: *MeshBuilder, map: *const bsp.Map, face: bsp.Face, preferred_reverse_winding: bool) !void {
        if (face.vertex_index < 0 or face.meshvert_index < 0) return;
        if (face.vertex_count <= 0 or face.meshvert_count <= 0) return;

        const base_vertex: usize = @intCast(face.vertex_index);
        const vertex_count: usize = @intCast(face.vertex_count);
        const meshvert_index: usize = @intCast(face.meshvert_index);
        const meshvert_count: usize = @intCast(face.meshvert_count);

        if (base_vertex + vertex_count > map.vertices.len) return;
        if (meshvert_index + meshvert_count > map.meshverts.len) return;

        const vertices = map.vertices[base_vertex .. base_vertex + vertex_count];
        const meshverts = map.meshverts[meshvert_index .. meshvert_index + meshvert_count];

        var tri: usize = 0;
        while (tri + 2 < meshverts.len) : (tri += 3) {
            const a = meshverts[tri];
            const b = meshverts[tri + 1];
            const c = meshverts[tri + 2];
            if (a < 0 or b < 0 or c < 0) continue;

            const ia: usize = @intCast(a);
            const ib: usize = @intCast(b);
            const ic: usize = @intCast(c);
            if (ia >= vertices.len or ib >= vertices.len or ic >= vertices.len) continue;

            try self.appendTriangle(vertices[ia], vertices[ib], vertices[ic], face.normal, preferred_reverse_winding);
        }
    }

    fn appendPatchFace(self: *MeshBuilder, map: *const bsp.Map, face: bsp.Face, tessellation: usize) !void {
        if (face.vertex_index < 0 or face.vertex_count <= 0) return;
        if (face.patch_size[0] < 3 or face.patch_size[1] < 3) return;

        const base_vertex: usize = @intCast(face.vertex_index);
        const vertex_count: usize = @intCast(face.vertex_count);
        if (base_vertex + vertex_count > map.vertices.len) return;

        const patch_width: usize = @intCast(face.patch_size[0]);
        const patch_height: usize = @intCast(face.patch_size[1]);
        if (patch_width * patch_height > vertex_count) return;

        const surface_vertices = map.vertices[base_vertex .. base_vertex + vertex_count];
        const patch_cols = (patch_width - 1) / 2;
        const patch_rows = (patch_height - 1) / 2;

        var row: usize = 0;
        while (row < patch_rows) : (row += 1) {
            var col: usize = 0;
            while (col < patch_cols) : (col += 1) {
                var control: [3][3]bsp.Vertex = undefined;
                var cp_row: usize = 0;
                while (cp_row < 3) : (cp_row += 1) {
                    var cp_col: usize = 0;
                    while (cp_col < 3) : (cp_col += 1) {
                        const src_index = (row * 2 + cp_row) * patch_width + (col * 2 + cp_col);
                        control[cp_row][cp_col] = surface_vertices[src_index];
                    }
                }
                try self.appendTessellatedPatch(control, face.normal, tessellation);
            }
        }
    }

    fn appendTessellatedPatch(self: *MeshBuilder, control: [3][3]bsp.Vertex, face_normal: [3]f32, tessellation: usize) !void {
        const row_count = tessellation + 1;
        const samples = try self.allocator.alloc(SampledVertex, row_count * row_count);
        defer self.allocator.free(samples);

        var y: usize = 0;
        while (y < row_count) : (y += 1) {
            const v = @as(f32, @floatFromInt(y)) / @as(f32, @floatFromInt(tessellation));
            var x: usize = 0;
            while (x < row_count) : (x += 1) {
                const u = @as(f32, @floatFromInt(x)) / @as(f32, @floatFromInt(tessellation));
                samples[y * row_count + x] = samplePatch(control, u, v);
            }
        }

        var cell_y: usize = 0;
        while (cell_y < tessellation) : (cell_y += 1) {
            var cell_x: usize = 0;
            while (cell_x < tessellation) : (cell_x += 1) {
                const s0 = cell_y * row_count + cell_x;
                const s1 = s0 + 1;
                const s2 = s0 + row_count;
                const s3 = s2 + 1;

                try self.appendSampledTriangle(samples[s0], samples[s2], samples[s1], face_normal, true);
                try self.appendSampledTriangle(samples[s1], samples[s2], samples[s3], face_normal, true);
            }
        }
    }

    fn appendTriangle(
        self: *MeshBuilder,
        a: bsp.Vertex,
        b: bsp.Vertex,
        c: bsp.Vertex,
        face_normal: [3]f32,
        preferred_reverse_winding: bool,
    ) !void {
        const reverse_winding = shouldReverseTriangleVertices(a.position, b.position, c.position, face_normal, preferred_reverse_winding);
        try self.appendVertex(.{
            .position = a.position,
            .texcoord = a.texcoord,
            .lightmap_uv = a.lightmap_uv,
            .normal = a.normal,
            .color = a.color,
        });
        if (reverse_winding) {
            try self.appendVertex(.{
                .position = c.position,
                .texcoord = c.texcoord,
                .lightmap_uv = c.lightmap_uv,
                .normal = c.normal,
                .color = c.color,
            });
            try self.appendVertex(.{
                .position = b.position,
                .texcoord = b.texcoord,
                .lightmap_uv = b.lightmap_uv,
                .normal = b.normal,
                .color = b.color,
            });
        } else {
            try self.appendVertex(.{
                .position = b.position,
                .texcoord = b.texcoord,
                .lightmap_uv = b.lightmap_uv,
                .normal = b.normal,
                .color = b.color,
            });
            try self.appendVertex(.{
                .position = c.position,
                .texcoord = c.texcoord,
                .lightmap_uv = c.lightmap_uv,
                .normal = c.normal,
                .color = c.color,
            });
        }
    }

    fn appendSampledTriangle(
        self: *MeshBuilder,
        a: SampledVertex,
        b: SampledVertex,
        c: SampledVertex,
        face_normal: [3]f32,
        preferred_reverse_winding: bool,
    ) !void {
        const reverse_winding = shouldReverseTriangleVertices(a.position, b.position, c.position, face_normal, preferred_reverse_winding);
        try self.appendVertex(a);
        if (reverse_winding) {
            try self.appendVertex(c);
            try self.appendVertex(b);
        } else {
            try self.appendVertex(b);
            try self.appendVertex(c);
        }
    }

    fn appendVertex(self: *MeshBuilder, vertex: SampledVertex) !void {
        const position = bsp.toEngineSpace(vertex.position);
        const normal = normalizeVector(bsp.toEngineNormal(vertex.normal));

        try self.positions.appendSlice(self.allocator, &.{ position.x, position.y, position.z });
        try self.texcoords.appendSlice(self.allocator, &.{ vertex.texcoord[0], 1.0 - vertex.texcoord[1] });
        try self.texcoords2.appendSlice(self.allocator, &.{ vertex.lightmap_uv[0], 1.0 - vertex.lightmap_uv[1] });
        try self.normals.appendSlice(self.allocator, &.{ normal.x, normal.y, normal.z });
        try self.colors.appendSlice(self.allocator, &.{ 255, 255, 255, vertex.color[3] });
        self.vertex_count += 1;
    }

    fn toMesh(self: *MeshBuilder) !rl.Mesh {
        var mesh = std.mem.zeroes(rl.Mesh);
        mesh.vertexCount = @intCast(self.vertex_count);
        mesh.triangleCount = @intCast(self.vertex_count / 3);

        mesh.vertices = try copyToRaylibAlloc(f32, self.positions.items);
        mesh.texcoords = try copyToRaylibAlloc(f32, self.texcoords.items);
        mesh.texcoords2 = try copyToRaylibAlloc(f32, self.texcoords2.items);
        mesh.normals = try copyToRaylibAlloc(f32, self.normals.items);
        mesh.colors = try copyToRaylibAlloc(u8, self.colors.items);

        rl.uploadMesh(&mesh, false);
        return mesh;
    }
};

const SampledVertex = struct {
    position: [3]f32,
    texcoord: [2]f32,
    lightmap_uv: [2]f32,
    normal: [3]f32,
    color: [4]u8,
};

fn samplePatch(control: [3][3]bsp.Vertex, u: f32, v: f32) SampledVertex {
    const wu = quadraticWeights(u);
    const wv = quadraticWeights(v);

    var position = [3]f32{ 0.0, 0.0, 0.0 };
    var texcoord = [2]f32{ 0.0, 0.0 };
    var lightmap_uv = [2]f32{ 0.0, 0.0 };
    var normal = [3]f32{ 0.0, 0.0, 0.0 };
    var color = [4]f32{ 0.0, 0.0, 0.0, 0.0 };

    var row: usize = 0;
    while (row < 3) : (row += 1) {
        var col: usize = 0;
        while (col < 3) : (col += 1) {
            const weight = wu[col] * wv[row];
            const vertex = control[row][col];

            position[0] += vertex.position[0] * weight;
            position[1] += vertex.position[1] * weight;
            position[2] += vertex.position[2] * weight;

            texcoord[0] += vertex.texcoord[0] * weight;
            texcoord[1] += vertex.texcoord[1] * weight;

            lightmap_uv[0] += vertex.lightmap_uv[0] * weight;
            lightmap_uv[1] += vertex.lightmap_uv[1] * weight;

            normal[0] += vertex.normal[0] * weight;
            normal[1] += vertex.normal[1] * weight;
            normal[2] += vertex.normal[2] * weight;

            color[0] += @as(f32, @floatFromInt(vertex.color[0])) * weight;
            color[1] += @as(f32, @floatFromInt(vertex.color[1])) * weight;
            color[2] += @as(f32, @floatFromInt(vertex.color[2])) * weight;
            color[3] += @as(f32, @floatFromInt(vertex.color[3])) * weight;
        }
    }

    return .{
        .position = position,
        .texcoord = texcoord,
        .lightmap_uv = lightmap_uv,
        .normal = normal,
        .color = .{
            clampColor(color[0]),
            clampColor(color[1]),
            clampColor(color[2]),
            clampColor(color[3]),
        },
    };
}

fn quadraticWeights(t: f32) [3]f32 {
    const inv = 1.0 - t;
    return .{
        inv * inv,
        2.0 * inv * t,
        t * t,
    };
}

fn clampColor(value: f32) u8 {
    return @intFromFloat(@max(0.0, @min(255.0, value)));
}

fn normalizeVector(v: rl.Vector3) rl.Vector3 {
    const len_sq = v.x * v.x + v.y * v.y + v.z * v.z;
    if (len_sq <= 0.000001) {
        return .{ .x = 0.0, .y = 1.0, .z = 0.0 };
    }
    const inv_len = 1.0 / @sqrt(len_sq);
    return .{
        .x = v.x * inv_len,
        .y = v.y * inv_len,
        .z = v.z * inv_len,
    };
}

fn shouldReverseTriangleVertices(
    a_position: [3]f32,
    b_position: [3]f32,
    c_position: [3]f32,
    face_normal: [3]f32,
    preferred_reverse_winding: bool,
) bool {
    const pa = bsp.toEngineSpace(a_position);
    const pb = bsp.toEngineSpace(b_position);
    const pc = bsp.toEngineSpace(c_position);

    const edge_ab = rl.Vector3{ .x = pb.x - pa.x, .y = pb.y - pa.y, .z = pb.z - pa.z };
    const edge_ac = rl.Vector3{ .x = pc.x - pa.x, .y = pc.y - pa.y, .z = pc.z - pa.z };
    const geometric_normal = rl.Vector3{
        .x = edge_ab.y * edge_ac.z - edge_ab.z * edge_ac.y,
        .y = edge_ab.z * edge_ac.x - edge_ab.x * edge_ac.z,
        .z = edge_ab.x * edge_ac.y - edge_ab.y * edge_ac.x,
    };
    const geometric_len_sq = geometric_normal.x * geometric_normal.x +
        geometric_normal.y * geometric_normal.y +
        geometric_normal.z * geometric_normal.z;
    if (geometric_len_sq <= 0.000001) return preferred_reverse_winding;

    const expected_normal = bsp.toEngineNormal(face_normal);
    const expected_len_sq = expected_normal.x * expected_normal.x +
        expected_normal.y * expected_normal.y +
        expected_normal.z * expected_normal.z;
    if (expected_len_sq <= 0.000001) return preferred_reverse_winding;

    const dot = geometric_normal.x * expected_normal.x +
        geometric_normal.y * expected_normal.y +
        geometric_normal.z * expected_normal.z;
    return dot < 0.0;
}

fn copyToRaylibAlloc(comptime T: type, items: []const T) ![*c]T {
    if (items.len == 0) return null;

    const byte_len = items.len * @sizeOf(T);
    const raw_ptr = rl.memAlloc(@intCast(byte_len));
    if (@intFromPtr(raw_ptr) == 0) return error.OutOfMemory;

    const typed_ptr: [*]T = @ptrCast(@alignCast(raw_ptr));
    @memcpy(typed_ptr[0..items.len], items);
    return @ptrCast(typed_ptr);
}

fn loadTextureFromBytes(allocator: std.mem.Allocator, ext: []const u8, file_data: []const u8) !rl.Texture2D {
    if (std.ascii.eqlIgnoreCase(ext, ".tga")) {
        return loadTgaTexture(allocator, file_data);
    }

    return loadTextureFromMemory(ext, file_data);
}

fn loadTextureFromMemory(ext: []const u8, file_data: []const u8) !rl.Texture2D {
    var ext_buf: [8]u8 = undefined;
    const ext_z = try std.fmt.bufPrintZ(&ext_buf, "{s}", .{ext});
    const image = try rl.loadImageFromMemory(ext_z, file_data);
    defer rl.unloadImage(image);
    return rl.loadTextureFromImage(image);
}

fn loadTgaTexture(allocator: std.mem.Allocator, file_data: []const u8) !rl.Texture2D {
    const decoded = try tga.decode(allocator, file_data);
    defer allocator.free(decoded.pixels);

    const raw = try copyToRaylibAlloc(u8, decoded.pixels);
    const image = rl.Image{
        .data = raw,
        .width = decoded.width,
        .height = decoded.height,
        .mipmaps = 1,
        .format = .uncompressed_r8g8b8a8,
    };
    defer rl.unloadImage(image);

    return rl.loadTextureFromImage(image);
}

fn trimShaderLine(raw_line: []const u8) []const u8 {
    const comment_index = std.mem.indexOf(u8, raw_line, "//") orelse raw_line.len;
    return std.mem.trim(u8, raw_line[0..comment_index], " \t\r");
}

fn extractStageTarget(line: []const u8) ?[]const u8 {
    const target = extractRawStageTarget(line) orelse return null;
    return if (isShaderImageTarget(target)) target else null;
}

fn extractRawStageTarget(line: []const u8) ?[]const u8 {
    var tokens = std.mem.tokenizeAny(u8, line, " \t\r");
    const keyword = tokens.next() orelse return null;

    if (std.mem.eql(u8, keyword, "map") or std.mem.eql(u8, keyword, "clampmap")) {
        return tokens.next() orelse return null;
    }
    if (std.mem.eql(u8, keyword, "animmap") or std.mem.eql(u8, keyword, "oneshotanimmap")) {
        _ = tokens.next() orelse return null;
        return tokens.next() orelse return null;
    }

    return null;
}

fn extractEditorTarget(line: []const u8) ?[]const u8 {
    var tokens = std.mem.tokenizeAny(u8, line, " \t\r");
    const keyword = tokens.next() orelse return null;
    if (!std.mem.eql(u8, keyword, "qer_editorimage")) return null;

    const target = tokens.next() orelse return null;
    return if (isShaderImageTarget(target)) target else null;
}

fn isShaderImageTarget(target: []const u8) bool {
    if (target.len == 0) return false;
    if (target[0] == '$') return false;
    return true;
}

fn applyMaterialKeyword(rule: *MaterialRule, line: []const u8) void {
    var tokens = std.mem.tokenizeAny(u8, line, " \t\r");
    const keyword = tokens.next() orelse return;

    if (std.mem.eql(u8, keyword, "surfaceparm")) {
        const parm = tokens.next() orelse return;
        if (std.mem.eql(u8, parm, "nolightmap")) {
            rule.use_lightmap = false;
        } else if (std.mem.eql(u8, parm, "fog") or std.mem.eql(u8, parm, "sky") or std.mem.eql(u8, parm, "nodraw")) {
            rule.skip = true;
        } else if (std.mem.eql(u8, parm, "trans")) {
            if (rule.render_mode == .solid) rule.render_mode = .alpha;
        }
        return;
    }

    if (std.mem.eql(u8, keyword, "cull")) {
        const mode = tokens.next() orelse return;
        if (std.mem.eql(u8, mode, "disable") or std.mem.eql(u8, mode, "none")) {
            rule.double_sided = true;
        }
    }
}

fn parseBlendMode(first: []const u8, second: ?[]const u8) ?StageBlend {
    if (std.mem.eql(u8, first, "add")) return .additive;
    if (std.mem.eql(u8, first, "blend")) return .alpha;
    if (std.mem.eql(u8, first, "filter")) return .filter;

    if (second) |rhs| {
        if ((std.mem.eql(u8, first, "GL_DST_COLOR") or std.mem.eql(u8, first, "gl_dst_color")) and
            (std.mem.eql(u8, rhs, "GL_ZERO") or std.mem.eql(u8, rhs, "gl_zero")))
        {
            return .filter;
        }
        if ((std.mem.eql(u8, first, "GL_ONE") or std.mem.eql(u8, first, "gl_one")) and
            (std.mem.eql(u8, rhs, "GL_ONE") or std.mem.eql(u8, rhs, "gl_one")))
        {
            return .additive;
        }
        if ((std.mem.eql(u8, first, "GL_SRC_ALPHA") or std.mem.eql(u8, first, "gl_src_alpha")) and
            (std.mem.eql(u8, rhs, "GL_ONE") or std.mem.eql(u8, rhs, "gl_one")))
        {
            return .additive;
        }
        if ((std.mem.eql(u8, first, "GL_SRC_ALPHA") or std.mem.eql(u8, first, "gl_src_alpha")) and
            (std.mem.eql(u8, rhs, "GL_ONE_MINUS_SRC_ALPHA") or std.mem.eql(u8, rhs, "gl_one_minus_src_alpha")))
        {
            return .alpha;
        }
    }

    return null;
}

fn normalizeOwned(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    const owned = try allocator.dupe(u8, text);
    for (owned) |*byte| {
        if (byte.* == '\\') byte.* = '/';
        byte.* = std.ascii.toLower(byte.*);
    }
    return owned;
}

fn normalizeLookupStem(stem: []const u8) []const u8 {
    var out = stem;

    if (stripLightSuffix(out)) |trimmed| out = trimmed;
    if (stripTokenSuffix(out, "_trans")) |trimmed| out = trimmed;
    if (stripTokenSuffix(out, "_shiny")) |trimmed| out = trimmed;
    if (stripTokenSuffix(out, "_drops")) |trimmed| out = trimmed;
    if (stripTokenSuffix(out, "_blue")) |trimmed| out = trimmed;
    if (stripTokenSuffix(out, "_red")) |trimmed| out = trimmed;
    if (stripTokenSuffix(out, "_green")) |trimmed| out = trimmed;
    if (stripTokenSuffix(out, "_yellow")) |trimmed| out = trimmed;
    if (stripTokenSuffix(out, "new")) |trimmed| out = trimmed;
    if (stripTrailingDigits(out)) |trimmed| out = trimmed;
    if (stripTrailingSingleAlpha(out)) |trimmed| out = trimmed;

    return out;
}

fn stripLightSuffix(stem: []const u8) ?[]const u8 {
    const underscore = std.mem.lastIndexOfScalar(u8, stem, '_') orelse return null;
    const suffix = stem[underscore + 1 ..];
    if (suffix.len < 2 or suffix[suffix.len - 1] != 'k') return null;
    for (suffix[0 .. suffix.len - 1]) |ch| {
        if (!std.ascii.isDigit(ch)) return null;
    }
    return stem[0..underscore];
}

fn stripTokenSuffix(stem: []const u8, suffix: []const u8) ?[]const u8 {
    if (stem.len <= suffix.len) return null;
    if (!std.mem.endsWith(u8, stem, suffix)) return null;
    return stem[0 .. stem.len - suffix.len];
}

fn stripTrailingDigits(stem: []const u8) ?[]const u8 {
    var end = stem.len;
    while (end > 0 and std.ascii.isDigit(stem[end - 1])) : (end -= 1) {}
    if (end == stem.len or end == 0) return null;
    return stem[0..end];
}

fn stripTrailingSingleAlpha(stem: []const u8) ?[]const u8 {
    if (stem.len < 2) return null;
    const last = stem[stem.len - 1];
    if (!std.ascii.isAlphabetic(last)) return null;
    if (!std.ascii.isDigit(stem[stem.len - 2])) return null;
    return stem[0 .. stem.len - 1];
}

fn fuzzyScore(query: []const u8, candidate: []const u8) usize {
    if (query.len == 0 or candidate.len == 0) return 0;
    if (std.mem.eql(u8, query, candidate)) return query.len + 100;
    if (std.mem.startsWith(u8, candidate, query) or std.mem.startsWith(u8, query, candidate)) {
        return @min(query.len, candidate.len) + 50;
    }

    const prefix_len = commonPrefixLen(query, candidate);
    if (prefix_len >= 6) return prefix_len;
    return 0;
}

fn commonPrefixLen(a: []const u8, b: []const u8) usize {
    var index: usize = 0;
    while (index < a.len and index < b.len and a[index] == b[index]) : (index += 1) {}
    return index;
}

fn shouldSkipTexture(texture_name: []const u8) bool {
    return std.mem.startsWith(u8, texture_name, "textures/common/");
}
