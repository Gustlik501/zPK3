const std = @import("std");
const bsp = @import("bsp.zig");
const qmath = @import("math.zig");

pub const contents = struct {
    pub const solid: i32 = 0x00000001;
    pub const lava: i32 = 0x00000008;
    pub const slime: i32 = 0x00000010;
    pub const water: i32 = 0x00000020;
    pub const fog: i32 = 0x00000040;
    pub const area_portal: i32 = 0x00008000;
    pub const player_clip: i32 = 0x00010000;
    pub const monster_clip: i32 = 0x00020000;
    pub const teleporter: i32 = 0x00040000;
    pub const jump_pad: i32 = 0x00080000;
    pub const cluster_portal: i32 = 0x00100000;
    pub const do_not_enter: i32 = 0x00200000;
    pub const bot_clip: i32 = 0x00400000;
    pub const body: i32 = 0x02000000;
    pub const corpse: i32 = 0x04000000;
    pub const detail: i32 = 0x08000000;
    pub const structural: i32 = 0x10000000;
    pub const translucent: i32 = 0x20000000;
    pub const trigger: i32 = 0x40000000;
    pub const no_drop: i32 = @bitCast(@as(u32, 0x80000000));
};

pub const movement_mask: i32 = contents.solid | contents.player_clip | contents.body;

pub const BrushSide = struct {
    plane_index: usize,
    texture_index: i32,
};

pub const Brush = struct {
    contents: i32,
    flags: i32,
    sides: []BrushSide,
};

pub const TraceResult = struct {
    hit: bool = false,
    start_solid: bool = false,
    all_solid: bool = false,
    fraction: f32 = 1.0,
    end_position: qmath.Vec3,
    normal: qmath.Vec3 = .{ .x = 0.0, .y = 0.0, .z = 0.0 },
    contents: i32 = 0,
    flags: i32 = 0,
    brush_index: ?usize = null,
};

