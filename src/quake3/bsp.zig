const std = @import("std");
const entities = @import("entities.zig");
const qmath = @import("math.zig");

// Match vanilla Quake 3's common hardware-gamma defaults:
// r_mapOverBrightBits = 2, tr.overbrightBits = 1.
pub const q3_map_overbright_bits: u5 = 2;
pub const q3_overbright_bits: u5 = 1;

pub const MapTexture = struct {
    name: []const u8,
    flags: i32,
    contents: i32,
};

pub const Vertex = struct {
    position: [3]f32,
    texcoord: [2]f32,
    lightmap_uv: [2]f32,
    normal: [3]f32,
    color: [4]u8,
};

pub fn colorShiftLightingBytes(
    input: [4]u8,
    map_overbright_bits: u5,
    overbright_bits: u5,
) [4]u8 {
    const shift: u5 = map_overbright_bits -| overbright_bits;
    var r: u32 = @as(u32, input[0]) << shift;
    var g: u32 = @as(u32, input[1]) << shift;
    var b: u32 = @as(u32, input[2]) << shift;

    if ((r | g | b) > 255) {
        var max_value = if (r > g) r else g;
        if (b > max_value) max_value = b;
        if (max_value > 0) {
            r = r * 255 / max_value;
            g = g * 255 / max_value;
            b = b * 255 / max_value;
        }
    }

    return .{
        @intCast(@min(r, 255)),
        @intCast(@min(g, 255)),
        @intCast(@min(b, 255)),
        input[3],
    };
}

pub const Face = struct {
    texture: i32,
    effect: i32,
    face_type: i32,
    vertex_index: i32,
    vertex_count: i32,
    meshvert_index: i32,
    meshvert_count: i32,
    lightmap_index: i32,
    lightmap_start: [2]i32,
    lightmap_size: [2]i32,
    lightmap_origin: [3]f32,
    lightmap_vecs: [2][3]f32,
    normal: [3]f32,
    patch_size: [2]i32,
};

pub const Plane = extern struct {
    normal: [3]f32 align(1),
    distance: f32 align(1),
};

pub const Node = extern struct {
    plane: i32 align(1),
    children: [2]i32 align(1),
    mins: [3]i32 align(1),
    maxs: [3]i32 align(1),
};

pub const Leaf = extern struct {
    cluster: i32 align(1),
    area: i32 align(1),
    mins: [3]i32 align(1),
    maxs: [3]i32 align(1),
    leafsurface_index: i32 align(1),
    leafsurface_count: i32 align(1),
    leafbrush_index: i32 align(1),
    leafbrush_count: i32 align(1),
};

pub const Model = extern struct {
    mins: [3]f32 align(1),
    maxs: [3]f32 align(1),
    face_index: i32 align(1),
    face_count: i32 align(1),
    brush_index: i32 align(1),
    brush_count: i32 align(1),
};

pub const Brush = extern struct {
    brushside_index: i32 align(1),
    brushside_count: i32 align(1),
    texture: i32 align(1),
};

pub const BrushSide = extern struct {
    plane: i32 align(1),
    texture: i32 align(1),
};

pub const Effect = struct {
    name: []const u8,
    brush: i32,
    unknown: i32,
};

pub const LightVolume = extern struct {
    ambient: [3]u8 align(1),
    directional: [3]u8 align(1),
    direction: [2]u8 align(1),
};

pub const VisData = struct {
    vector_count: usize,
    bytes_per_vector: usize,
    bytes: []u8,

    pub fn deinit(self: *VisData, allocator: std.mem.Allocator) void {
        allocator.free(self.bytes);
        self.* = undefined;
    }

    pub fn clusterBytes(self: *const VisData, cluster_index: usize) ?[]const u8 {
        if (cluster_index >= self.vector_count) return null;
        const start = cluster_index * self.bytes_per_vector;
        return self.bytes[start .. start + self.bytes_per_vector];
    }
};

