const std = @import("std");
const bsp = @import("bsp.zig");
const entities = @import("entities.zig");
const qmath = @import("math.zig");

pub const SceneStats = struct {
    batch_count: usize = 0,
    billboard_count: usize = 0,
    face_count: usize = 0,
    vertex_count: usize = 0,
    missing_texture_count: usize = 0,
    drawn_batch_count: usize = 0,
    drawn_vertex_count: usize = 0,
    model_instance_count: usize = 0,
    bsp_submodel_instance_count: usize = 0,
    world_batch_count: usize = 0,
    submodel_batch_count: usize = 0,
    loaded_texture_count: usize = 0,
    lightmap_texture_count: usize = 0,
    animated_batch_count: usize = 0,
    geometry_memory_bytes: usize = 0,
    wireframe_memory_bytes: usize = 0,
    material_memory_bytes: usize = 0,
    visibility_memory_bytes: usize = 0,
    texture_memory_bytes: usize = 0,
    lightmap_memory_bytes: usize = 0,
    pvs_visible_world_batch_count: usize = 0,
    pvs_culled_world_batch_count: usize = 0,
    frustum_visible_world_batch_count: usize = 0,
    frustum_culled_world_batch_count: usize = 0,
};

pub const RenderMode = enum {
    solid,
    filter,
    alpha,
    additive,
};

pub const BillboardMode = enum {
    none,
    auto_sprite,
    auto_sprite2,
};

pub const MaterialRule = struct {
    skip: bool = false,
    use_lightmap: bool = true,
    render_mode: RenderMode = .solid,
    double_sided: bool = false,
    alpha_cutoff: f32 = 0.0,
    billboard_mode: BillboardMode = .none,
};

pub const SurfaceBatch = struct {
    owner_bsp_model_index: usize,
    texture_name: []const u8,
    lightmap_index: i32,
    render_mode: RenderMode,
    use_lightmap: bool,
    double_sided: bool,
    alpha_cutoff: f32,
    visible_clusters: []u8,
    bounds_min: qmath.Vec3,
    bounds_max: qmath.Vec3,
    positions: []f32,
    texcoords: []f32,
    texcoords2: []f32,
    normals: []f32,
    colors: []u8,
    vertex_count: usize,

    pub fn deinit(self: *SurfaceBatch, allocator: std.mem.Allocator) void {
        allocator.free(self.texture_name);
        allocator.free(self.visible_clusters);
        allocator.free(self.positions);
        allocator.free(self.texcoords);
        allocator.free(self.texcoords2);
        allocator.free(self.normals);
        allocator.free(self.colors);
        self.* = undefined;
    }
};

pub const BillboardSprite = struct {
    owner_bsp_model_index: usize,
    texture_name: []const u8,
    render_mode: RenderMode,
    alpha_cutoff: f32,
    billboard_mode: BillboardMode,
    visible_clusters: []u8,
    bounds_min: qmath.Vec3,
    bounds_max: qmath.Vec3,
    center: qmath.Vec3,
    size: [2]f32,
    up_axis: qmath.Vec3,
    color: [4]u8,

    pub fn deinit(self: *BillboardSprite, allocator: std.mem.Allocator) void {
        allocator.free(self.texture_name);
        allocator.free(self.visible_clusters);
        self.* = undefined;
    }
};

pub const ModelInstanceKind = enum {
    bsp_submodel,
    external_model,
};

pub const ModelInstance = struct {
    entity_index: usize,
    kind: ModelInstanceKind,
    classname: []const u8,
    targetname: ?[]const u8,
    model_path: ?[]const u8,
    bsp_model_index: ?usize,
    origin: qmath.Vec3,
    angles: qmath.Vec3,

    pub fn deinit(self: *ModelInstance, allocator: std.mem.Allocator) void {
        allocator.free(self.classname);
        if (self.targetname) |targetname| allocator.free(targetname);
        if (self.model_path) |model_path| allocator.free(model_path);
        self.* = undefined;
    }
};