pub const World = struct {
    allocator: std.mem.Allocator,
    brushes: []Brush,

    pub fn initFromMap(allocator: std.mem.Allocator, map: *const bsp.Map) !World {
        var brushes: std.ArrayList(Brush) = .empty;
        errdefer {
            for (brushes.items) |brush| allocator.free(brush.sides);
            brushes.deinit(allocator);
        }

        for (map.brushes) |raw_brush| {
            if (raw_brush.brushside_index < 0 or raw_brush.brushside_count <= 0) continue;

            const side_start: usize = @intCast(raw_brush.brushside_index);
            const side_count: usize = @intCast(raw_brush.brushside_count);
            if (side_start + side_count > map.brushsides.len) continue;

            const raw_sides = map.brushsides[side_start .. side_start + side_count];
            const sides = try allocator.alloc(BrushSide, raw_sides.len);
            errdefer allocator.free(sides);

            var written: usize = 0;
            for (raw_sides) |raw_side| {
                if (raw_side.plane < 0) continue;
                const plane_index: usize = @intCast(raw_side.plane);
                if (plane_index >= map.planes.len) continue;

                sides[written] = .{
                    .plane_index = plane_index,
                    .texture_index = raw_side.texture,
                };
                written += 1;
            }

            if (written == 0) {
                allocator.free(sides);
                continue;
            }

            const compact_sides = try allocator.realloc(sides, written);
            const texture_index: usize = if (raw_brush.texture >= 0) @intCast(raw_brush.texture) else map.textures.len;
            const texture = if (texture_index < map.textures.len) map.textures[texture_index] else bsp.MapTexture{
                .name = "",
                .flags = 0,
                .contents = 0,
            };

            try brushes.append(allocator, .{
                .contents = texture.contents,
                .flags = texture.flags,
                .sides = compact_sides,
            });
        }

        return .{
            .allocator = allocator,
            .brushes = try brushes.toOwnedSlice(allocator),
        };
    }

    pub fn deinit(self: *World) void {
        for (self.brushes) |brush| self.allocator.free(brush.sides);
        self.allocator.free(self.brushes);
        self.* = undefined;
    }

    pub fn pointContents(self: *const World, map: *const bsp.Map, point: qmath.Vec3) i32 {
        const map_point = bsp.toMapSpace(point);
        return self.pointContentsMapPoint(map, map_point, -1);
    }

    pub fn pointContentsMasked(self: *const World, map: *const bsp.Map, point: qmath.Vec3, mask: i32) i32 {
        const map_point = bsp.toMapSpace(point);
        return self.pointContentsMapPoint(map, map_point, mask);
    }

    pub fn traceSegment(self: *const World, map: *const bsp.Map, start: qmath.Vec3, end: qmath.Vec3) TraceResult {
        return self.traceSegmentMasked(map, start, end, movement_mask);
    }

    pub fn traceSegmentMasked(
        self: *const World,
        map: *const bsp.Map,
        start: qmath.Vec3,
        end: qmath.Vec3,
        mask: i32,
    ) TraceResult {
        return self.traceBoxMasked(map, start, end, .{ .x = 0.0, .y = 0.0, .z = 0.0 }, .{ .x = 0.0, .y = 0.0, .z = 0.0 }, mask);
    }

    pub fn traceBox(
        self: *const World,
        map: *const bsp.Map,
        start: qmath.Vec3,
        end: qmath.Vec3,
        mins: qmath.Vec3,
        maxs: qmath.Vec3,
    ) TraceResult {
        return self.traceBoxMasked(map, start, end, mins, maxs, movement_mask);
    }

    pub fn traceBoxMasked(
        self: *const World,
        map: *const bsp.Map,
        start: qmath.Vec3,
        end: qmath.Vec3,
        mins: qmath.Vec3,
        maxs: qmath.Vec3,
        mask: i32,
    ) TraceResult {
        const start_map = bsp.toMapSpace(start);
        const end_map = bsp.toMapSpace(end);
        const extents = toMapExtents(mins, maxs);

        var result = TraceResult{
            .end_position = end,
        };

        for (self.brushes, 0..) |brush, brush_index| {
            if ((brush.contents & mask) == 0) continue;
            if (traceBrush(map, brush, start_map, end_map, extents)) |trace| {
                if (trace.start_solid) {
                    result.hit = true;
                    result.start_solid = true;
                    result.contents |= brush.contents;
                    result.flags |= brush.flags;
                    if (trace.all_solid) {
                        result.all_solid = true;
                        result.fraction = 0.0;
                        result.end_position = start;
                        result.brush_index = brush_index;
                    }
                }

                if (trace.fraction < result.fraction) {
                    result.hit = true;
                    result.fraction = trace.fraction;
                    result.normal = bsp.toEngineNormal(trace.plane_normal);
                    result.contents = brush.contents;
                    result.flags = brush.flags;
                    result.brush_index = brush_index;
                }
            }
        }

        if (!result.all_solid) {
            result.end_position = lerp(start, end, result.fraction);
        }

        return result;
    }

    fn pointContentsMapPoint(self: *const World, map: *const bsp.Map, point: [3]f32, mask: i32) i32 {
        var combined_contents: i32 = 0;

        for (self.brushes) |brush| {
            if (mask != -1 and (brush.contents & mask) == 0) continue;
            if (pointInsideBrush(map, brush, point)) {
                combined_contents |= brush.contents;
            }
        }

        return combined_contents;
    }
};

const BrushTrace = struct {
    fraction: f32,
    plane_normal: [3]f32,
    start_solid: bool,
    all_solid: bool,
};

fn traceBrush(
    map: *const bsp.Map,
    brush: Brush,
    start: [3]f32,
    end: [3]f32,
    extents: [3]f32,
) ?BrushTrace {
    var enter_fraction: f32 = -std.math.inf(f32);
    var leave_fraction: f32 = 1.0;
    var plane_normal = [3]f32{ 0.0, 0.0, 0.0 };
    var start_outside = false;
    var end_outside = false;

    for (brush.sides) |side| {
        const plane = map.planes[side.plane_index];
        const offset =
            @abs(plane.normal[0]) * extents[0] +
            @abs(plane.normal[1]) * extents[1] +
            @abs(plane.normal[2]) * extents[2];
        const distance = plane.distance + offset;
        const start_distance = dot3(plane.normal, start) - distance;
        const end_distance = dot3(plane.normal, end) - distance;

        if (start_distance > 0.0) start_outside = true;
        if (end_distance > 0.0) end_outside = true;

        if (start_distance > 0.0 and end_distance > 0.0) {
            return null;
        }
        if (start_distance <= 0.0 and end_distance <= 0.0) continue;

        if (start_distance > end_distance) {
            const fraction = clampFraction((start_distance - 0.001) / (start_distance - end_distance));
            if (fraction > enter_fraction) {
                enter_fraction = fraction;
                plane_normal = plane.normal;
            }
        } else {
            const fraction = clampFraction((start_distance + 0.001) / (start_distance - end_distance));
            if (fraction < leave_fraction) {
                leave_fraction = fraction;
            }
        }

        if (leave_fraction <= enter_fraction) {
            return null;
        }
    }

    if (!start_outside) {
        return .{
            .fraction = 0.0,
            .plane_normal = plane_normal,
            .start_solid = true,
            .all_solid = !end_outside,
        };
    }

    if (enter_fraction < 0.0 or enter_fraction >= 1.0) return null;

    return .{
        .fraction = enter_fraction,
        .plane_normal = plane_normal,
        .start_solid = false,
        .all_solid = false,
    };
}