pub const ValidationReport = struct {
    invalid_node_plane_refs: usize = 0,
    invalid_node_child_refs: usize = 0,
    invalid_leafsurface_ranges: usize = 0,
    invalid_leafsurface_refs: usize = 0,
    invalid_leafbrush_ranges: usize = 0,
    invalid_leafbrush_refs: usize = 0,
    invalid_model_face_ranges: usize = 0,
    invalid_model_brush_ranges: usize = 0,
    invalid_brushside_ranges: usize = 0,
    invalid_brushside_plane_refs: usize = 0,
    invalid_brush_texture_refs: usize = 0,
    invalid_face_texture_refs: usize = 0,
    invalid_face_effect_refs: usize = 0,
    invalid_face_vertex_ranges: usize = 0,
    invalid_face_meshvert_ranges: usize = 0,
    invalid_effect_brush_refs: usize = 0,

    pub fn issueCount(self: ValidationReport) usize {
        return self.invalid_node_plane_refs +
            self.invalid_node_child_refs +
            self.invalid_leafsurface_ranges +
            self.invalid_leafsurface_refs +
            self.invalid_leafbrush_ranges +
            self.invalid_leafbrush_refs +
            self.invalid_model_face_ranges +
            self.invalid_model_brush_ranges +
            self.invalid_brushside_ranges +
            self.invalid_brushside_plane_refs +
            self.invalid_brush_texture_refs +
            self.invalid_face_texture_refs +
            self.invalid_face_effect_refs +
            self.invalid_face_vertex_ranges +
            self.invalid_face_meshvert_ranges +
            self.invalid_effect_brush_refs;
    }

    pub fn isValid(self: ValidationReport) bool {
        return self.issueCount() == 0;
    }
};