pub const Scene = struct {
    allocator: std.mem.Allocator,
    batches: []SurfaceBatch,
    billboards: []BillboardSprite,
    model_instances: []ModelInstance,
    stats: SceneStats,

    pub fn init(allocator: std.mem.Allocator, map: *const bsp.Map, material_provider: anytype) !Scene {
        var builders: std.ArrayList(MeshBuilder) = .empty;
        defer {
            for (builders.items) |*builder| builder.deinit();
            builders.deinit(allocator);
        }

        const face_owner_models = try collectFaceOwnerModels(allocator, map);
        defer allocator.free(face_owner_models);
        var face_cluster_info = try collectFaceClusterInfo(allocator, map);
        defer face_cluster_info.deinit(allocator);

        var stats: SceneStats = .{};
        var billboard_list: std.ArrayList(BillboardSprite) = .empty;
        errdefer {
            for (billboard_list.items) |*billboard| billboard.deinit(allocator);
            billboard_list.deinit(allocator);
        }

        for (map.faces, 0..) |face, face_index| {
            if (face.texture < 0 or @as(usize, @intCast(face.texture)) >= map.textures.len) continue;
            const texture_name = map.textures[@intCast(face.texture)].name;
            const rule = material_provider.getMaterialRule(texture_name);
            if (rule.skip or shouldSkipTexture(texture_name)) continue;

            if (rule.billboard_mode != .none) {
                if (try buildBillboardSprite(
                    allocator,
                    map,
                    face,
                    face_owner_models[face_index],
                    texture_name,
                    rule,
                    face_cluster_info,
                    face_index,
                )) |billboard| {
                    try billboard_list.append(allocator, billboard);
                    stats.face_count += 1;
                }
                continue;
            }

            const builder = try getOrCreateBuilder(allocator, &builders, .{
                .owner_bsp_model_index = face_owner_models[face_index],
                .texture_name = texture_name,
                .lightmap_index = if (rule.use_lightmap) face.lightmap_index else -1,
                .rule = rule,
                .cluster_vector_bytes = face_cluster_info.bytes_per_face,
            });
            builder.includeFaceClusters(face_cluster_info, face_index);

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
            for (batch_list.items) |*batch| batch.deinit(allocator);
            batch_list.deinit(allocator);
        }

        var model_instances = try collectModelInstances(allocator, map);
        errdefer {
            for (model_instances.items) |*instance| instance.deinit(allocator);
            model_instances.deinit(allocator);
        }

        for (builders.items) |*builder| {
            if (builder.vertex_count == 0) continue;
            try batch_list.append(allocator, try builder.toBatch(allocator));
            stats.vertex_count += builder.vertex_count;
            if (builder.owner_bsp_model_index == 0) {
                stats.world_batch_count += 1;
            } else {
                stats.submodel_batch_count += 1;
            }
        }

        stats.billboard_count = billboard_list.items.len;
        stats.batch_count = batch_list.items.len + billboard_list.items.len;
        stats.model_instance_count = model_instances.items.len;
        for (model_instances.items) |instance| {
            if (instance.kind == .bsp_submodel) stats.bsp_submodel_instance_count += 1;
        }

        return .{
            .allocator = allocator,
            .batches = try batch_list.toOwnedSlice(allocator),
            .billboards = try billboard_list.toOwnedSlice(allocator),
            .model_instances = try model_instances.toOwnedSlice(allocator),
            .stats = stats,
        };
    }

    pub fn deinit(self: *Scene) void {
        for (self.batches) |*batch| batch.deinit(self.allocator);
        self.allocator.free(self.batches);
        for (self.billboards) |*billboard| billboard.deinit(self.allocator);
        self.allocator.free(self.billboards);
        for (self.model_instances) |*instance| instance.deinit(self.allocator);
        self.allocator.free(self.model_instances);
        self.* = undefined;
    }
};

