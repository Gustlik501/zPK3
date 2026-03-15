const std = @import("std");
const rl = @import("raylib");
const rlgl = rl.gl;
const archive = @import("archive.zig");
const bsp = @import("bsp.zig");
const qmath = @import("math.zig");
const qscene = @import("scene.zig");
const qshader = @import("shader.zig");
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

pub const SceneStats = qscene.SceneStats;
const RenderMode = qscene.RenderMode;
const MaterialRule = qscene.MaterialRule;

const SurfaceBatch = struct {
    binding: MaterialBinding,
    model: rl.Model,
    wire_positions: []f32,
    material_name: []const u8,
    owner_bsp_model_index: usize,
    render_mode: RenderMode,
    use_lightmap: bool,
    double_sided: bool,
    alpha_cutoff: f32,
};

const MaterialBinding = struct {
    mode: enum {
        static,
        animated_loop,
        animated_once,
    } = .static,
    static_texture: rl.Texture2D,
    animated_frames: []rl.Texture2D = &.{},
    fps: f32 = 0.0,

    fn deinit(self: *MaterialBinding, allocator: std.mem.Allocator) void {
        allocator.free(self.animated_frames);
        self.* = undefined;
    }

    fn currentTexture(self: *const MaterialBinding, time_seconds: f64) rl.Texture2D {
        switch (self.mode) {
            .static => return self.static_texture,
            .animated_loop, .animated_once => {
                if (self.animated_frames.len == 0 or self.fps <= 0.0) return self.static_texture;
                const raw_index: usize = @intFromFloat(@max(@floor(time_seconds * @as(f64, self.fps)), 0.0));
                const frame_index = switch (self.mode) {
                    .animated_loop => raw_index % self.animated_frames.len,
                    .animated_once => @min(raw_index, self.animated_frames.len - 1),
                    .static => unreachable,
                };
                return self.animated_frames[frame_index];
            },
        }
    }
};

pub const SceneObject = struct {
    entity_index: usize,
    kind: qscene.ModelInstanceKind,
    classname: []const u8,
    targetname: ?[]const u8,
    model_path: ?[]const u8,
    bsp_model_index: ?usize,
    origin: qmath.Vec3,
    bounds: ?rl.BoundingBox,

    pub fn deinit(self: *SceneObject, allocator: std.mem.Allocator) void {
        allocator.free(self.classname);
        if (self.targetname) |targetname| allocator.free(targetname);
        if (self.model_path) |model_path| allocator.free(model_path);
        self.* = undefined;
    }
};