pub const Map = struct {
    allocator: std.mem.Allocator,
    path: []const u8,
    entities_source: []u8,
    textures: []MapTexture,
    planes: []Plane,
    nodes: []Node,
    leaves: []Leaf,
    leafsurfaces: []i32,
    leafbrushes: []i32,
    models: []Model,
    brushes: []Brush,
    brushsides: []BrushSide,
    vertices: []Vertex,
    meshverts: []i32,
    effects: []Effect,
    faces: []Face,
    lightmap_bytes: []u8,
    lightvols: []LightVolume,
    visdata: ?VisData,
    lightmap_count: usize,
    bounds_min: qmath.Vec3,
    bounds_max: qmath.Vec3,
    bounds_center: qmath.Vec3,

    pub fn init(allocator: std.mem.Allocator, path: []const u8, data: []const u8) !Map {
        var reader = std.Io.Reader.fixed(data);
        const header = try reader.takeStruct(Header, .little);

        if (!std.mem.eql(u8, &header.magic, "IBSP")) return error.InvalidMagic;
        if (header.version != 46) return error.UnsupportedVersion;

        const entities_source = try parseOwnedBytes(allocator, data, header.lumps[@intFromEnum(LumpIndex.entities)], 0);
        errdefer allocator.free(entities_source);

        const textures = try parseTextures(allocator, data, header.lumps[@intFromEnum(LumpIndex.textures)]);
        errdefer freeTextures(allocator, textures);

        const planes = try parseStructSlice(Plane, allocator, data, header.lumps[@intFromEnum(LumpIndex.planes)]);
        errdefer allocator.free(planes);

        const nodes = try parseStructSlice(Node, allocator, data, header.lumps[@intFromEnum(LumpIndex.nodes)]);
        errdefer allocator.free(nodes);

        const leaves = try parseStructSlice(Leaf, allocator, data, header.lumps[@intFromEnum(LumpIndex.leaves)]);
        errdefer allocator.free(leaves);

        const leafsurfaces = try parseI32Slice(allocator, data, header.lumps[@intFromEnum(LumpIndex.leafsurfaces)]);
        errdefer allocator.free(leafsurfaces);

        const leafbrushes = try parseI32Slice(allocator, data, header.lumps[@intFromEnum(LumpIndex.leafbrushes)]);
        errdefer allocator.free(leafbrushes);

        const models = try parseStructSlice(Model, allocator, data, header.lumps[@intFromEnum(LumpIndex.models)]);
        errdefer allocator.free(models);

        const brushes = try parseStructSlice(Brush, allocator, data, header.lumps[@intFromEnum(LumpIndex.brushes)]);
        errdefer allocator.free(brushes);

        const brushsides = try parseStructSlice(BrushSide, allocator, data, header.lumps[@intFromEnum(LumpIndex.brushsides)]);
        errdefer allocator.free(brushsides);

        const vertices = try parseVertices(allocator, data, header.lumps[@intFromEnum(LumpIndex.vertices)]);
        errdefer allocator.free(vertices);

        const meshverts = try parseI32Slice(allocator, data, header.lumps[@intFromEnum(LumpIndex.meshverts)]);
        errdefer allocator.free(meshverts);

        const effects = try parseEffects(allocator, data, header.lumps[@intFromEnum(LumpIndex.effects)]);
        errdefer freeEffects(allocator, effects);

        const faces = try parseFaces(allocator, data, header.lumps[@intFromEnum(LumpIndex.faces)]);
        errdefer allocator.free(faces);

        const lightmap_bytes = try parseOwnedBytes(allocator, data, header.lumps[@intFromEnum(LumpIndex.lightmaps)], lightmap_byte_len);
        errdefer allocator.free(lightmap_bytes);

        const lightvols = try parseStructSlice(LightVolume, allocator, data, header.lumps[@intFromEnum(LumpIndex.lightvols)]);
        errdefer allocator.free(lightvols);

        const visdata = try parseVisData(allocator, data, header.lumps[@intFromEnum(LumpIndex.visdata)]);
        errdefer if (visdata) |value| {
            var owned_value = value;
            owned_value.deinit(allocator);
        };

        const bounds = computeBounds(vertices);

        return .{
            .allocator = allocator,
            .path = try allocator.dupe(u8, path),
            .entities_source = entities_source,
            .textures = textures,
            .planes = planes,
            .nodes = nodes,
            .leaves = leaves,
            .leafsurfaces = leafsurfaces,
            .leafbrushes = leafbrushes,
            .models = models,
            .brushes = brushes,
            .brushsides = brushsides,
            .vertices = vertices,
            .meshverts = meshverts,
            .effects = effects,
            .faces = faces,
            .lightmap_bytes = lightmap_bytes,
            .lightvols = lightvols,
            .visdata = visdata,
            .lightmap_count = lightmap_bytes.len / lightmap_byte_len,
            .bounds_min = bounds.min,
            .bounds_max = bounds.max,
            .bounds_center = .{
                .x = (bounds.min.x + bounds.max.x) * 0.5,
                .y = (bounds.min.y + bounds.max.y) * 0.5,
                .z = (bounds.min.z + bounds.max.z) * 0.5,
            },
        };
    }

    pub fn deinit(self: *Map) void {
        self.allocator.free(self.entities_source);
        freeTextures(self.allocator, self.textures);
        self.allocator.free(self.planes);
        self.allocator.free(self.nodes);
        self.allocator.free(self.leaves);
        self.allocator.free(self.leafsurfaces);
        self.allocator.free(self.leafbrushes);
        self.allocator.free(self.models);
        self.allocator.free(self.brushes);
        self.allocator.free(self.brushsides);
        self.allocator.free(self.vertices);
        self.allocator.free(self.meshverts);
        freeEffects(self.allocator, self.effects);
        self.allocator.free(self.faces);
        self.allocator.free(self.lightmap_bytes);
        self.allocator.free(self.lightvols);
        if (self.visdata) |*value| value.deinit(self.allocator);
        self.allocator.free(self.path);
        self.* = undefined;
    }

    pub fn lightmapPixels(self: *const Map, index: usize) []const u8 {
        const start = index * lightmap_byte_len;
        return self.lightmap_bytes[start .. start + lightmap_byte_len];
    }

    pub fn parseEntities(self: *const Map, allocator: std.mem.Allocator) !entities.EntityList {
        return entities.parse(allocator, self.entities_source);
    }

    pub fn findLeafIndex(self: *const Map, position: qmath.Vec3) ?usize {
        if (self.leaves.len == 0) return null;
        if (self.nodes.len == 0) return 0;

        const map_position = toMapSpace(position);
        var node_index: i32 = 0;

        while (node_index >= 0) {
            const index: usize = @intCast(node_index);
            if (index >= self.nodes.len) return null;

            const node = self.nodes[index];
            if (node.plane < 0) return null;
            const plane_index: usize = @intCast(node.plane);
            if (plane_index >= self.planes.len) return null;

            const plane = self.planes[plane_index];
            const distance = dot3(plane.normal, map_position) - plane.distance;
            node_index = if (distance >= 0.0) node.children[0] else node.children[1];
        }

        const leaf_index = -node_index - 1;
        if (leaf_index < 0) return null;
        const index: usize = @intCast(leaf_index);
        if (index >= self.leaves.len) return null;
        return index;
    }

    pub fn isClusterVisible(self: *const Map, from_cluster: i32, to_cluster: i32) bool {
        if (self.visdata == null) return true;
        if (from_cluster < 0 or to_cluster < 0) return true;

        const visdata = self.visdata.?;
        const from_index: usize = @intCast(from_cluster);
        const to_index: usize = @intCast(to_cluster);
        const cluster_bytes = visdata.clusterBytes(from_index) orelse return true;
        if (to_index / 8 >= cluster_bytes.len) return false;

        const byte = cluster_bytes[to_index / 8];
        const mask: u8 = @as(u8, 1) << @intCast(to_index & 7);
        return (byte & mask) != 0;
    }

    pub fn estimatedMemoryBytes(self: *const Map) usize {
        var total: usize = @sizeOf(Map);
        total += self.path.len;
        total += self.entities_source.len;
        total += self.textures.len * @sizeOf(MapTexture);
        for (self.textures) |texture| total += texture.name.len;
        total += sliceMemoryBytes(Plane, self.planes);
        total += sliceMemoryBytes(Node, self.nodes);
        total += sliceMemoryBytes(Leaf, self.leaves);
        total += sliceMemoryBytes(i32, self.leafsurfaces);
        total += sliceMemoryBytes(i32, self.leafbrushes);
        total += sliceMemoryBytes(Model, self.models);
        total += sliceMemoryBytes(Brush, self.brushes);
        total += sliceMemoryBytes(BrushSide, self.brushsides);
        total += sliceMemoryBytes(Vertex, self.vertices);
        total += sliceMemoryBytes(i32, self.meshverts);
        total += self.effects.len * @sizeOf(Effect);
        for (self.effects) |effect| total += effect.name.len;
        total += sliceMemoryBytes(Face, self.faces);
        total += self.lightmap_bytes.len;
        total += sliceMemoryBytes(LightVolume, self.lightvols);
        if (self.visdata) |visdata| {
            total += @sizeOf(VisData);
            total += visdata.bytes.len;
        }
        return total;
    }

    pub fn validate(self: *const Map) ValidationReport {
        var report: ValidationReport = .{};

        for (self.nodes) |node| {
            if (node.plane < 0 or @as(usize, @intCast(node.plane)) >= self.planes.len) {
                report.invalid_node_plane_refs += 1;
            }

            for (node.children) |child| {
                if (child >= 0) {
                    if (@as(usize, @intCast(child)) >= self.nodes.len) {
                        report.invalid_node_child_refs += 1;
                    }
                } else {
                    const leaf_index = -child - 1;
                    if (leaf_index < 0 or @as(usize, @intCast(leaf_index)) >= self.leaves.len) {
                        report.invalid_node_child_refs += 1;
                    }
                }
            }
        }

        for (self.leaves) |leaf| {
            if (leaf.leafsurface_index < 0 or leaf.leafsurface_count < 0) {
                report.invalid_leafsurface_ranges += 1;
            } else {
                const start: usize = @intCast(leaf.leafsurface_index);
                const count: usize = @intCast(leaf.leafsurface_count);
                if (start + count > self.leafsurfaces.len) {
                    report.invalid_leafsurface_ranges += 1;
                } else {
                    for (self.leafsurfaces[start .. start + count]) |face_index| {
                        if (face_index < 0 or @as(usize, @intCast(face_index)) >= self.faces.len) {
                            report.invalid_leafsurface_refs += 1;
                        }
                    }
                }
            }

            if (leaf.leafbrush_index < 0 or leaf.leafbrush_count < 0) {
                report.invalid_leafbrush_ranges += 1;
            } else {
                const start: usize = @intCast(leaf.leafbrush_index);
                const count: usize = @intCast(leaf.leafbrush_count);
                if (start + count > self.leafbrushes.len) {
                    report.invalid_leafbrush_ranges += 1;
                } else {
                    for (self.leafbrushes[start .. start + count]) |brush_index| {
                        if (brush_index < 0 or @as(usize, @intCast(brush_index)) >= self.brushes.len) {
                            report.invalid_leafbrush_refs += 1;
                        }
                    }
                }
            }
        }

        for (self.models) |model| {
            if (model.face_index < 0 or model.face_count < 0 or
                @as(usize, @intCast(model.face_index)) + @as(usize, @intCast(model.face_count)) > self.faces.len)
            {
                report.invalid_model_face_ranges += 1;
            }

            if (model.brush_index < 0 or model.brush_count < 0 or
                @as(usize, @intCast(model.brush_index)) + @as(usize, @intCast(model.brush_count)) > self.brushes.len)
            {
                report.invalid_model_brush_ranges += 1;
            }
        }

        for (self.brushes) |brush| {
            if (brush.brushside_index < 0 or brush.brushside_count < 0 or
                @as(usize, @intCast(brush.brushside_index)) + @as(usize, @intCast(brush.brushside_count)) > self.brushsides.len)
            {
                report.invalid_brushside_ranges += 1;
            }
            if (brush.texture < 0 or @as(usize, @intCast(brush.texture)) >= self.textures.len) {
                report.invalid_brush_texture_refs += 1;
            }
        }

        for (self.brushsides) |brushside| {
            if (brushside.plane < 0 or @as(usize, @intCast(brushside.plane)) >= self.planes.len) {
                report.invalid_brushside_plane_refs += 1;
            }
        }

        for (self.faces) |face| {
            if (face.texture < 0 or @as(usize, @intCast(face.texture)) >= self.textures.len) {
                report.invalid_face_texture_refs += 1;
            }

            if (face.effect >= 0 and @as(usize, @intCast(face.effect)) >= self.effects.len) {
                report.invalid_face_effect_refs += 1;
            }

            if (face.vertex_index < 0 or face.vertex_count < 0 or
                @as(usize, @intCast(face.vertex_index)) + @as(usize, @intCast(face.vertex_count)) > self.vertices.len)
            {
                report.invalid_face_vertex_ranges += 1;
            }

            if (face.meshvert_index < 0 or face.meshvert_count < 0 or
                @as(usize, @intCast(face.meshvert_index)) + @as(usize, @intCast(face.meshvert_count)) > self.meshverts.len)
            {
                report.invalid_face_meshvert_ranges += 1;
            }
        }

        for (self.effects) |effect| {
            if (effect.brush >= 0 and @as(usize, @intCast(effect.brush)) >= self.brushes.len) {
                report.invalid_effect_brush_refs += 1;
            }
        }

        return report;
    }
};