const BatchKey = struct {
    owner_bsp_model_index: usize,
    texture_name: []const u8,
    lightmap_index: i32,
    rule: MaterialRule,
    cluster_vector_bytes: usize,
};

fn getOrCreateBuilder(
    allocator: std.mem.Allocator,
    builders: *std.ArrayList(MeshBuilder),
    key: BatchKey,
) !*MeshBuilder {
    for (builders.items) |*builder| {
        if (builder.owner_bsp_model_index == key.owner_bsp_model_index and
            builder.lightmap_index == key.lightmap_index and
            std.mem.eql(u8, builder.texture_name, key.texture_name) and
            builder.rule.render_mode == key.rule.render_mode and
            builder.rule.use_lightmap == key.rule.use_lightmap and
            builder.rule.double_sided == key.rule.double_sided and
            builder.rule.alpha_cutoff == key.rule.alpha_cutoff and
            builder.rule.billboard_mode == key.rule.billboard_mode and
            builder.visible_clusters.len == key.cluster_vector_bytes)
        {
            return builder;
        }
    }

    try builders.append(allocator, try MeshBuilder.init(
        allocator,
        key.owner_bsp_model_index,
        key.texture_name,
        key.lightmap_index,
        key.rule,
        key.cluster_vector_bytes,
    ));
    return &builders.items[builders.items.len - 1];
}