pub const SceneRenderer = struct {
    allocator: std.mem.Allocator,
    batches: []SurfaceBatch,
    scene_objects: []SceneObject,
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
    draw_scene_objects: bool = true,
    draw_world_geometry: bool = true,
    draw_submodel_geometry: bool = true,
    isolate_selected_submodel: bool = false,
    selected_scene_object_index: ?usize = null,

    pub fn init(allocator: std.mem.Allocator, packs: *archive.Pk3Collection, map: *const bsp.Map) !SceneRenderer {
        var texture_cache = try TextureCache.init(allocator, packs);
        errdefer texture_cache.deinit();

        var lightmap_cache = try LightmapCache.init(allocator, map);
        errdefer lightmap_cache.deinit();

        const lightmap_shader = try createLightmapShader();
        errdefer rl.unloadShader(lightmap_shader);

        var extracted_scene = try qscene.Scene.init(allocator, map, &texture_cache);
        defer extracted_scene.deinit();

        var stats: SceneStats = extracted_scene.stats;

        var batch_list: std.ArrayList(SurfaceBatch) = .empty;
        errdefer {
            for (batch_list.items) |*batch| {
                batch.binding.deinit(allocator);
                rl.unloadModel(batch.model);
                allocator.free(batch.wire_positions);
                allocator.free(batch.material_name);
            }
            batch_list.deinit(allocator);
        }

        const scene_objects = try buildSceneObjects(allocator, map, extracted_scene.model_instances);
        errdefer {
            for (scene_objects) |*object| object.deinit(allocator);
            allocator.free(scene_objects);
        }

        for (extracted_scene.batches) |*batch| {
            const mesh = try loadMeshFromBatch(batch);
            var model = try rl.loadModelFromMesh(mesh);
            const wire_positions = try allocator.dupe(f32, batch.positions);
            errdefer allocator.free(wire_positions);
            const material_name = try allocator.dupe(u8, batch.texture_name);
            errdefer allocator.free(material_name);
            const binding = try texture_cache.buildMaterialBinding(batch.texture_name);
            errdefer {
                var owned_binding = binding;
                owned_binding.deinit(allocator);
            }
            const texture = binding.currentTexture(0.0);
            const lightmap = lightmap_cache.getTexture(batch.lightmap_index);
            if (texture_cache.was_missing_last_load) {
                stats.missing_texture_count += 1;
            }
            if (binding.mode != .static) {
                stats.animated_batch_count += 1;
            }

            stats.geometry_memory_bytes += batchMemoryBytes(batch);
            stats.wireframe_memory_bytes += wire_positions.len * @sizeOf(f32);
            stats.material_memory_bytes += material_name.len + bindingMemoryBytes(binding);

            model.materials[0].shader = lightmap_shader;
            model.materials[0].maps[@intFromEnum(rl.MATERIAL_MAP_DIFFUSE)].texture = texture;
            model.materials[0].maps[@intFromEnum(rl.MaterialMapIndex.emission)].texture = lightmap;
            try batch_list.append(allocator, .{
                .binding = binding,
                .model = model,
                .wire_positions = wire_positions,
                .material_name = material_name,
                .owner_bsp_model_index = batch.owner_bsp_model_index,
                .render_mode = batch.render_mode,
                .use_lightmap = batch.use_lightmap,
                .double_sided = batch.double_sided,
                .alpha_cutoff = batch.alpha_cutoff,
            });
        }

        stats.loaded_texture_count = texture_cache.loadedTextureCount();
        stats.texture_memory_bytes = texture_cache.loadedTextureMemoryBytes();
        stats.lightmap_texture_count = lightmap_cache.textureCount();
        stats.lightmap_memory_bytes = lightmap_cache.memoryBytesEstimate();

        return .{
            .allocator = allocator,
            .batches = try batch_list.toOwnedSlice(allocator),
            .scene_objects = scene_objects,
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
        for (self.batches) |*batch| {
            batch.binding.deinit(self.allocator);
            rl.unloadModel(batch.model);
            self.allocator.free(batch.wire_positions);
            self.allocator.free(batch.material_name);
        }
        self.allocator.free(self.batches);
        for (self.scene_objects) |*object| object.deinit(self.allocator);
        self.allocator.free(self.scene_objects);
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
        if (rl.isKeyPressed(.f4)) {
            self.draw_scene_objects = !self.draw_scene_objects;
        }
        if (rl.isKeyPressed(.f5)) {
            self.draw_world_geometry = !self.draw_world_geometry;
        }
        if (rl.isKeyPressed(.f6)) {
            self.draw_submodel_geometry = !self.draw_submodel_geometry;
        }
        if (rl.isKeyPressed(.f7)) {
            self.isolate_selected_submodel = !self.isolate_selected_submodel;
        }
        if (rl.isKeyPressed(.tab)) {
            self.stepSelectedSceneObject(if (isShiftDown()) -1 else 1);
        }

        self.stats.drawn_batch_count = 0;
        self.stats.drawn_vertex_count = 0;

        self.drawBatches(.solid);
        self.drawBatches(.alpha);
        self.drawBatches(.additive);
        if (self.draw_scene_objects) self.drawSceneObjects();
        rlgl.rlEnableBackfaceCulling();
    }

    pub fn selectedSceneObject(self: *const SceneRenderer) ?*const SceneObject {
        const index = self.selected_scene_object_index orelse return null;
        if (index >= self.scene_objects.len) return null;
        return &self.scene_objects[index];
    }

    pub fn setSelectedSceneObject(self: *SceneRenderer, index: ?usize) void {
        if (index) |value| {
            if (value >= self.scene_objects.len) return;
        }
        self.selected_scene_object_index = index;
    }

    pub fn selectNextSceneObject(self: *SceneRenderer) void {
        self.stepSelectedSceneObject(1);
    }

    pub fn selectPreviousSceneObject(self: *SceneRenderer) void {
        self.stepSelectedSceneObject(-1);
    }

    pub fn selectedSceneObjectBatchCount(self: *const SceneRenderer) usize {
        const object = self.selectedSceneObject() orelse return 0;
        if (object.bsp_model_index) |model_index| {
            var count: usize = 0;
            for (self.batches) |batch| {
                if (batch.owner_bsp_model_index == model_index) count += 1;
            }
            return count;
        }
        return 0;
    }

    pub fn selectedSceneObjectFocusPoint(self: *const SceneRenderer) ?qmath.Vec3 {
        const object = self.selectedSceneObject() orelse return null;
        if (object.bounds) |bounds| {
            return .{
                .x = (bounds.min.x + bounds.max.x) * 0.5,
                .y = (bounds.min.y + bounds.max.y) * 0.5,
                .z = (bounds.min.z + bounds.max.z) * 0.5,
            };
        }
        return object.origin;
    }

    pub fn estimatedSceneObjectMemoryBytes(self: *const SceneRenderer) usize {
        var total: usize = self.scene_objects.len * @sizeOf(SceneObject);
        for (self.scene_objects) |object| {
            total += object.classname.len;
            if (object.targetname) |targetname| total += targetname.len;
            if (object.model_path) |model_path| total += model_path.len;
        }
        return total;
    }

    pub fn estimatedCacheMetadataMemoryBytes(self: *const SceneRenderer) usize {
        return self.texture_cache.metadataMemoryBytes() + self.lightmap_cache.metadataMemoryBytes();
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

        const time_seconds = rl.getTime();
        for (self.batches) |*batch| {
            if (batch.render_mode != mode) continue;
            if (batch.owner_bsp_model_index == 0 and !self.draw_world_geometry) continue;
            if (batch.owner_bsp_model_index != 0 and !self.draw_submodel_geometry) continue;
            if (self.isolate_selected_submodel) {
                if (self.selectedBspModelIndex()) |model_index| {
                    if (batch.owner_bsp_model_index != model_index) continue;
                }
            }

            const use_lightmap: i32 = if (self.fullbright or self.draw_wireframe or !batch.use_lightmap) 0 else 1;
            const lightmap_scale: f32 = if (self.fullbright or self.draw_wireframe or !batch.use_lightmap) 1.0 else 2.0;
            rl.setShaderValue(self.lightmap_shader, self.lightmap_use_loc, &use_lightmap, .int);
            rl.setShaderValue(self.lightmap_shader, self.lightmap_scale_loc, &lightmap_scale, .float);
            rl.setShaderValue(self.lightmap_shader, self.alpha_cutoff_loc, &batch.alpha_cutoff, .float);

            const texture = batch.binding.currentTexture(time_seconds);
            batch.model.materials[0].maps[@intFromEnum(rl.MATERIAL_MAP_DIFFUSE)].texture = texture;

            if (!self.backface_culling or batch.double_sided) {
                rlgl.rlDisableBackfaceCulling();
            } else {
                rlgl.rlEnableBackfaceCulling();
            }

            if (self.draw_wireframe) {
                drawWireTriangles(batch.wire_positions, .{ .r = 96, .g = 255, .b = 128, .a = 255 });
            } else {
                rl.drawModel(batch.model, .{ .x = 0, .y = 0, .z = 0 }, 1.0, .white);
            }

            self.stats.drawn_batch_count += 1;
            self.stats.drawn_vertex_count += batch.wire_positions.len / 3;
        }
    }

    fn drawSceneObjects(self: *SceneRenderer) void {
        const selected_index = self.selected_scene_object_index;
        for (self.scene_objects, 0..) |object, object_index| {
            const is_selected = selected_index != null and selected_index.? == object_index;
            switch (object.kind) {
                .bsp_submodel => {
                    const color: rl.Color = if (is_selected) .yellow else .orange;
                    if (object.bounds) |bounds| {
                        rl.drawBoundingBox(bounds, color);
                    } else {
                        rl.drawSphereWires(toRlVector3(object.origin), 12.0, 8, 8, color);
                    }
                },
                .external_model => {
                    const box_color: rl.Color = if (is_selected) .lime else .sky_blue;
                    const sphere_color: rl.Color = if (is_selected) .green else .blue;
                    rl.drawCubeWiresV(toRlVector3(object.origin), .{ .x = 12.0, .y = 12.0, .z = 12.0 }, box_color);
                    rl.drawSphereWires(toRlVector3(object.origin), 6.0, 6, 6, sphere_color);
                },
            }
        }
    }

    fn stepSelectedSceneObject(self: *SceneRenderer, step: i32) void {
        if (self.scene_objects.len == 0) {
            self.selected_scene_object_index = null;
            return;
        }

        if (self.selected_scene_object_index == null) {
            self.selected_scene_object_index = if (step < 0) self.scene_objects.len - 1 else 0;
            return;
        }

        const current: i32 = @intCast(self.selected_scene_object_index.?);
        const len: i32 = @intCast(self.scene_objects.len);
        const next = @mod(current + step, len);
        self.selected_scene_object_index = @intCast(next);
    }

    fn selectedBspModelIndex(self: *const SceneRenderer) ?usize {
        const object = self.selectedSceneObject() orelse return null;
        return object.bsp_model_index;
    }
};

const TextureCache = struct {
    allocator: std.mem.Allocator,
    packs: *archive.Pk3Collection,
    shaders: qshader.Library,
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

        var shaders = try qshader.Library.init(allocator, packs);
        errdefer shaders.deinit();

        var cache = TextureCache{
            .allocator = allocator,
            .packs = packs,
            .shaders = shaders,
            .textures = std.StringHashMap(rl.Texture2D).init(allocator),
            .shader_aliases = std.StringHashMap([]const u8).init(allocator),
            .material_rules = std.StringHashMap(MaterialRule).init(allocator),
            .fallback_paths = std.StringHashMap([]const u8).init(allocator),
            .fallback_ambiguous = std.StringHashMap(void).init(allocator),
            .image_paths = .empty,
            .placeholder = try rl.loadTextureFromImage(image),
        };
        errdefer cache.deinit();

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
        self.shaders.deinit();

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

    fn loadedTextureCount(self: *const TextureCache) usize {
        return self.textures.count();
    }

    fn loadedTextureMemoryBytes(self: *const TextureCache) usize {
        var total: usize = 0;
        var it = self.textures.iterator();
        while (it.next()) |entry| {
            total += textureMemoryBytesEstimate(entry.value_ptr.*);
        }
        return total;
    }

    fn metadataMemoryBytes(self: *const TextureCache) usize {
        var total: usize = @sizeOf(TextureCache) + self.image_paths.items.len * @sizeOf([]const u8);

        var texture_it = self.textures.iterator();
        while (texture_it.next()) |entry| {
            total += entry.key_ptr.*.len;
            total += @sizeOf(rl.Texture2D);
        }

        var alias_it = self.shader_aliases.iterator();
        while (alias_it.next()) |entry| {
            total += entry.key_ptr.*.len + entry.value_ptr.*.len;
        }

        var rule_it = self.material_rules.iterator();
        while (rule_it.next()) |entry| {
            total += entry.key_ptr.*.len + @sizeOf(MaterialRule);
        }

        var fallback_it = self.fallback_paths.iterator();
        while (fallback_it.next()) |entry| {
            total += entry.key_ptr.*.len + entry.value_ptr.*.len;
        }

        var ambiguous_it = self.fallback_ambiguous.iterator();
        while (ambiguous_it.next()) |entry| {
            total += entry.key_ptr.*.len;
        }

        for (self.image_paths.items) |path| total += path.len;

        total += self.shaders.estimatedMemoryBytes();
        return total;
    }

    pub fn getTextureForMaterial(self: *TextureCache, material_name: []const u8, time_seconds: f64) !rl.Texture2D {
        self.was_missing_last_load = false;

        const target_name = self.resolveMaterialTexture(material_name, time_seconds);
        if (target_name) |resolved_name| {
            if (try self.tryLoadResolvedTexture(resolved_name)) |texture| {
                return texture;
            }
        }

        self.was_missing_last_load = true;
        return self.placeholder;
    }

    pub fn buildMaterialBinding(self: *TextureCache, material_name: []const u8) !MaterialBinding {
        self.was_missing_last_load = false;

        if (self.shaders.get(material_name)) |definition| {
            for (definition.stages) |stage| {
                switch (stage.map_kind) {
                    .animmap, .oneshotanimmap => {
                        if (stage.anim_frames.len == 0) continue;

                        const frames = try self.allocator.alloc(rl.Texture2D, stage.anim_frames.len);
                        errdefer self.allocator.free(frames);

                        for (stage.anim_frames, 0..) |frame_name, frame_index| {
                            const texture = try self.tryLoadResolvedTexture(frame_name) orelse self.placeholder;
                            if (texture.id == self.placeholder.id) self.was_missing_last_load = true;
                            frames[frame_index] = texture;
                        }

                        return .{
                            .mode = if (stage.map_kind == .oneshotanimmap) .animated_once else .animated_loop,
                            .static_texture = frames[0],
                            .animated_frames = frames,
                            .fps = stage.fps,
                        };
                    },
                    .map, .clampmap => {
                        if (stage.texture) |texture_name| {
                            const texture = try self.tryLoadResolvedTexture(texture_name) orelse self.placeholder;
                            if (texture.id == self.placeholder.id) self.was_missing_last_load = true;
                            return .{
                                .mode = .static,
                                .static_texture = texture,
                            };
                        }
                    },
                    .lightmap => {},
                }
            }

            if (definition.editor_image) |editor_image| {
                const texture = try self.tryLoadResolvedTexture(editor_image) orelse self.placeholder;
                if (texture.id == self.placeholder.id) self.was_missing_last_load = true;
                return .{
                    .mode = .static,
                    .static_texture = texture,
                };
            }
        }

        const texture = try self.tryLoadResolvedTexture(material_name) orelse self.placeholder;
        if (texture.id == self.placeholder.id) self.was_missing_last_load = true;
        return .{
            .mode = .static,
            .static_texture = texture,
        };
    }

    pub fn getMaterialRule(self: *const TextureCache, texture_name: []const u8) MaterialRule {
        var rule = MaterialRule{};
        if (self.shaders.get(texture_name)) |definition| {
            if (definition.surfaceparm_nolightmap) {
                rule.use_lightmap = false;
            }
            if (definition.surfaceparm_fog or definition.surfaceparm_sky or definition.surfaceparm_nodraw) {
                rule.skip = true;
            }
            if (definition.surfaceparm_trans and rule.render_mode == .solid) {
                rule.render_mode = .alpha;
            }
            if (definition.cull_mode == .none) {
                rule.double_sided = true;
            }

            for (definition.stages) |stage| {
                if (stage.map_kind == .lightmap) continue;
                if (stage.alpha_cutout) {
                    rule.alpha_cutoff = @max(rule.alpha_cutoff, 0.5);
                }

                switch (stage.blend_mode) {
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
        }
        if (std.mem.startsWith(u8, texture_name, "models/")) {
            rule.double_sided = true;
        }
        return rule;
    }

    fn resolveMaterialTexture(self: *const TextureCache, material_name: []const u8, time_seconds: f64) ?[]const u8 {
        if (self.shaders.get(material_name)) |definition| {
            return definition.resolveImage(time_seconds);
        }
        return material_name;
    }

    fn tryLoadResolvedTexture(self: *TextureCache, target_name: []const u8) !?rl.Texture2D {
        if (self.textures.get(target_name)) |texture| {
            return texture;
        }

        if (try self.loadTextureFile(target_name, target_name)) |texture| {
            return texture;
        }

        if (self.findFallbackPath(target_name)) |fallback_path| {
            if (std.mem.eql(u8, fallback_path, target_name)) return null;
            if (self.textures.get(fallback_path)) |texture| return texture;
            return try self.loadTextureFile(fallback_path, fallback_path);
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

    fn textureCount(self: *const LightmapCache) usize {
        return self.textures.len + 1;
    }

    fn memoryBytesEstimate(self: *const LightmapCache) usize {
        var total = textureMemoryBytesEstimate(self.white);
        for (self.textures) |texture| {
            total += textureMemoryBytesEstimate(texture);
        }
        return total;
    }

    fn metadataMemoryBytes(self: *const LightmapCache) usize {
        return @sizeOf(LightmapCache) + self.textures.len * @sizeOf(rl.Texture2D);
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

fn loadMeshFromBatch(batch: *const qscene.SurfaceBatch) !rl.Mesh {
    var mesh = std.mem.zeroes(rl.Mesh);
    mesh.vertexCount = @intCast(batch.vertex_count);
    mesh.triangleCount = @intCast(batch.vertex_count / 3);

    mesh.vertices = try copyToRaylibAlloc(f32, batch.positions);
    mesh.texcoords = try copyToRaylibAlloc(f32, batch.texcoords);
    mesh.texcoords2 = try copyToRaylibAlloc(f32, batch.texcoords2);
    mesh.normals = try copyToRaylibAlloc(f32, batch.normals);
    mesh.colors = try copyToRaylibAlloc(u8, batch.colors);

    rl.uploadMesh(&mesh, false);
    return mesh;
}

fn drawWireTriangles(positions: []const f32, color: rl.Color) void {
    if (positions.len < 9) return;

    const previous_width = rlgl.rlGetLineWidth();
    rlgl.rlSetLineWidth(1.5);
    defer rlgl.rlSetLineWidth(previous_width);

    rlgl.rlDisableBackfaceCulling();
    rlgl.rlBegin(rlgl.rl_lines);
    defer rlgl.rlEnd();

    rlgl.rlColor4ub(color.r, color.g, color.b, color.a);

    var i: usize = 0;
    while (i + 8 < positions.len) : (i += 9) {
        const ax = positions[i];
        const ay = positions[i + 1];
        const az = positions[i + 2];
        const bx = positions[i + 3];
        const by = positions[i + 4];
        const bz = positions[i + 5];
        const cx = positions[i + 6];
        const cy = positions[i + 7];
        const cz = positions[i + 8];

        rlgl.rlVertex3f(ax, ay, az);
        rlgl.rlVertex3f(bx, by, bz);

        rlgl.rlVertex3f(bx, by, bz);
        rlgl.rlVertex3f(cx, cy, cz);

        rlgl.rlVertex3f(cx, cy, cz);
        rlgl.rlVertex3f(ax, ay, az);
    }
}

fn batchMemoryBytes(batch: *const qscene.SurfaceBatch) usize {
    return batch.positions.len * @sizeOf(f32) +
        batch.texcoords.len * @sizeOf(f32) +
        batch.texcoords2.len * @sizeOf(f32) +
        batch.normals.len * @sizeOf(f32) +
        batch.colors.len * @sizeOf(u8) +
        batch.texture_name.len;
}

fn bindingMemoryBytes(binding: MaterialBinding) usize {
    return binding.animated_frames.len * @sizeOf(rl.Texture2D);
}

fn textureMemoryBytesEstimate(texture: rl.Texture2D) usize {
    if (texture.id == 0 or texture.width <= 0 or texture.height <= 0) return 0;

    var width = texture.width;
    var height = texture.height;
    var remaining_levels: i32 = @max(texture.mipmaps, 1);
    var total: usize = 0;

    while (remaining_levels > 0) : (remaining_levels -= 1) {
        total += @intCast(rl.getPixelDataSize(width, height, texture.format));
        if (width > 1) width = @max(@divFloor(width, 2), 1);
        if (height > 1) height = @max(@divFloor(height, 2), 1);
    }

    return total;
}

fn buildSceneObjects(
    allocator: std.mem.Allocator,
    map: *const bsp.Map,
    instances: []const qscene.ModelInstance,
) ![]SceneObject {
    const objects = try allocator.alloc(SceneObject, instances.len);
    var built_count: usize = 0;
    errdefer {
        for (objects[0..built_count]) |*object| object.deinit(allocator);
        allocator.free(objects);
    }
    for (instances, objects) |instance, *object| {
        object.* = .{
            .entity_index = instance.entity_index,
            .kind = instance.kind,
            .classname = try allocator.dupe(u8, instance.classname),
            .targetname = if (instance.targetname) |targetname| try allocator.dupe(u8, targetname) else null,
            .model_path = if (instance.model_path) |model_path| try allocator.dupe(u8, model_path) else null,
            .bsp_model_index = instance.bsp_model_index,
            .origin = instance.origin,
            .bounds = null,
        };

        if (instance.kind == .bsp_submodel) {
            if (instance.bsp_model_index) |model_index| {
                if (model_index < map.models.len) {
                    object.bounds = toBoundingBox(map.models[model_index]);
                }
            }
        }
        built_count += 1;
    }
    return objects;
}

fn isShiftDown() bool {
    return rl.isKeyDown(.left_shift) or rl.isKeyDown(.right_shift);
}

fn toRlVector3(v: qmath.Vec3) rl.Vector3 {
    return .{ .x = v.x, .y = v.y, .z = v.z };
}

fn toBoundingBox(model: bsp.Model) rl.BoundingBox {
    const a = bsp.toEngineSpace(model.mins);
    const b = bsp.toEngineSpace(model.maxs);
    return .{
        .min = .{
            .x = @min(a.x, b.x),
            .y = @min(a.y, b.y),
            .z = @min(a.z, b.z),
        },
        .max = .{
            .x = @max(a.x, b.x),
            .y = @max(a.y, b.y),
            .z = @max(a.z, b.z),
        },
    };
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