pub const lightmap_side = 128;
pub const lightmap_byte_len = lightmap_side * lightmap_side * 3;

const LumpIndex = enum(usize) {
    entities = 0,
    textures = 1,
    planes = 2,
    nodes = 3,
    leaves = 4,
    leafsurfaces = 5,
    leafbrushes = 6,
    models = 7,
    brushes = 8,
    brushsides = 9,
    vertices = 10,
    meshverts = 11,
    effects = 12,
    faces = 13,
    lightmaps = 14,
    lightvols = 15,
    visdata = 16,
};

const Lump = extern struct {
    offset: i32 align(1),
    length: i32 align(1),
};

const Header = extern struct {
    magic: [4]u8 align(1),
    version: i32 align(1),
    lumps: [17]Lump align(1),
};

const RawTexture = extern struct {
    name: [64]u8 align(1),
    flags: i32 align(1),
    contents: i32 align(1),
};

const RawVertex = extern struct {
    position: [3]f32 align(1),
    texcoord: [2]f32 align(1),
    lightmap_uv: [2]f32 align(1),
    normal: [3]f32 align(1),
    color: [4]u8 align(1),
};

const RawFace = extern struct {
    texture: i32 align(1),
    effect: i32 align(1),
    face_type: i32 align(1),
    vertex_index: i32 align(1),
    vertex_count: i32 align(1),
    meshvert_index: i32 align(1),
    meshvert_count: i32 align(1),
    lightmap_index: i32 align(1),
    lightmap_start: [2]i32 align(1),
    lightmap_size: [2]i32 align(1),
    lightmap_origin: [3]f32 align(1),
    lightmap_vecs: [2][3]f32 align(1),
    normal: [3]f32 align(1),
    patch_size: [2]i32 align(1),
};