const MeshBuilder = struct {
    allocator: std.mem.Allocator,
    owner_bsp_model_index: usize,
    texture_name: []const u8,
    lightmap_index: i32,
    rule: MaterialRule,
    visible_clusters: []u8,
    bounds_min: qmath.Vec3,
    bounds_max: qmath.Vec3,
    has_bounds: bool = false,
    positions: std.ArrayList(f32),
    texcoords: std.ArrayList(f32),
    texcoords2: std.ArrayList(f32),
    normals: std.ArrayList(f32),
    colors: std.ArrayList(u8),
    vertex_count: usize = 0,

    fn init(
        allocator: std.mem.Allocator,
        owner_bsp_model_index: usize,
        texture_name: []const u8,
        lightmap_index: i32,
        rule: MaterialRule,
        cluster_vector_bytes: usize,
    ) !MeshBuilder {
        const visible_clusters = if (cluster_vector_bytes == 0)
            try allocator.alloc(u8, 0)
        else blk: {
            const bytes = try allocator.alloc(u8, cluster_vector_bytes);
            @memset(bytes, 0);
            break :blk bytes;
        };
        return .{
            .allocator = allocator,
            .owner_bsp_model_index = owner_bsp_model_index,
            .texture_name = try allocator.dupe(u8, texture_name),
            .lightmap_index = lightmap_index,
            .rule = rule,
            .visible_clusters = visible_clusters,
            .bounds_min = undefined,
            .bounds_max = undefined,
            .positions = .empty,
            .texcoords = .empty,
            .texcoords2 = .empty,
            .normals = .empty,
            .colors = .empty,
        };
    }

    fn deinit(self: *MeshBuilder) void {
        if (self.texture_name.len != 0) {
            self.allocator.free(self.texture_name);
        }
        self.allocator.free(self.visible_clusters);
        self.positions.deinit(self.allocator);
        self.texcoords.deinit(self.allocator);
        self.texcoords2.deinit(self.allocator);
        self.normals.deinit(self.allocator);
        self.colors.deinit(self.allocator);
    }

    fn includeFaceClusters(self: *MeshBuilder, info: FaceClusterInfo, face_index: usize) void {
        if (self.visible_clusters.len == 0 or face_index >= info.face_count) return;
        const start = face_index * info.bytes_per_face;
        const src = info.bytes[start .. start + info.bytes_per_face];
        for (self.visible_clusters, src) |*dst, value| {
            dst.* |= value;
        }
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
        self.expandBounds(position);

        try self.positions.appendSlice(self.allocator, &.{ position.x, position.y, position.z });
        try self.texcoords.appendSlice(self.allocator, &.{ vertex.texcoord[0], 1.0 - vertex.texcoord[1] });
        try self.texcoords2.appendSlice(self.allocator, &.{ vertex.lightmap_uv[0], 1.0 - vertex.lightmap_uv[1] });
        try self.normals.appendSlice(self.allocator, &.{ normal.x, normal.y, normal.z });
        try self.colors.appendSlice(self.allocator, &.{ vertex.color[0], vertex.color[1], vertex.color[2], vertex.color[3] });
        self.vertex_count += 1;
    }

    fn toBatch(self: *MeshBuilder, allocator: std.mem.Allocator) !SurfaceBatch {
        const texture_name = self.texture_name;
        self.texture_name = "";
        errdefer allocator.free(texture_name);
        const visible_clusters = self.visible_clusters;
        self.visible_clusters = try allocator.alloc(u8, 0);
        errdefer allocator.free(visible_clusters);

        const positions = try self.positions.toOwnedSlice(allocator);
        errdefer allocator.free(positions);

        const texcoords = try self.texcoords.toOwnedSlice(allocator);
        errdefer allocator.free(texcoords);

        const texcoords2 = try self.texcoords2.toOwnedSlice(allocator);
        errdefer allocator.free(texcoords2);

        const normals = try self.normals.toOwnedSlice(allocator);
        errdefer allocator.free(normals);

        const colors = try self.colors.toOwnedSlice(allocator);
        errdefer allocator.free(colors);

        return .{
            .owner_bsp_model_index = self.owner_bsp_model_index,
            .texture_name = texture_name,
            .lightmap_index = self.lightmap_index,
            .render_mode = self.rule.render_mode,
            .use_lightmap = self.rule.use_lightmap,
            .double_sided = self.rule.double_sided,
            .alpha_cutoff = self.rule.alpha_cutoff,
            .visible_clusters = visible_clusters,
            .bounds_min = self.bounds_min,
            .bounds_max = self.bounds_max,
            .positions = positions,
            .texcoords = texcoords,
            .texcoords2 = texcoords2,
            .normals = normals,
            .colors = colors,
            .vertex_count = self.vertex_count,
        };
    }

    fn expandBounds(self: *MeshBuilder, position: qmath.Vec3) void {
        if (!self.has_bounds) {
            self.bounds_min = position;
            self.bounds_max = position;
            self.has_bounds = true;
            return;
        }
        self.bounds_min.x = @min(self.bounds_min.x, position.x);
        self.bounds_min.y = @min(self.bounds_min.y, position.y);
        self.bounds_min.z = @min(self.bounds_min.z, position.z);
        self.bounds_max.x = @max(self.bounds_max.x, position.x);
        self.bounds_max.y = @max(self.bounds_max.y, position.y);
        self.bounds_max.z = @max(self.bounds_max.z, position.z);
    }
};

const SampledVertex = struct {
    position: [3]f32,
    texcoord: [2]f32,
    lightmap_uv: [2]f32,
    normal: [3]f32,
    color: [4]u8,
};

const FacePoint = struct {
    position: qmath.Vec3,
    color: [4]u8,
};

const FaceClusterInfo = struct {
    bytes_per_face: usize,
    face_count: usize,
    bytes: []u8,

    fn deinit(self: *FaceClusterInfo, allocator: std.mem.Allocator) void {
        allocator.free(self.bytes);
        self.* = undefined;
    }
};

