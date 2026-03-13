const std = @import("std");
const rl = @import("raylib");
const q3 = @import("quake3/mod.zig");

pub fn run(allocator: std.mem.Allocator) !void {
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    const source_path = if (args.len >= 2) args[1] else "assets/maps";
    const requested_bsp = if (args.len >= 3) args[2] else null;

    var packs = try q3.archive.Pk3Collection.initFromPath(allocator, source_path);
    defer packs.deinit();

    const map_ref = if (requested_bsp) |name|
        packs.findMap(name) orelse return error.MapNotFound
    else
        packs.findFirstMap() orelse return error.NoMapsFound;

    const map_bytes = try packs.readFileAlloc(allocator, map_ref.path);
    defer allocator.free(map_bytes);

    var map = try q3.bsp.Map.init(allocator, map_ref.path, map_bytes);
    defer map.deinit();

    rl.setConfigFlags(.{ .window_resizable = true, .msaa_4x_hint = true });
    rl.initWindow(1600, 900, "quake3 pk3 viewer");
    defer rl.closeWindow();

    var renderer = try q3.renderer.SceneRenderer.init(allocator, &packs, &map);
    defer renderer.deinit();

    var camera = defaultCamera(map.bounds_center);
    var controller = CameraController.init(camera);
    rl.setTargetFPS(144);

    while (!rl.windowShouldClose()) {
        controller.update(&camera);

        rl.beginDrawing();
        defer rl.endDrawing();

        rl.clearBackground(.{ .r = 10, .g = 8, .b = 6, .a = 255 });
        rl.beginMode3D(camera);
        renderer.draw();
        rl.endMode3D();

        drawOverlay(map, renderer.stats, source_path);
    }
}

fn defaultCamera(center: rl.Vector3) rl.Camera {
    return .{
        .position = .{
            .x = center.x + 128.0,
            .y = center.y + 96.0,
            .z = center.z + 128.0,
        },
        .target = center,
        .up = .{ .x = 0.0, .y = 1.0, .z = 0.0 },
        .fovy = 65.0,
        .projection = .perspective,
    };
}

const CameraController = struct {
    move_speed: f32 = 900.0,
    boost_multiplier: f32 = 3.5,
    slow_multiplier: f32 = 0.35,
    mouse_sensitivity: f32 = 0.0022,
    yaw: f32,
    pitch: f32,
    cursor_locked: bool = false,

    fn init(camera: rl.Camera) CameraController {
        const forward = normalize(subtract(camera.target, camera.position));
        return .{
            .yaw = std.math.atan2(forward.z, forward.x),
            .pitch = std.math.asin(forward.y),
        };
    }

    fn update(self: *CameraController, camera: *rl.Camera) void {
        const wants_look = rl.isMouseButtonDown(.right);
        if (wants_look and !self.cursor_locked) {
            rl.disableCursor();
            self.cursor_locked = true;
        } else if (!wants_look and self.cursor_locked) {
            rl.enableCursor();
            self.cursor_locked = false;
        }

        if (self.cursor_locked) {
            const mouse_delta = rl.getMouseDelta();
            self.yaw += mouse_delta.x * self.mouse_sensitivity;
            self.pitch -= mouse_delta.y * self.mouse_sensitivity;
            self.pitch = @max(-1.55, @min(1.55, self.pitch));
        }

        const dt = rl.getFrameTime();
        var speed = self.move_speed;
        if (rl.isKeyDown(.left_shift) or rl.isKeyDown(.right_shift)) speed *= self.boost_multiplier;
        if (rl.isKeyDown(.left_control) or rl.isKeyDown(.right_control)) speed *= self.slow_multiplier;
        speed *= dt;

        const forward = self.forwardVector();
        const world_up = rl.Vector3{ .x = 0.0, .y = 1.0, .z = 0.0 };
        const right = normalize(cross(forward, world_up));

        var movement = rl.Vector3{ .x = 0.0, .y = 0.0, .z = 0.0 };
        if (rl.isKeyDown(.w)) movement = add(movement, scale(forward, speed));
        if (rl.isKeyDown(.s)) movement = add(movement, scale(forward, -speed));
        if (rl.isKeyDown(.d)) movement = add(movement, scale(right, speed));
        if (rl.isKeyDown(.a)) movement = add(movement, scale(right, -speed));
        if (rl.isKeyDown(.e)) movement.y += speed;
        if (rl.isKeyDown(.q)) movement.y -= speed;

        camera.position = add(camera.position, movement);
        camera.target = add(camera.position, forward);

        const wheel = rl.getMouseWheelMove();
        if (wheel != 0.0) {
            camera.fovy = @max(25.0, @min(100.0, camera.fovy - wheel * 3.0));
        }
    }

    fn forwardVector(self: *const CameraController) rl.Vector3 {
        const cos_pitch = @cos(self.pitch);
        return normalize(.{
            .x = @cos(self.yaw) * cos_pitch,
            .y = @sin(self.pitch),
            .z = @sin(self.yaw) * cos_pitch,
        });
    }
};

fn add(a: rl.Vector3, b: rl.Vector3) rl.Vector3 {
    return .{ .x = a.x + b.x, .y = a.y + b.y, .z = a.z + b.z };
}

fn subtract(a: rl.Vector3, b: rl.Vector3) rl.Vector3 {
    return .{ .x = a.x - b.x, .y = a.y - b.y, .z = a.z - b.z };
}

fn scale(v: rl.Vector3, amount: f32) rl.Vector3 {
    return .{ .x = v.x * amount, .y = v.y * amount, .z = v.z * amount };
}

fn cross(a: rl.Vector3, b: rl.Vector3) rl.Vector3 {
    return .{
        .x = a.y * b.z - a.z * b.y,
        .y = a.z * b.x - a.x * b.z,
        .z = a.x * b.y - a.y * b.x,
    };
}

fn normalize(v: rl.Vector3) rl.Vector3 {
    const length_sq = v.x * v.x + v.y * v.y + v.z * v.z;
    if (length_sq <= 0.000001) return .{ .x = 0.0, .y = 0.0, .z = -1.0 };

    const inv_length = 1.0 / @sqrt(length_sq);
    return .{
        .x = v.x * inv_length,
        .y = v.y * inv_length,
        .z = v.z * inv_length,
    };
}

fn drawOverlay(map: q3.bsp.Map, stats: q3.renderer.SceneStats, source_path: []const u8) void {
    rl.drawRectangle(12, 12, 520, 126, rl.fade(.black, 0.72));
    rl.drawRectangleLines(12, 12, 520, 126, .dark_gray);
    rl.drawText("Modular Quake 3 PK3 viewer", 24, 24, 24, .ray_white);

    var line_buf: [256]u8 = undefined;

    const map_line = std.fmt.bufPrintZ(&line_buf, "Map: {s}", .{map.path}) catch return;
    rl.drawText(map_line, 24, 56, 18, .light_gray);

    const stats_line = std.fmt.bufPrintZ(
        &line_buf,
        "Batches: {d}  Faces: {d}  Draw verts: {d}  Missing textures: {d}",
        .{ stats.batch_count, stats.face_count, stats.vertex_count, stats.missing_texture_count },
    ) catch return;
    rl.drawText(stats_line, 24, 78, 18, .light_gray);

    const source_line = std.fmt.bufPrintZ(&line_buf, "PK3 source: {s}", .{source_path}) catch return;
    rl.drawText(source_line, 24, 100, 18, .light_gray);

    rl.drawText("Controls: RMB look, WASD fly, E/Q up-down, Shift boost, wheel FOV, F1 wire, F2 fullbright, F3 cull", 24, 122, 18, .gray);
}