const RawEffect = extern struct {
    name: [64]u8 align(1),
    brush: i32 align(1),
    unknown: i32 align(1),
};

fn parseTextures(allocator: std.mem.Allocator, data: []const u8, lump: Lump) ![]MapTexture {
    const bytes = try lumpBytes(data, lump, @sizeOf(RawTexture));
    const count = bytes.len / @sizeOf(RawTexture);

    var reader = std.Io.Reader.fixed(bytes);
    const textures = try allocator.alloc(MapTexture, count);
    errdefer allocator.free(textures);

    for (textures) |*texture| {
        const raw = try reader.takeStruct(RawTexture, .little);
        const owned_name = try allocator.dupe(u8, cStringSlice(&raw.name));
        normalizePathInPlace(owned_name);
        texture.* = .{
            .name = owned_name,
            .flags = raw.flags,
            .contents = raw.contents,
        };
    }

    return textures;
}

fn sliceMemoryBytes(comptime T: type, slice: []const T) usize {
    return slice.len * @sizeOf(T);
}

fn parseVertices(allocator: std.mem.Allocator, data: []const u8, lump: Lump) ![]Vertex {
    const bytes = try lumpBytes(data, lump, @sizeOf(RawVertex));
    const count = bytes.len / @sizeOf(RawVertex);

    var reader = std.Io.Reader.fixed(bytes);
    const vertices = try allocator.alloc(Vertex, count);

    for (vertices) |*vertex| {
        const raw = try reader.takeStruct(RawVertex, .little);
        vertex.* = .{
            .position = raw.position,
            .texcoord = raw.texcoord,
            .lightmap_uv = raw.lightmap_uv,
            .normal = raw.normal,
            .color = colorShiftLightingBytes(raw.color, q3_map_overbright_bits, q3_overbright_bits),
        };
    }

    return vertices;
}

