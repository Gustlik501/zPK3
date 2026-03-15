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
};

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
