const std = @import("std");
const bsp = @import("bsp.zig");
const qmath = @import("math.zig");

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
        var contents: i32 = 0;

        for (self.brushes) |brush| {
            if (pointInsideBrush(map, brush, map_point)) {
                contents |= brush.contents;
            }
        }

        return contents;
    }

    pub fn traceSegment(self: *const World, map: *const bsp.Map, start: qmath.Vec3, end: qmath.Vec3) TraceResult {
        return self.traceBox(map, start, end, .{ .x = 0.0, .y = 0.0, .z = 0.0 }, .{ .x = 0.0, .y = 0.0, .z = 0.0 });
    }

    pub fn traceBox(
        self: *const World,
        map: *const bsp.Map,
        start: qmath.Vec3,
        end: qmath.Vec3,
        mins: qmath.Vec3,
        maxs: qmath.Vec3,
    ) TraceResult {
        const start_map = bsp.toMapSpace(start);
        const end_map = bsp.toMapSpace(end);
        const extents = toMapExtents(mins, maxs);

        var result = TraceResult{
            .end_position = end,
        };

        for (self.brushes, 0..) |brush, brush_index| {
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