fn parseStructSlice(comptime T: type, allocator: std.mem.Allocator, data: []const u8, lump: Lump) ![]T {
    const bytes = try lumpBytes(data, lump, @sizeOf(T));
    const count = bytes.len / @sizeOf(T);

    var reader = std.Io.Reader.fixed(bytes);
    const values = try allocator.alloc(T, count);
    for (values) |*value| {
        value.* = try reader.takeStruct(T, .little);
    }
    return values;
}

fn parseI32Slice(allocator: std.mem.Allocator, data: []const u8, lump: Lump) ![]i32 {
    const bytes = try lumpBytes(data, lump, @sizeOf(i32));
    const count = bytes.len / @sizeOf(i32);

    var reader = std.Io.Reader.fixed(bytes);
    const values = try allocator.alloc(i32, count);
    for (values) |*value| {
        value.* = try reader.takeInt(i32, .little);
    }
    return values;
}

fn parseFaces(allocator: std.mem.Allocator, data: []const u8, lump: Lump) ![]Face {
    const bytes = try lumpBytes(data, lump, @sizeOf(RawFace));
    const count = bytes.len / @sizeOf(RawFace);

    var reader = std.Io.Reader.fixed(bytes);
    const faces = try allocator.alloc(Face, count);

    for (faces) |*face| {
        const raw = try reader.takeStruct(RawFace, .little);
        face.* = .{
            .texture = raw.texture,
            .effect = raw.effect,
            .face_type = raw.face_type,
            .vertex_index = raw.vertex_index,
            .vertex_count = raw.vertex_count,
            .meshvert_index = raw.meshvert_index,
            .meshvert_count = raw.meshvert_count,
            .lightmap_index = raw.lightmap_index,
            .lightmap_start = raw.lightmap_start,
            .lightmap_size = raw.lightmap_size,
            .lightmap_origin = raw.lightmap_origin,
            .lightmap_vecs = raw.lightmap_vecs,
            .normal = raw.normal,
            .patch_size = raw.patch_size,
        };
    }

    return faces;
}

fn parseEffects(allocator: std.mem.Allocator, data: []const u8, lump: Lump) ![]Effect {
    const bytes = try lumpBytes(data, lump, @sizeOf(RawEffect));
    const count = bytes.len / @sizeOf(RawEffect);

    var reader = std.Io.Reader.fixed(bytes);
    const effects = try allocator.alloc(Effect, count);
    errdefer allocator.free(effects);

    for (effects) |*effect| {
        const raw = try reader.takeStruct(RawEffect, .little);
        const owned_name = try allocator.dupe(u8, cStringSlice(&raw.name));
        normalizePathInPlace(owned_name);
        effect.* = .{
            .name = owned_name,
            .brush = raw.brush,
            .unknown = raw.unknown,
        };
    }

    return effects;
}