fn pointInsideBrush(map: *const bsp.Map, brush: Brush, point: [3]f32) bool {
    for (brush.sides) |side| {
        const plane = map.planes[side.plane_index];
        const distance =
            plane.normal[0] * point[0] +
            plane.normal[1] * point[1] +
            plane.normal[2] * point[2] -
            plane.distance;
        if (distance > 0.001) return false;
    }
    return true;
}

fn dot3(a: [3]f32, b: [3]f32) f32 {
    return a[0] * b[0] + a[1] * b[1] + a[2] * b[2];
}

fn toMapExtents(mins: qmath.Vec3, maxs: qmath.Vec3) [3]f32 {
    return .{
        @max(@abs(mins.x), @abs(maxs.x)),
        @max(@abs(mins.z), @abs(maxs.z)),
        @max(@abs(mins.y), @abs(maxs.y)),
    };
}

fn lerp(a: qmath.Vec3, b: qmath.Vec3, t: f32) qmath.Vec3 {
    return .{
        .x = a.x + (b.x - a.x) * t,
        .y = a.y + (b.y - a.y) * t,
        .z = a.z + (b.z - a.z) * t,
    };
}

fn clampFraction(value: f32) f32 {
    return @max(0.0, @min(1.0, value));
}

test "pointContents and segment trace hit a simple cube brush" {
    var map = try makeTestCubeMap(std.testing.allocator);
    defer map.deinit();

    var world = try World.initFromMap(std.testing.allocator, &map);
    defer world.deinit();

    try std.testing.expectEqual(@as(i32, 1), world.pointContents(&map, .{ .x = 0.0, .y = 0.0, .z = 0.0 }));
    try std.testing.expectEqual(@as(i32, 0), world.pointContents(&map, .{ .x = 96.0, .y = 0.0, .z = 0.0 }));

    const trace = world.traceSegment(
        &map,
        .{ .x = -100.0, .y = 0.0, .z = 0.0 },
        .{ .x = 100.0, .y = 0.0, .z = 0.0 },
    );

    try std.testing.expect(trace.hit);
    try std.testing.expect(!trace.start_solid);
    try std.testing.expectEqual(@as(?usize, 0), trace.brush_index);
    try std.testing.expectApproxEqAbs(-32.0, trace.end_position.x, 0.01);
    try std.testing.expectApproxEqAbs(0.34, trace.fraction, 0.01);
    try std.testing.expectApproxEqAbs(-1.0, trace.normal.x, 0.01);
}

test "movement mask ignores trigger-only brushes" {
    var map = try makeTestCubeMap(std.testing.allocator);
    defer map.deinit();

    try addCubeBrush(std.testing.allocator, &map, contents.trigger, "textures/test/trigger");

    var world = try World.initFromMap(std.testing.allocator, &map);
    defer world.deinit();

    const trace = world.traceSegment(
        &map,
        .{ .x = 40.0, .y = 0.0, .z = 0.0 },
        .{ .x = 60.0, .y = 0.0, .z = 0.0 },
    );
    try std.testing.expect(!trace.hit);

    const trigger_contents = world.pointContentsMasked(&map, .{ .x = 50.0, .y = 0.0, .z = 0.0 }, contents.trigger);
    try std.testing.expectEqual(contents.trigger, trigger_contents);
}

