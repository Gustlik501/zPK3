const std = @import("std");
const entities = @import("entities.zig");
const qmath = @import("math.zig");

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
            .color = raw.color,
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

fn normalizePathInPlace(path: []u8) void {
    for (path) |*byte| {
        if (byte.* == '\\') byte.* = '/';
        byte.* = std.ascii.toLower(byte.*);
    }
}
