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

    const validation = map.validate();
    var entity_list = try map.parseEntities(allocator);
    defer entity_list.deinit();

    rl.setConfigFlags(.{ .window_resizable = true, .msaa_4x_hint = true });
    rl.initWindow(1600, 900, "quake3 pk3 viewer");
    defer rl.closeWindow();

    var renderer = try q3.renderer.SceneRenderer.init(allocator, &packs, &map);
    defer renderer.deinit();

    var camera = defaultCamera(toRlVector3(map.bounds_center));
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

        drawOverlay(map, &renderer, source_path, entity_list.items.len, validation.issueCount());
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

fn toRlVector3(v: q3.math.Vec3) rl.Vector3 {
    return .{ .x = v.x, .y = v.y, .z = v.z };
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

fn drawOverlay(
    map: q3.bsp.Map,
    renderer: *const q3.renderer.SceneRenderer,
    source_path: []const u8,
    entity_count: usize,
    validation_issue_count: usize,
) void {
    const stats = renderer.stats;

    rl.drawRectangle(12, 12, 660, 252, rl.fade(.black, 0.72));
    rl.drawRectangleLines(12, 12, 660, 252, .dark_gray);
    rl.drawText("Modular Quake 3 PK3 viewer", 24, 24, 24, .ray_white);

    var line_buf: [384]u8 = undefined;

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

    const runtime_line = std.fmt.bufPrintZ(
        &line_buf,
        "Entities: {d}  Validation issues: {d}",
        .{ entity_count, validation_issue_count },
    ) catch return;
    rl.drawText(runtime_line, 24, 122, 18, if (validation_issue_count == 0) .light_gray else .orange);

    const scene_line = std.fmt.bufPrintZ(
        &line_buf,
        "Scene models: {d}  BSP submodels: {d}  World batches: {d}  Submodel batches: {d}",
        .{ stats.model_instance_count, stats.bsp_submodel_instance_count, stats.world_batch_count, stats.submodel_batch_count },
    ) catch return;
    rl.drawText(scene_line, 24, 144, 18, .light_gray);

    const object_line = if (renderer.selectedSceneObject()) |object|
        std.fmt.bufPrintZ(
            &line_buf,
            "Selected: {d}/{d} {s}  class={s}  model={s}  batches={d}",
            .{
                renderer.selected_scene_object_index.? + 1,
                renderer.scene_objects.len,
                switch (object.kind) {
                    .bsp_submodel => "bsp_submodel",
                    .external_model => "external_model",
                },
                object.classname,
                object.model_path orelse "-",
                renderer.selectedSceneObjectBatchCount(),
            },
        ) catch return
    else
        std.fmt.bufPrintZ(&line_buf, "Selected: none  Scene objects: {d}", .{renderer.scene_objects.len}) catch return;
    rl.drawText(object_line, 24, 166, 18, .light_gray);

    const object_detail_line = if (renderer.selectedSceneObject()) |object|
        if (object.bsp_model_index) |index|
            std.fmt.bufPrintZ(
                &line_buf,
                "Entity={d}  Target={s}  Origin=({d:.1}, {d:.1}, {d:.1})  BSP model={d}",
                .{
                    object.entity_index,
                    object.targetname orelse "-",
                    object.origin.x,
                    object.origin.y,
                    object.origin.z,
                    index,
                },
            ) catch return
        else
            std.fmt.bufPrintZ(
                &line_buf,
                "Entity={d}  Target={s}  Origin=({d:.1}, {d:.1}, {d:.1})",
                .{
                    object.entity_index,
                    object.targetname orelse "-",
                    object.origin.x,
                    object.origin.y,
                    object.origin.z,
                },
            ) catch return
    else
        std.fmt.bufPrintZ(
            &line_buf,
            "Render toggles: world={s} submodels={s} isolate={s} objects={s}",
            .{
                if (renderer.draw_world_geometry) "on" else "off",
                if (renderer.draw_submodel_geometry) "on" else "off",
                if (renderer.isolate_selected_submodel) "on" else "off",
                if (renderer.draw_scene_objects) "on" else "off",
            },
        ) catch return;
    rl.drawText(object_detail_line, 24, 188, 18, .light_gray);

    rl.drawText("Controls: RMB look, WASD fly, E/Q up-down, Shift boost, wheel FOV, Tab cycle objects", 24, 210, 18, .gray);
    rl.drawText("F1 wire, F2 fullbright, F3 cull, F4 objects, F5 world, F6 submodels, F7 isolate", 24, 232, 18, .gray);
}