fn makeTestCubeMap(allocator: std.mem.Allocator) !bsp.Map {
    const textures = try allocator.alloc(bsp.MapTexture, 1);
    errdefer allocator.free(textures);
    textures[0] = .{
        .name = try allocator.dupe(u8, "textures/test/solid"),
        .flags = 0,
        .contents = contents.solid,
    };
    errdefer allocator.free(textures[0].name);

    const planes = try allocator.alloc(bsp.Plane, 6);
    errdefer allocator.free(planes);
    planes[0] = .{ .normal = .{ 1.0, 0.0, 0.0 }, .distance = 32.0 };
    planes[1] = .{ .normal = .{ -1.0, 0.0, 0.0 }, .distance = 32.0 };
    planes[2] = .{ .normal = .{ 0.0, 1.0, 0.0 }, .distance = 32.0 };
    planes[3] = .{ .normal = .{ 0.0, -1.0, 0.0 }, .distance = 32.0 };
    planes[4] = .{ .normal = .{ 0.0, 0.0, 1.0 }, .distance = 32.0 };
    planes[5] = .{ .normal = .{ 0.0, 0.0, -1.0 }, .distance = 32.0 };

    const brushes = try allocator.alloc(bsp.Brush, 1);
    errdefer allocator.free(brushes);
    brushes[0] = .{
        .brushside_index = 0,
        .brushside_count = 6,
        .texture = 0,
    };

    const brushsides = try allocator.alloc(bsp.BrushSide, 6);
    errdefer allocator.free(brushsides);
    for (brushsides, 0..) |*brushside, index| {
        brushside.* = .{
            .plane = @intCast(index),
            .texture = 0,
        };
    }

    return .{
        .allocator = allocator,
        .path = try allocator.dupe(u8, "test_cube.bsp"),
        .entities_source = try allocator.dupe(u8, ""),
        .textures = textures,
        .planes = planes,
        .nodes = try allocator.alloc(bsp.Node, 0),
        .leaves = try allocator.alloc(bsp.Leaf, 0),
        .leafsurfaces = try allocator.alloc(i32, 0),
        .leafbrushes = try allocator.alloc(i32, 0),
        .models = try allocator.alloc(bsp.Model, 0),
        .brushes = brushes,
        .brushsides = brushsides,
        .vertices = try allocator.alloc(bsp.Vertex, 0),
        .meshverts = try allocator.alloc(i32, 0),
        .effects = try allocator.alloc(bsp.Effect, 0),
        .faces = try allocator.alloc(bsp.Face, 0),
        .lightmap_bytes = try allocator.alloc(u8, 0),
        .lightvols = try allocator.alloc(bsp.LightVolume, 0),
        .visdata = null,
        .lightmap_count = 0,
        .bounds_min = .{ .x = -32.0, .y = -32.0, .z = -32.0 },
        .bounds_max = .{ .x = 32.0, .y = 32.0, .z = 32.0 },
        .bounds_center = .{ .x = 0.0, .y = 0.0, .z = 0.0 },
    };
}

fn addCubeBrush(allocator: std.mem.Allocator, map: *bsp.Map, brush_contents: i32, texture_name: []const u8) !void {
    const texture_index = map.textures.len;
    map.textures = try allocator.realloc(map.textures, texture_index + 1);
    map.textures[texture_index] = .{
        .name = try allocator.dupe(u8, texture_name),
        .flags = 0,
        .contents = brush_contents,
    };

    const plane_start = map.planes.len;
    map.planes = try allocator.realloc(map.planes, plane_start + 6);
    map.planes[plane_start + 0] = .{ .normal = .{ 1.0, 0.0, 0.0 }, .distance = 60.0 };
    map.planes[plane_start + 1] = .{ .normal = .{ -1.0, 0.0, 0.0 }, .distance = -40.0 };
    map.planes[plane_start + 2] = .{ .normal = .{ 0.0, 1.0, 0.0 }, .distance = 32.0 };
    map.planes[plane_start + 3] = .{ .normal = .{ 0.0, -1.0, 0.0 }, .distance = 32.0 };
    map.planes[plane_start + 4] = .{ .normal = .{ 0.0, 0.0, 1.0 }, .distance = 32.0 };
    map.planes[plane_start + 5] = .{ .normal = .{ 0.0, 0.0, -1.0 }, .distance = 32.0 };

    const side_start = map.brushsides.len;
    map.brushsides = try allocator.realloc(map.brushsides, side_start + 6);
    for (map.brushsides[side_start .. side_start + 6], 0..) |*brushside, index| {
        brushside.* = .{
            .plane = @intCast(plane_start + index),
            .texture = @intCast(texture_index),
        };
    }

    const brush_index = map.brushes.len;
    map.brushes = try allocator.realloc(map.brushes, brush_index + 1);
    map.brushes[brush_index] = .{
        .brushside_index = @intCast(side_start),
        .brushside_count = 6,
        .texture = @intCast(texture_index),
    };
}
