const std = @import("std");
const rl = @import("raylib");
const q3 = @import("quake3/mod.zig");
const imgui = @import("ui/imgui.zig");

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
    var collision_world = try q3.collision.World.initFromMap(allocator, &map);
    defer collision_world.deinit();

    rl.setConfigFlags(.{ .window_resizable = true, .msaa_4x_hint = true });
    rl.initWindow(1600, 900, "quake3 pk3 viewer");
    defer rl.closeWindow();

    imgui.setup(true);
    defer imgui.shutdown();

    var renderer = try q3.renderer.SceneRenderer.init(allocator, &packs, &map);
    defer renderer.deinit();

    var camera = defaultCamera(toRlVector3(map.bounds_center));
    var controller = CameraController.init(camera);
    var inspector: InspectorState = .{};
    rl.setTargetFPS(144);

    while (!rl.windowShouldClose()) {
        if (rl.isKeyPressed(.f8)) {
            inspector.visible = !inspector.visible;
        }

        controller.update(&camera, inspector.capture_mouse, inspector.capture_keyboard);
        updateCollisionDebugState(&inspector.collision, &collision_world, &map, &camera, &controller, &renderer);

        rl.beginDrawing();
        defer rl.endDrawing();

        rl.clearBackground(.{ .r = 10, .g = 8, .b = 6, .a = 255 });
        rl.beginMode3D(camera);
        renderer.draw();
        drawCollisionDebug(&inspector.collision);
        rl.endMode3D();

        imgui.begin();
        defer imgui.end();

        if (inspector.visible) {
            drawInspector(&collision_world, &renderer, &camera, &controller, &inspector);
        }

        inspector.capture_mouse = imgui.wantCaptureMouse();
        inspector.capture_keyboard = imgui.wantCaptureKeyboard();

        drawOverlay(map, &renderer, source_path, entity_list.items.len, validation.issueCount(), inspector.visible);
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
        return fromCamera(camera);
    }

    fn fromCamera(camera: rl.Camera) CameraController {
        const forward = normalize(subtract(camera.target, camera.position));
        return .{
            .yaw = std.math.atan2(forward.z, forward.x),
            .pitch = std.math.asin(forward.y),
        };
    }

    fn syncFromCamera(self: *CameraController, camera: rl.Camera) void {
        self.* = fromCamera(camera);
    }

    fn update(self: *CameraController, camera: *rl.Camera, capture_mouse: bool, capture_keyboard: bool) void {
        if (capture_mouse and self.cursor_locked) {
            rl.enableCursor();
            self.cursor_locked = false;
        }

        const wants_look = rl.isMouseButtonDown(.right);
        if (!capture_mouse and wants_look and !self.cursor_locked) {
            rl.disableCursor();
            self.cursor_locked = true;
        } else if ((capture_mouse or !wants_look) and self.cursor_locked) {
            rl.enableCursor();
            self.cursor_locked = false;
        }

        if (self.cursor_locked and !capture_mouse) {
            const mouse_delta = rl.getMouseDelta();
            self.yaw += mouse_delta.x * self.mouse_sensitivity;
            self.pitch -= mouse_delta.y * self.mouse_sensitivity;
            self.pitch = @max(-1.55, @min(1.55, self.pitch));
        }

        const dt = rl.getFrameTime();
        var speed = self.move_speed;
        if (!capture_keyboard and (rl.isKeyDown(.left_shift) or rl.isKeyDown(.right_shift))) speed *= self.boost_multiplier;
        if (!capture_keyboard and (rl.isKeyDown(.left_control) or rl.isKeyDown(.right_control))) speed *= self.slow_multiplier;
        speed *= dt;

        const forward = self.forwardVector();
        const world_up = rl.Vector3{ .x = 0.0, .y = 1.0, .z = 0.0 };
        const right = normalize(cross(forward, world_up));

        var movement = rl.Vector3{ .x = 0.0, .y = 0.0, .z = 0.0 };
        if (!capture_keyboard) {
            if (rl.isKeyDown(.w)) movement = add(movement, scale(forward, speed));
            if (rl.isKeyDown(.s)) movement = add(movement, scale(forward, -speed));
            if (rl.isKeyDown(.d)) movement = add(movement, scale(right, speed));
            if (rl.isKeyDown(.a)) movement = add(movement, scale(right, -speed));
            if (rl.isKeyDown(.e)) movement.y += speed;
            if (rl.isKeyDown(.q)) movement.y -= speed;
        }

        camera.position = add(camera.position, movement);
        camera.target = add(camera.position, forward);

        const wheel = rl.getMouseWheelMove();
        if (!capture_mouse and wheel != 0.0) {
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
    inspector_visible: bool,
) void {
    const stats = renderer.stats;

    rl.drawRectangle(12, 12, 660, 296, rl.fade(.black, 0.72));
    rl.drawRectangleLines(12, 12, 660, 296, .dark_gray);
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

    const ui_line = std.fmt.bufPrintZ(&line_buf, "UI: inspector={s}", .{if (inspector_visible) "on" else "off"}) catch return;
    rl.drawText(ui_line, 24, 210, 18, .gray);

    const debug_line = std.fmt.bufPrintZ(
        &line_buf,
        "Debug: wire={s} fullbright={s} cull={s} objects={s}",
        .{
            if (renderer.draw_wireframe) "on" else "off",
            if (renderer.fullbright) "on" else "off",
            if (renderer.backface_culling) "on" else "off",
            if (renderer.draw_scene_objects) "on" else "off",
        },
    ) catch return;
    rl.drawText(debug_line, 24, 232, 18, if (renderer.draw_wireframe) .orange else .gray);

    rl.drawText("Controls: RMB look, WASD fly, E/Q up-down, Shift boost, wheel FOV, Tab cycle objects", 24, 254, 18, .gray);
    rl.drawText("F1 wire, F2 fullbright, F3 cull, F4 objects, F5 world, F6 submodels, F7 isolate, F8 inspector", 24, 276, 18, .gray);
}

const InspectorState = struct {
    visible: bool = true,
    capture_mouse: bool = false,
    capture_keyboard: bool = false,
    collision: CollisionDebugState = .{},
};

fn drawInspector(
    collision_world: *const q3.collision.World,
    renderer: *q3.renderer.SceneRenderer,
    camera: *rl.Camera,
    controller: *CameraController,
    inspector: *InspectorState,
) void {
    imgui.setNextWindowSize(430.0, 620.0);
    const open = imgui.beginWindow("Scene Inspector", &inspector.visible);
    defer imgui.endWindow();
    if (!open) return;

    _ = imgui.checkbox("Draw scene object markers", &renderer.draw_scene_objects);
    _ = imgui.checkbox("Draw world geometry", &renderer.draw_world_geometry);
    _ = imgui.checkbox("Draw submodel geometry", &renderer.draw_submodel_geometry);
    _ = imgui.checkbox("Isolate selected BSP submodel", &renderer.isolate_selected_submodel);
    _ = imgui.checkbox("Wireframe renderer", &renderer.draw_wireframe);
    _ = imgui.checkbox("Fullbright renderer", &renderer.fullbright);
    _ = imgui.checkbox("Backface culling", &renderer.backface_culling);

    if (imgui.button("Previous")) renderer.selectPreviousSceneObject();
    imgui.sameLine();
    if (imgui.button("Next")) renderer.selectNextSceneObject();
    imgui.sameLine();
    if (imgui.button("Clear selection")) renderer.setSelectedSceneObject(null);

    if (imgui.button("Focus selection")) {
        focusCameraOnSelection(renderer, camera, controller);
    }

    imgui.separator();
    imgui.beginChild("scene_objects", 0.0, 280.0, true);
    var label_buf: [256]u8 = undefined;
    for (renderer.scene_objects, 0..) |object, index| {
        const kind_name = switch (object.kind) {
            .bsp_submodel => "bsp",
            .external_model => "model",
        };
        const label = std.fmt.bufPrintZ(
            &label_buf,
            "#{d} [{s}] {s} {s}",
            .{ index + 1, kind_name, object.classname, object.targetname orelse "" },
        ) catch continue;
        if (imgui.selectable(label, renderer.selected_scene_object_index == index)) {
            renderer.setSelectedSceneObject(index);
        }
    }
    imgui.endChild();

    imgui.separator();
    drawInspectorDetails(renderer);

    imgui.separator();
    drawCollisionInspector(collision_world, renderer, camera, controller, &inspector.collision);
}

fn drawInspectorDetails(renderer: *const q3.renderer.SceneRenderer) void {
    var line_buf: [320]u8 = undefined;

    if (renderer.selectedSceneObject()) |object| {
        const summary = std.fmt.bufPrintZ(
            &line_buf,
            "Selected entity {d}  batches {d}",
            .{ object.entity_index, renderer.selectedSceneObjectBatchCount() },
        ) catch return;
        imgui.text(summary);

        const class_line = std.fmt.bufPrintZ(&line_buf, "classname: {s}", .{object.classname}) catch return;
        imgui.text(class_line);

        const target_line = std.fmt.bufPrintZ(&line_buf, "targetname: {s}", .{object.targetname orelse "-"}) catch return;
        imgui.text(target_line);

        const model_line = std.fmt.bufPrintZ(&line_buf, "model: {s}", .{object.model_path orelse "-"}) catch return;
        imgui.text(model_line);

        if (object.bsp_model_index) |model_index| {
            const bsp_line = std.fmt.bufPrintZ(&line_buf, "bsp model index: {d}", .{model_index}) catch return;
            imgui.text(bsp_line);
        }

        const origin_line = std.fmt.bufPrintZ(
            &line_buf,
            "origin: ({d:.1}, {d:.1}, {d:.1})",
            .{ object.origin.x, object.origin.y, object.origin.z },
        ) catch return;
        imgui.text(origin_line);

        if (object.bounds) |bounds| {
            const bounds_min = std.fmt.bufPrintZ(
                &line_buf,
                "bounds min: ({d:.1}, {d:.1}, {d:.1})",
                .{ bounds.min.x, bounds.min.y, bounds.min.z },
            ) catch return;
            imgui.text(bounds_min);

            const bounds_max = std.fmt.bufPrintZ(
                &line_buf,
                "bounds max: ({d:.1}, {d:.1}, {d:.1})",
                .{ bounds.max.x, bounds.max.y, bounds.max.z },
            ) catch return;
            imgui.text(bounds_max);
        }
        return;
    }

    const empty_line = std.fmt.bufPrintZ(&line_buf, "No scene object selected. Total objects: {d}", .{renderer.scene_objects.len}) catch return;
    imgui.text(empty_line);
}

fn focusCameraOnSelection(
    renderer: *const q3.renderer.SceneRenderer,
    camera: *rl.Camera,
    controller: *CameraController,
) void {
    const focus = renderer.selectedSceneObjectFocusPoint() orelse return;
    const target = toRlVector3(focus);
    camera.target = target;
    camera.position = .{
        .x = target.x + 160.0,
        .y = target.y + 120.0,
        .z = target.z + 160.0,
    };
    controller.syncFromCamera(camera.*);
}

const CollisionTraceMode = enum {
    forward,
    selection,
};

const CollisionTraceSnapshot = struct {
    start: q3.math.Vec3,
    intended_end: q3.math.Vec3,
    result: q3.collision.TraceResult,
};

const CollisionDebugState = struct {
    draw_debug: bool = true,
    use_box_trace: bool = true,
    trace_mode: CollisionTraceMode = .selection,
    trace_length_index: usize = 2,
    camera_contents: i32 = 0,
    camera_movement_contents: i32 = 0,
    last_trace: ?CollisionTraceSnapshot = null,
};

const collision_trace_lengths = [_]f32{ 256.0, 512.0, 1024.0, 2048.0, 4096.0 };
const collision_box_mins = q3.math.Vec3{ .x = -16.0, .y = -16.0, .z = -24.0 };
const collision_box_maxs = q3.math.Vec3{ .x = 16.0, .y = 16.0, .z = 32.0 };

fn updateCollisionDebugState(
    state: *CollisionDebugState,
    collision_world: *const q3.collision.World,
    map: *const q3.bsp.Map,
    camera: *const rl.Camera,
    controller: *const CameraController,
    renderer: *const q3.renderer.SceneRenderer,
) void {
    const start = fromRlVector3(camera.position);
    state.camera_contents = collision_world.pointContents(map, start);
    state.camera_movement_contents = collision_world.pointContentsMasked(map, start, q3.collision.movement_mask);

    const intended_end = collisionTraceTarget(state, camera, controller, renderer);
    const result = if (state.use_box_trace)
        collision_world.traceBoxMasked(map, start, intended_end, collision_box_mins, collision_box_maxs, q3.collision.movement_mask)
    else
        collision_world.traceSegmentMasked(map, start, intended_end, q3.collision.movement_mask);

    state.last_trace = .{
        .start = start,
        .intended_end = intended_end,
        .result = result,
    };
}

fn collisionTraceTarget(
    state: *const CollisionDebugState,
    camera: *const rl.Camera,
    controller: *const CameraController,
    renderer: *const q3.renderer.SceneRenderer,
) q3.math.Vec3 {
    if (state.trace_mode == .selection) {
        if (renderer.selectedSceneObjectFocusPoint()) |focus| return focus;
    }

    const start = fromRlVector3(camera.position);
    const forward = fromRlVector3(controller.forwardVector());
    return addVec3(start, scaleVec3(forward, collision_trace_lengths[state.trace_length_index]));
}

fn drawCollisionInspector(
    collision_world: *const q3.collision.World,
    renderer: *q3.renderer.SceneRenderer,
    camera: *rl.Camera,
    controller: *CameraController,
    state: *CollisionDebugState,
) void {
    var line_buf: [320]u8 = undefined;

    imgui.text("Collision");
    _ = imgui.checkbox("Draw collision trace", &state.draw_debug);
    _ = imgui.checkbox("Use swept player box", &state.use_box_trace);

    if (imgui.button("Target forward")) state.trace_mode = .forward;
    imgui.sameLine();
    if (imgui.button("Target selection")) state.trace_mode = .selection;
    imgui.sameLine();
    if (imgui.button("Focus hit")) {
        focusCameraOnCollisionHit(camera, controller, state);
    }

    if (imgui.button("Shorter trace")) {
        if (state.trace_length_index > 0) state.trace_length_index -= 1;
    }
    imgui.sameLine();
    if (imgui.button("Longer trace")) {
        if (state.trace_length_index + 1 < collision_trace_lengths.len) state.trace_length_index += 1;
    }

    const summary = std.fmt.bufPrintZ(
        &line_buf,
        "Brushes: {d}  Camera contents: 0x{x}  Move mask: 0x{x}  Trace len: {d:.0}",
        .{
            collision_world.brushes.len,
            @as(u32, @bitCast(state.camera_contents)),
            @as(u32, @bitCast(state.camera_movement_contents)),
            collision_trace_lengths[state.trace_length_index],
        },
    ) catch return;
    imgui.text(summary);

    const mode_line = std.fmt.bufPrintZ(
        &line_buf,
        "Mode: {s}  Query: {s}",
        .{
            switch (state.trace_mode) {
                .forward => "forward",
                .selection => "selection",
            },
            if (state.use_box_trace) "swept_box" else "segment",
        },
    ) catch return;
    imgui.text(mode_line);

    if (state.trace_mode == .selection and renderer.selectedSceneObject() == null) {
        imgui.text("Selection target unavailable; using forward trace.");
    }

    if (state.last_trace) |trace| {
        const result = trace.result;
        const trace_line = std.fmt.bufPrintZ(
            &line_buf,
            "Hit: {s}  Start solid: {s}  Fraction: {d:.3}",
            .{
                if (result.hit) "yes" else "no",
                if (result.start_solid) "yes" else "no",
                result.fraction,
            },
        ) catch return;
        imgui.text(trace_line);

        const hit_line = std.fmt.bufPrintZ(
            &line_buf,
            "End: ({d:.1}, {d:.1}, {d:.1})",
            .{ result.end_position.x, result.end_position.y, result.end_position.z },
        ) catch return;
        imgui.text(hit_line);

        if (result.hit) {
            const normal_line = std.fmt.bufPrintZ(
                &line_buf,
                "Normal: ({d:.2}, {d:.2}, {d:.2})",
                .{ result.normal.x, result.normal.y, result.normal.z },
            ) catch return;
            imgui.text(normal_line);

            const brush_line = if (result.brush_index) |brush_index|
                std.fmt.bufPrintZ(
                    &line_buf,
                    "Brush: {d}  Contents: 0x{x}  Flags: 0x{x}",
                    .{
                        brush_index,
                        @as(u32, @bitCast(result.contents)),
                        @as(u32, @bitCast(result.flags)),
                    },
                ) catch return
            else
                std.fmt.bufPrintZ(
                    &line_buf,
                    "Brush: none  Contents: 0x{x}  Flags: 0x{x}",
                    .{
                        @as(u32, @bitCast(result.contents)),
                        @as(u32, @bitCast(result.flags)),
                    },
                ) catch return;
            imgui.text(brush_line);
        }
    }
}

fn focusCameraOnCollisionHit(
    camera: *rl.Camera,
    controller: *CameraController,
    state: *const CollisionDebugState,
) void {
    const trace = state.last_trace orelse return;
    const target = toRlVector3(trace.result.end_position);
    camera.target = target;
    camera.position = .{
        .x = target.x + 96.0,
        .y = target.y + 64.0,
        .z = target.z + 96.0,
    };
    controller.syncFromCamera(camera.*);
}

fn drawCollisionDebug(state: *const CollisionDebugState) void {
    if (!state.draw_debug) return;
    const trace = state.last_trace orelse return;

    const start = toRlVector3(trace.start);
    const intended_end = toRlVector3(trace.intended_end);
    const actual_end = toRlVector3(trace.result.end_position);
    const to_target = subtract(intended_end, start);
    const start_dir = normalize(to_target);
    const start_hint = add(start, scale(start_dir, 64.0));

    rl.drawCubeWiresV(start_hint, .{ .x = 6.0, .y = 6.0, .z = 6.0 }, .sky_blue);
    rl.drawLine3D(start, start_hint, .sky_blue);
    rl.drawLine3D(start, intended_end, .dark_gray);
    rl.drawLine3D(start, actual_end, if (trace.result.hit) .orange else .green);

    if (state.use_box_trace) {
        const distance_sq =
            (trace.result.end_position.x - trace.start.x) * (trace.result.end_position.x - trace.start.x) +
            (trace.result.end_position.y - trace.start.y) * (trace.result.end_position.y - trace.start.y) +
            (trace.result.end_position.z - trace.start.z) * (trace.result.end_position.z - trace.start.z);
        if (trace.result.start_solid or distance_sq < 1.0) {
            rl.drawSphereWires(actual_end, 12.0, 8, 8, .orange);
        } else {
            rl.drawCubeWiresV(actual_end, .{ .x = 32.0, .y = 56.0, .z = 32.0 }, if (trace.result.hit) .orange else .green);
        }
    }

    if (trace.result.hit) {
        const normal_end = toRlVector3(addVec3(trace.result.end_position, scaleVec3(trace.result.normal, 48.0)));
        rl.drawSphereWires(actual_end, 8.0, 8, 8, .yellow);
        rl.drawLine3D(actual_end, normal_end, .yellow);
    }
}

fn fromRlVector3(v: rl.Vector3) q3.math.Vec3 {
    return .{ .x = v.x, .y = v.y, .z = v.z };
}

fn addVec3(a: q3.math.Vec3, b: q3.math.Vec3) q3.math.Vec3 {
    return .{
        .x = a.x + b.x,
        .y = a.y + b.y,
        .z = a.z + b.z,
    };
}

fn scaleVec3(v: q3.math.Vec3, amount: f32) q3.math.Vec3 {
    return .{
        .x = v.x * amount,
        .y = v.y * amount,
        .z = v.z * amount,
    };
}
