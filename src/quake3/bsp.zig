const std = @import("std");
const rl = @import("raylib");

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

pub const Map = struct {
    allocator: std.mem.Allocator,
    path: []const u8,
    textures: []MapTexture,
    vertices: []Vertex,
    meshverts: []i32,
    faces: []Face,
    lightmap_bytes: []u8,
    lightmap_count: usize,
    bounds_min: rl.Vector3,
    bounds_max: rl.Vector3,
    bounds_center: rl.Vector3,

    pub fn init(allocator: std.mem.Allocator, path: []const u8, data: []const u8) !Map {
        var reader = std.Io.Reader.fixed(data);
        const header = try reader.takeStruct(Header, .little);

        if (!std.mem.eql(u8, &header.magic, "IBSP")) return error.InvalidMagic;
        if (header.version != 46) return error.UnsupportedVersion;

        const textures = try parseTextures(allocator, data, header.lumps[@intFromEnum(LumpIndex.textures)]);
        errdefer freeTextures(allocator, textures);

        const vertices = try parseVertices(allocator, data, header.lumps[@intFromEnum(LumpIndex.vertices)]);
        errdefer allocator.free(vertices);

        const meshverts = try parseI32Slice(allocator, data, header.lumps[@intFromEnum(LumpIndex.meshverts)]);
        errdefer allocator.free(meshverts);

        const faces = try parseFaces(allocator, data, header.lumps[@intFromEnum(LumpIndex.faces)]);
        errdefer allocator.free(faces);

        const lightmap_bytes = try parseOwnedBytes(allocator, data, header.lumps[@intFromEnum(LumpIndex.lightmaps)], lightmap_byte_len);
        errdefer allocator.free(lightmap_bytes);

        const bounds = computeBounds(vertices);

        return .{
            .allocator = allocator,
            .path = try allocator.dupe(u8, path),
            .textures = textures,
            .vertices = vertices,
            .meshverts = meshverts,
            .faces = faces,
            .lightmap_bytes = lightmap_bytes,
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
        freeTextures(self.allocator, self.textures);
        self.allocator.free(self.vertices);
        self.allocator.free(self.meshverts);
        self.allocator.free(self.faces);
        self.allocator.free(self.lightmap_bytes);
        self.allocator.free(self.path);
        self.* = undefined;
    }

    pub fn lightmapPixels(self: *const Map, index: usize) []const u8 {
        const start = index * lightmap_byte_len;
        return self.lightmap_bytes[start .. start + lightmap_byte_len];
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

fn computeBounds(vertices: []const Vertex) struct { min: rl.Vector3, max: rl.Vector3 } {
    if (vertices.len == 0) {
        const zero = rl.Vector3{ .x = 0, .y = 0, .z = 0 };
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

pub fn toEngineSpace(position: [3]f32) rl.Vector3 {
    return .{
        .x = position[0],
        .y = position[2],
        .z = -position[1],
    };
}

pub fn toEngineNormal(normal: [3]f32) rl.Vector3 {
    return .{
        .x = normal[0],
        .y = normal[2],
        .z = -normal[1],
    };
}

fn normalizePathInPlace(path: []u8) void {
    for (path) |*byte| {
        if (byte.* == '\\') byte.* = '/';
        byte.* = std.ascii.toLower(byte.*);
    }
}