fn collectFaceClusterInfo(allocator: std.mem.Allocator, map: *const bsp.Map) !FaceClusterInfo {
    const visdata = map.visdata orelse return .{
        .bytes_per_face = 0,
        .face_count = map.faces.len,
        .bytes = try allocator.alloc(u8, 0),
    };
    if (visdata.bytes_per_vector == 0 or map.faces.len == 0) {
        return .{
            .bytes_per_face = 0,
            .face_count = map.faces.len,
            .bytes = try allocator.alloc(u8, 0),
        };
    }

    const total_bytes = map.faces.len * visdata.bytes_per_vector;
    const bytes = try allocator.alloc(u8, total_bytes);
    @memset(bytes, 0);

    for (map.leaves) |leaf| {
        if (leaf.cluster < 0 or leaf.leafsurface_index < 0 or leaf.leafsurface_count <= 0) continue;
        const cluster_index: usize = @intCast(leaf.cluster);
        if (cluster_index >= visdata.vector_count) continue;

        const surface_start: usize = @intCast(leaf.leafsurface_index);
        const surface_count: usize = @intCast(leaf.leafsurface_count);
        if (surface_start + surface_count > map.leafsurfaces.len) continue;

        for (map.leafsurfaces[surface_start .. surface_start + surface_count]) |face_index_i32| {
            if (face_index_i32 < 0) continue;
            const face_index: usize = @intCast(face_index_i32);
            if (face_index >= map.faces.len) continue;

            const face_bytes = bytes[face_index * visdata.bytes_per_vector .. (face_index + 1) * visdata.bytes_per_vector];
            const byte_index = cluster_index / 8;
            if (byte_index >= face_bytes.len) continue;
            face_bytes[byte_index] |= @as(u8, 1) << @intCast(cluster_index & 7);
        }
    }

    return .{
        .bytes_per_face = visdata.bytes_per_vector,
        .face_count = map.faces.len,
        .bytes = bytes,
    };
}

fn buildBillboardSprite(
    allocator: std.mem.Allocator,
    map: *const bsp.Map,
    face: bsp.Face,
    owner_bsp_model_index: usize,
    texture_name: []const u8,
    rule: MaterialRule,
    face_cluster_info: FaceClusterInfo,
    face_index: usize,
) !?BillboardSprite {
    var points: std.ArrayList(FacePoint) = .empty;
    defer points.deinit(allocator);

    try collectFacePoints(allocator, &points, map, face);
    if (points.items.len < 3) return null;

    var center: qmath.Vec3 = .{ .x = 0.0, .y = 0.0, .z = 0.0 };
    var color_accum = [4]u32{ 0, 0, 0, 0 };
    for (points.items) |point| {
        center.x += point.position.x;
        center.y += point.position.y;
        center.z += point.position.z;
        color_accum[0] += point.color[0];
        color_accum[1] += point.color[1];
        color_accum[2] += point.color[2];
        color_accum[3] += point.color[3];
    }

    const count_f: f32 = @floatFromInt(points.items.len);
    center.x /= count_f;
    center.y /= count_f;
    center.z /= count_f;

    var major_axis = qmath.Vec3{ .x = 1.0, .y = 0.0, .z = 0.0 };
    var max_distance_sq: f32 = 0.0;
    for (points.items, 0..) |point_a, a_index| {
        for (points.items[a_index + 1 ..]) |point_b| {
            const delta = subtractVec3(point_b.position, point_a.position);
            const distance_sq = dotVec3(delta, delta);
            if (distance_sq > max_distance_sq) {
                max_distance_sq = distance_sq;
                major_axis = normalizeBillboardVec(delta);
            }
        }
    }
    if (max_distance_sq <= 0.0001) return null;

    var minor_axis = qmath.Vec3{ .x = 0.0, .y = 1.0, .z = 0.0 };
    var half_major: f32 = 0.0;
    var half_minor: f32 = 0.0;
    for (points.items) |point| {
        const relative = subtractVec3(point.position, center);
        const major_projection = dotVec3(relative, major_axis);
        half_major = @max(half_major, @abs(major_projection));

        const major_component = scaleVec3(major_axis, major_projection);
        const perpendicular = subtractVec3(relative, major_component);
        const perpendicular_length = lengthVec3(perpendicular);
        if (perpendicular_length > half_minor) {
            half_minor = perpendicular_length;
            minor_axis = normalizeBillboardVec(perpendicular);
        }
    }

    if (half_minor <= 0.001) half_minor = half_major;
    if (half_major <= 0.001) half_major = half_minor;
    if (half_major <= 0.001 or half_minor <= 0.001) return null;

    var size = [2]f32{ half_major * 2.0, half_minor * 2.0 };
    var up_axis = qmath.Vec3{ .x = 0.0, .y = 1.0, .z = 0.0 };
    if (rule.billboard_mode == .auto_sprite2) {
        if (half_major >= half_minor) {
            size = .{ half_minor * 2.0, half_major * 2.0 };
            up_axis = major_axis;
        } else {
            size = .{ half_major * 2.0, half_minor * 2.0 };
            up_axis = minor_axis;
        }
    }

    const radius = @max(half_major, half_minor);
    const point_count_u32: u32 = @intCast(points.items.len);
    const average_color: [4]u8 = .{
        @intCast(color_accum[0] / point_count_u32),
        @intCast(color_accum[1] / point_count_u32),
        @intCast(color_accum[2] / point_count_u32),
        @intCast(color_accum[3] / point_count_u32),
    };

    return .{
        .owner_bsp_model_index = owner_bsp_model_index,
        .texture_name = try allocator.dupe(u8, texture_name),
        .render_mode = rule.render_mode,
        .alpha_cutoff = rule.alpha_cutoff,
        .billboard_mode = rule.billboard_mode,
        .visible_clusters = try dupeFaceClusters(allocator, face_cluster_info, face_index),
        .bounds_min = .{
            .x = center.x - radius,
            .y = center.y - radius,
            .z = center.z - radius,
        },
        .bounds_max = .{
            .x = center.x + radius,
            .y = center.y + radius,
            .z = center.z + radius,
        },
        .center = center,
        .size = size,
        .up_axis = up_axis,
        .color = average_color,
    };
}