fn parseVisData(allocator: std.mem.Allocator, data: []const u8, lump: Lump) !?VisData {
    const bytes = try lumpBytes(data, lump, 0);
    if (bytes.len == 0) return null;
    if (bytes.len < 8) return error.InvalidVisData;

    var reader = std.Io.Reader.fixed(bytes);
    const raw_vector_count = try reader.takeInt(i32, .little);
    const raw_bytes_per_vector = try reader.takeInt(i32, .little);
    if (raw_vector_count < 0 or raw_bytes_per_vector < 0) return error.InvalidVisData;

    const vector_count: usize = @intCast(raw_vector_count);
    const bytes_per_vector: usize = @intCast(raw_bytes_per_vector);
    const expected_bytes = try std.math.mul(usize, vector_count, bytes_per_vector);
    const payload = bytes[@sizeOf(i32) * 2 ..];
    if (payload.len != expected_bytes) return error.InvalidVisData;

    return .{
        .vector_count = vector_count,
        .bytes_per_vector = bytes_per_vector,
        .bytes = try allocator.dupe(u8, payload),
    };
}

fn parseOwnedBytes(allocator: std.mem.Allocator, data: []const u8, lump: Lump, stride: usize) ![]u8 {
    const bytes = try lumpBytes(data, lump, stride);
    return allocator.dupe(u8, bytes);
}

fn lumpBytes(data: []const u8, lump: Lump, stride: usize) ![]const u8 {
    if (lump.offset < 0 or lump.length < 0) return error.InvalidLump;
    const offset: usize = @intCast(lump.offset);
    const length: usize = @intCast(lump.length);
    if (offset + length > data.len) return error.InvalidLump;
    if (stride != 0 and length % stride != 0) return error.InvalidLumpStride;
    return data[offset .. offset + length];
}

fn cStringSlice(raw: []const u8) []const u8 {
    const end = std.mem.indexOfScalar(u8, raw, 0) orelse raw.len;
    return raw[0..end];
}

fn freeTextures(allocator: std.mem.Allocator, textures: []MapTexture) void {
    for (textures) |texture| allocator.free(texture.name);
    allocator.free(textures);
}

fn freeEffects(allocator: std.mem.Allocator, effects: []Effect) void {
    for (effects) |effect| allocator.free(effect.name);
    allocator.free(effects);
}

fn computeBounds(vertices: []const Vertex) struct { min: qmath.Vec3, max: qmath.Vec3 } {
    if (vertices.len == 0) {
        const zero = qmath.Vec3{ .x = 0, .y = 0, .z = 0 };
        return .{ .min = zero, .max = zero };
    }

    var min = toEngineSpace(vertices[0].position);
    var max = min;

    for (vertices[1..]) |vertex| {
        const p = toEngineSpace(vertex.position);
        min.x = @min(min.x, p.x);
        min.y = @min(min.y, p.y);
        min.z = @min(min.z, p.z);
        max.x = @max(max.x, p.x);
        max.y = @max(max.y, p.y);
        max.z = @max(max.z, p.z);
    }

    return .{ .min = min, .max = max };
}

pub fn toEngineSpace(position: [3]f32) qmath.Vec3 {
    return .{
        .x = position[0],
        .y = position[2],
        .z = -position[1],
    };
}

pub fn toEngineNormal(normal: [3]f32) qmath.Vec3 {
    return .{
        .x = normal[0],
        .y = normal[2],
        .z = -normal[1],
    };
}

pub fn toMapSpace(position: qmath.Vec3) [3]f32 {
    return .{
        position.x,
        -position.z,
        position.y,
    };
}

fn dot3(a: [3]f32, b: [3]f32) f32 {
    return a[0] * b[0] + a[1] * b[1] + a[2] * b[2];
}

fn normalizePathInPlace(path: []u8) void {
    for (path) |*byte| {
        if (byte.* == '\\') byte.* = '/';
        byte.* = std.ascii.toLower(byte.*);
    }
}