fn collectFacePoints(
    allocator: std.mem.Allocator,
    points: *std.ArrayList(FacePoint),
    map: *const bsp.Map,
    face: bsp.Face,
) !void {
    if (face.vertex_index < 0 or face.vertex_count <= 0) return;
    const base_vertex: usize = @intCast(face.vertex_index);
    const vertex_count: usize = @intCast(face.vertex_count);
    if (base_vertex + vertex_count > map.vertices.len) return;

    const vertices = map.vertices[base_vertex .. base_vertex + vertex_count];
    try points.ensureUnusedCapacity(allocator, vertices.len);
    for (vertices) |vertex| {
        points.appendAssumeCapacity(.{
            .position = bsp.toEngineSpace(vertex.position),
            .color = vertex.color,
        });
    }
}

fn dupeFaceClusters(allocator: std.mem.Allocator, info: FaceClusterInfo, face_index: usize) ![]u8 {
    if (info.bytes_per_face == 0 or face_index >= info.face_count) {
        return try allocator.alloc(u8, 0);
    }
    const start = face_index * info.bytes_per_face;
    return allocator.dupe(u8, info.bytes[start .. start + info.bytes_per_face]);
}

fn subtractVec3(a: qmath.Vec3, b: qmath.Vec3) qmath.Vec3 {
    return .{ .x = a.x - b.x, .y = a.y - b.y, .z = a.z - b.z };
}

fn scaleVec3(v: qmath.Vec3, scale: f32) qmath.Vec3 {
    return .{ .x = v.x * scale, .y = v.y * scale, .z = v.z * scale };
}

fn dotVec3(a: qmath.Vec3, b: qmath.Vec3) f32 {
    return a.x * b.x + a.y * b.y + a.z * b.z;
}

fn lengthVec3(v: qmath.Vec3) f32 {
    return @sqrt(dotVec3(v, v));
}

fn normalizeBillboardVec(v: qmath.Vec3) qmath.Vec3 {
    const length = lengthVec3(v);
    if (length <= 0.0001) return .{ .x = 0.0, .y = 1.0, .z = 0.0 };
    return scaleVec3(v, 1.0 / length);
}

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

fn normalizeVector(v: qmath.Vec3) qmath.Vec3 {
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

    const edge_ab = qmath.Vec3{ .x = pb.x - pa.x, .y = pb.y - pa.y, .z = pb.z - pa.z };
    const edge_ac = qmath.Vec3{ .x = pc.x - pa.x, .y = pc.y - pa.y, .z = pc.z - pa.z };
    const geometric_normal = qmath.Vec3{
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

fn shouldSkipTexture(texture_name: []const u8) bool {
    return std.mem.startsWith(u8, texture_name, "textures/common/");
}

fn collectFaceOwnerModels(allocator: std.mem.Allocator, map: *const bsp.Map) ![]usize {
    const owners = try allocator.alloc(usize, map.faces.len);
    @memset(owners, 0);

    if (map.models.len <= 1) return owners;

    for (map.models[1..], 1..) |model, model_index| {
        if (model.face_index < 0 or model.face_count <= 0) continue;
        const start: usize = @intCast(model.face_index);
        const count: usize = @intCast(model.face_count);
        if (start + count > owners.len) continue;
        for (owners[start .. start + count]) |*owner| {
            owner.* = model_index;
        }
    }

    return owners;
}

fn collectModelInstances(allocator: std.mem.Allocator, map: *const bsp.Map) !std.ArrayList(ModelInstance) {
    var entity_list = try map.parseEntities(allocator);
    defer entity_list.deinit();

    var instances: std.ArrayList(ModelInstance) = .empty;
    errdefer {
        for (instances.items) |*instance| instance.deinit(allocator);
        instances.deinit(allocator);
    }

    for (entity_list.items, 0..) |*entity, entity_index| {
        const classname = entity.classname() orelse continue;
        const model = entity.model() orelse continue;

        if (model.len != 0 and model[0] == '*') {
            const index = parseSubmodelIndex(model) orelse continue;
            if (index >= map.models.len) continue;

            try instances.append(allocator, .{
                .entity_index = entity_index,
                .kind = .bsp_submodel,
                .classname = try allocator.dupe(u8, classname),
                .targetname = if (entity.targetname()) |value| try allocator.dupe(u8, value) else null,
                .model_path = null,
                .bsp_model_index = index,
                .origin = entity.origin() orelse .{ .x = 0.0, .y = 0.0, .z = 0.0 },
                .angles = entityAngles(entity),
            });
            continue;
        }

        try instances.append(allocator, .{
            .entity_index = entity_index,
            .kind = .external_model,
            .classname = try allocator.dupe(u8, classname),
            .targetname = if (entity.targetname()) |value| try allocator.dupe(u8, value) else null,
            .model_path = try allocator.dupe(u8, model),
            .bsp_model_index = null,
            .origin = entity.origin() orelse .{ .x = 0.0, .y = 0.0, .z = 0.0 },
            .angles = entityAngles(entity),
        });
    }

    return instances;
}

fn parseSubmodelIndex(model: []const u8) ?usize {
    if (model.len < 2 or model[0] != '*') return null;
    return std.fmt.parseUnsigned(usize, model[1..], 10) catch null;
}

fn entityAngles(entity: *const entities.Entity) qmath.Vec3 {
    if (entity.angles()) |angles| return angles;
    if (entity.get("angle")) |angle_text| {
        const yaw = std.fmt.parseFloat(f32, angle_text) catch return .{ .x = 0.0, .y = 0.0, .z = 0.0 };
        return .{ .x = 0.0, .y = yaw, .z = 0.0 };
    }
    return .{ .x = 0.0, .y = 0.0, .z = 0.0 };
}
