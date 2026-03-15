const std = @import("std");
const rl = @import("raylib");
const q3 = @import("quake3/mod.zig");
const imgui = @import("ui/imgui.zig");

pub fn run(allocator: std.mem.Allocator) !void {
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    const options = try parseRunOptions(args);
    var startup_profile: StartupProfile = .{};
    startup_profile.capture("process_start", null);

    if (options.dump_stats) {
        rl.setTraceLogLevel(.warning);
    }

    var packs = try q3.archive.Pk3Collection.initFromPath(allocator, options.source_path);
    defer packs.deinit();
    startup_profile.capture("pk3_collection", null);

    const map_ref = if (options.requested_bsp) |name|
        packs.findMap(name) orelse return error.MapNotFound
    else
        packs.findFirstMap() orelse return error.NoMapsFound;

    const map_bytes = try packs.readFileAlloc(allocator, map_ref.path);
    defer allocator.free(map_bytes);
    startup_profile.capture("map_bytes_read", null);

    var map = try q3.bsp.Map.init(allocator, map_ref.path, map_bytes);
    defer map.deinit();
    startup_profile.capture("bsp_parsed", map.estimatedMemoryBytes());

    const validation = map.validate();
    var entity_list = try map.parseEntities(allocator);
    defer entity_list.deinit();
    startup_profile.capture("entities_parsed", map.estimatedMemoryBytes() + entity_list.estimatedMemoryBytes());
    var collision_world = try q3.collision.World.initFromMap(allocator, &map);
    defer collision_world.deinit();
    startup_profile.capture(
        "collision_built",
        map.estimatedMemoryBytes() + entity_list.estimatedMemoryBytes() + collision_world.estimatedMemoryBytes(),
    );

    rl.setConfigFlags(.{ .window_resizable = true, .msaa_4x_hint = true });
    rl.initWindow(1600, 900, "quake3 pk3 viewer");
    defer rl.closeWindow();
    startup_profile.capture("window_ready", null);

    imgui.setup(true);
    defer imgui.shutdown();
    startup_profile.capture("imgui_ready", null);

    var renderer = try q3.renderer.SceneRenderer.init(allocator, &packs, &map);
    defer renderer.deinit();
    startup_profile.capture(
        "renderer_ready",
        totalTrackedBytes(&map, &entity_list, &collision_world, &renderer),
    );

    var camera = defaultCamera(toRlVector3(map.bounds_center));
    applyCameraOverrides(&camera, options);
    var controller = CameraController.init(camera);
    var inspector: InspectorState = .{};
    var profiler: FrameProfiler = .{};
    var frame_count: usize = 0;
    rl.setTargetFPS(144);

    while (!rl.windowShouldClose()) {
        const frame_start_ns = std.time.nanoTimestamp();

        if (rl.isKeyPressed(.f8)) {
            inspector.visible = !inspector.visible;
        }
        if (rl.isKeyPressed(.f9)) {
            inspector.stats_visible = !inspector.stats_visible;
        }

        const input_start_ns = std.time.nanoTimestamp();
        controller.update(&camera, inspector.capture_mouse, inspector.capture_keyboard);
        const input_end_ns = std.time.nanoTimestamp();

        const collision_start_ns = std.time.nanoTimestamp();
        updateCollisionDebugState(&inspector.collision, &collision_world, &map, &camera, &controller, &renderer);
        const collision_end_ns = std.time.nanoTimestamp();

        rl.beginDrawing();
        rl.clearBackground(.{ .r = 10, .g = 8, .b = 6, .a = 255 });

        const world_draw_start_ns = std.time.nanoTimestamp();
        rl.beginMode3D(camera);
        renderer.draw(camera);
        drawCollisionDebug(&inspector.collision);
        rl.endMode3D();
        const world_draw_end_ns = std.time.nanoTimestamp();

        const ui_start_ns = std.time.nanoTimestamp();
        imgui.begin();
        if (inspector.visible) {
            drawInspector(&collision_world, &renderer, &camera, &controller, &inspector, &profiler);
        }
        if (inspector.stats_visible) {
            drawRuntimeStatsWindow(
                &profiler,
                &map,
                &entity_list,
                &collision_world,
                options.source_path,
                &renderer,
                validation.issueCount(),
                inspector.visible,
                &inspector.stats_visible,
            );
        }

        inspector.capture_mouse = imgui.wantCaptureMouse();
        inspector.capture_keyboard = imgui.wantCaptureKeyboard();
        imgui.end();
        const ui_end_ns = std.time.nanoTimestamp();

        const overlay_start_ns = std.time.nanoTimestamp();
        drawOverlay(map.path, &renderer, inspector.visible, inspector.stats_visible);
        const overlay_end_ns = std.time.nanoTimestamp();

        const cpu_frame_end_ns = std.time.nanoTimestamp();
        rl.endDrawing();
        const frame_end_ns = std.time.nanoTimestamp();

        profiler.record(.{
            .input_ns = nsBetween(input_start_ns, input_end_ns),
            .collision_ns = nsBetween(collision_start_ns, collision_end_ns),
            .world_draw_ns = nsBetween(world_draw_start_ns, world_draw_end_ns),
            .ui_ns = nsBetween(ui_start_ns, ui_end_ns),
            .overlay_ns = nsBetween(overlay_start_ns, overlay_end_ns),
            .cpu_frame_ns = nsBetween(frame_start_ns, cpu_frame_end_ns),
            .present_wait_ns = nsBetween(cpu_frame_end_ns, frame_end_ns),
            .total_frame_ns = nsBetween(frame_start_ns, frame_end_ns),
        });

        frame_count += 1;
        if (frame_count == 1) {
            startup_profile.capture(
                "first_frame",
                totalTrackedBytes(&map, &entity_list, &collision_world, &renderer),
            );
        }

        if (options.dump_stats and frame_count >= options.max_frames) {
            dumpStatsReport(
                options,
                &startup_profile,
                &profiler,
                &map,
                &entity_list,
                &collision_world,
                &renderer,
                camera,
                validation.issueCount(),
            );
            break;
        }
    }
}

const RunOptions = struct {
    source_path: []const u8 = "assets/maps",
    requested_bsp: ?[]const u8 = null,
    dump_stats: bool = false,
    max_frames: usize = 1,
    camera_position: ?rl.Vector3 = null,
    camera_target: ?rl.Vector3 = null,
};

fn parseRunOptions(args: []const []const u8) !RunOptions {
    var options: RunOptions = .{};
    var positional_index: usize = 0;
    var i: usize = 1;

    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--dump-stats")) {
            options.dump_stats = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--frames")) {
            i += 1;
            if (i >= args.len) return error.MissingFramesValue;
            options.max_frames = try std.fmt.parseInt(usize, args[i], 10);
            if (options.max_frames == 0) options.max_frames = 1;
            continue;
        }
        if (std.mem.eql(u8, arg, "--camera")) {
            options.camera_position = try parseVector3Option(args, &i, error.MissingCameraValue);
            continue;
        }
        if (std.mem.eql(u8, arg, "--target")) {
            options.camera_target = try parseVector3Option(args, &i, error.MissingTargetValue);
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--")) {
            return error.UnknownOption;
        }

        switch (positional_index) {
            0 => options.source_path = arg,
            1 => options.requested_bsp = arg,
            else => return error.TooManyArguments,
        }
        positional_index += 1;
    }

    if (options.dump_stats and options.max_frames == 0) options.max_frames = 1;
    return options;
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

fn applyCameraOverrides(camera: *rl.Camera, options: RunOptions) void {
    if (options.camera_position) |position| {
        camera.position = position;
    }
    if (options.camera_target) |target| {
        camera.target = target;
    } else if (options.camera_position != null) {
        camera.target = .{
            .x = camera.position.x,
            .y = camera.position.y,
            .z = camera.position.z - 1.0,
        };
    }
}

fn parseVector3Option(args: []const []const u8, index: *usize, missing_error: anyerror) !rl.Vector3 {
    if (index.* + 3 >= args.len) return missing_error;
    index.* += 1;
    const x = try std.fmt.parseFloat(f32, args[index.*]);
    index.* += 1;
    const y = try std.fmt.parseFloat(f32, args[index.*]);
    index.* += 1;
    const z = try std.fmt.parseFloat(f32, args[index.*]);
    return .{ .x = x, .y = y, .z = z };
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
    map_path: []const u8,
    renderer: *const q3.renderer.SceneRenderer,
    inspector_visible: bool,
    stats_visible: bool,
) void {
    var line_buf: [320]u8 = undefined;
    const status_line = std.fmt.bufPrintZ(
        &line_buf,
        "{s}  {d} FPS  inspector={s} stats={s}  world={s} submodels={s}",
        .{
            map_path,
            rl.getFPS(),
            if (inspector_visible) "on" else "off",
            if (stats_visible) "on" else "off",
            if (renderer.draw_world_geometry) "on" else "off",
            if (renderer.draw_submodel_geometry) "on" else "off",
        },
    ) catch return;

    rl.drawRectangle(12, 12, 720, 54, rl.fade(.black, 0.52));
    rl.drawRectangleLines(12, 12, 720, 54, .dark_gray);
    rl.drawText(status_line, 24, 24, 18, .light_gray);
    rl.drawText("RMB look  WASD fly  E/Q up-down  Tab objects  F1-F7 render toggles  F8 inspector  F9 stats", 24, 44, 16, .gray);
}

const InspectorState = struct {
    visible: bool = true,
    stats_visible: bool = true,
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
    profiler: *const FrameProfiler,
) void {
    imgui.setNextWindowSize(430.0, 620.0);
    const open = imgui.beginWindow("Scene Inspector", &inspector.visible);
    defer imgui.endWindow();
    if (!open) return;

    _ = imgui.checkbox("Draw scene object markers", &renderer.draw_scene_objects);
    _ = imgui.checkbox("Draw world geometry", &renderer.draw_world_geometry);
    _ = imgui.checkbox("Draw submodel geometry", &renderer.draw_submodel_geometry);
    _ = imgui.checkbox("Isolate selected BSP submodel", &renderer.isolate_selected_submodel);
    _ = imgui.checkbox("PVS visibility culling", &renderer.visibility_culling);
    _ = imgui.checkbox("Frustum visibility culling", &renderer.frustum_culling);
    _ = imgui.checkbox("Wireframe renderer", &renderer.draw_wireframe);
    _ = imgui.checkbox("Fullbright renderer", &renderer.fullbright);
    _ = imgui.checkbox("Backface culling", &renderer.backface_culling);
    _ = imgui.checkbox("Show runtime stats window", &inspector.stats_visible);

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
    drawQuickPerformanceSummary(profiler);

    imgui.separator();
    drawCollisionInspector(collision_world, renderer, camera, controller, &inspector.collision);
}

const FrameSample = struct {
    input_ns: u64 = 0,
    collision_ns: u64 = 0,
    world_draw_ns: u64 = 0,
    ui_ns: u64 = 0,
    overlay_ns: u64 = 0,
    cpu_frame_ns: u64 = 0,
    present_wait_ns: u64 = 0,
    total_frame_ns: u64 = 0,
};

const FrameMetric = struct {
    current_ms: f32 = 0.0,
    smoothed_ms: f32 = 0.0,

    fn record(self: *FrameMetric, ns: u64) void {
        const ms = @as(f32, @floatFromInt(ns)) / 1_000_000.0;
        self.current_ms = ms;
        self.smoothed_ms = if (self.smoothed_ms == 0.0) ms else self.smoothed_ms * 0.88 + ms * 0.12;
    }
};

const FrameProfiler = struct {
    input: FrameMetric = .{},
    collision: FrameMetric = .{},
    world_draw: FrameMetric = .{},
    ui: FrameMetric = .{},
    overlay: FrameMetric = .{},
    cpu_frame: FrameMetric = .{},
    present_wait: FrameMetric = .{},
    total_frame: FrameMetric = .{},
    process_memory: ProcessMemoryStats = .{},

    fn record(self: *FrameProfiler, sample: FrameSample) void {
        self.input.record(sample.input_ns);
        self.collision.record(sample.collision_ns);
        self.world_draw.record(sample.world_draw_ns);
        self.ui.record(sample.ui_ns);
        self.overlay.record(sample.overlay_ns);
        self.cpu_frame.record(sample.cpu_frame_ns);
        self.present_wait.record(sample.present_wait_ns);
        self.total_frame.record(sample.total_frame_ns);
        self.process_memory.refresh();
    }
};

const ProcessMemoryStats = struct {
    rss_bytes: ?usize = null,
    virtual_bytes: ?usize = null,
    rss_anon_bytes: ?usize = null,
    rss_file_bytes: ?usize = null,
    rss_shmem_bytes: ?usize = null,
    last_refresh_ms: i64 = 0,

    fn refresh(self: *ProcessMemoryStats) void {
        const now_ms = std.time.milliTimestamp();
        if (now_ms - self.last_refresh_ms < 250) return;
        self.last_refresh_ms = now_ms;

        var buffer: [16 * 1024]u8 = undefined;
        const data = readProcSelfStatus(&buffer) catch {
            self.* = .{ .last_refresh_ms = now_ms };
            return;
        };

        self.rss_bytes = parseProcStatusKiB(data, "VmRSS:");
        self.virtual_bytes = parseProcStatusKiB(data, "VmSize:");
        self.rss_anon_bytes = parseProcStatusKiB(data, "RssAnon:");
        self.rss_file_bytes = parseProcStatusKiB(data, "RssFile:");
        self.rss_shmem_bytes = parseProcStatusKiB(data, "RssShmem:");
    }

    fn sampleNow() ProcessMemoryStats {
        var stats: ProcessMemoryStats = .{};
        stats.last_refresh_ms = std.time.milliTimestamp();

        var buffer: [16 * 1024]u8 = undefined;
        const data = readProcSelfStatus(&buffer) catch return stats;

        stats.rss_bytes = parseProcStatusKiB(data, "VmRSS:");
        stats.virtual_bytes = parseProcStatusKiB(data, "VmSize:");
        stats.rss_anon_bytes = parseProcStatusKiB(data, "RssAnon:");
        stats.rss_file_bytes = parseProcStatusKiB(data, "RssFile:");
        stats.rss_shmem_bytes = parseProcStatusKiB(data, "RssShmem:");
        return stats;
    }
};

const PhaseSnapshot = struct {
    label: []const u8,
    process_memory: ProcessMemoryStats,
    tracked_bytes: ?usize = null,
};

const StartupProfile = struct {
    snapshots: [16]PhaseSnapshot = undefined,
    count: usize = 0,

    fn capture(self: *StartupProfile, label: []const u8, tracked_bytes: ?usize) void {
        if (self.count >= self.snapshots.len) return;
        self.snapshots[self.count] = .{
            .label = label,
            .process_memory = ProcessMemoryStats.sampleNow(),
            .tracked_bytes = tracked_bytes,
        };
        self.count += 1;
    }
};

fn drawRuntimeStatsWindow(
    profiler: *const FrameProfiler,
    map: *const q3.bsp.Map,
    entity_list: *const q3.entities.EntityList,
    collision_world: *const q3.collision.World,
    source_path: []const u8,
    renderer: *const q3.renderer.SceneRenderer,
    validation_issue_count: usize,
    inspector_visible: bool,
    stats_visible: *bool,
) void {
    imgui.setNextWindowSize(470.0, 420.0);
    const open = imgui.beginWindow("Runtime Stats", stats_visible);
    defer imgui.endWindow();
    if (!open) return;

    var line_buf: [320]u8 = undefined;
    var texture_mem_buf: [32]u8 = undefined;
    var lightmap_mem_buf: [32]u8 = undefined;
    var geom_mem_buf: [32]u8 = undefined;
    var wire_mem_buf: [32]u8 = undefined;
    var material_mem_buf: [32]u8 = undefined;
    var visibility_mem_buf: [32]u8 = undefined;
    var total_mem_buf: [32]u8 = undefined;
    var bsp_mem_buf: [32]u8 = undefined;
    var entity_mem_buf: [32]u8 = undefined;
    var collision_mem_buf: [32]u8 = undefined;
    var object_mem_buf: [32]u8 = undefined;
    var cache_mem_buf: [32]u8 = undefined;
    var rss_mem_buf: [32]u8 = undefined;
    var vmem_mem_buf: [32]u8 = undefined;
    var anon_mem_buf: [32]u8 = undefined;
    var file_mem_buf: [32]u8 = undefined;
    var shmem_mem_buf: [32]u8 = undefined;
    var untracked_mem_buf: [32]u8 = undefined;
    const parsed_bsp_bytes = map.estimatedMemoryBytes();
    const entities_bytes = entity_list.estimatedMemoryBytes();
    const collision_bytes = collision_world.estimatedMemoryBytes();
    const object_bytes = renderer.estimatedSceneObjectMemoryBytes();
    const cache_meta_bytes = renderer.estimatedCacheMetadataMemoryBytes();
    const total_tracked_bytes = totalTrackedBytes(map, entity_list, collision_world, renderer);
    const frame_line = std.fmt.bufPrintZ(
        &line_buf,
        "FPS {d}  frame {d:.2} ms  CPU {d:.2} ms  present {d:.2} ms",
        .{
            rl.getFPS(),
            rl.getFrameTime() * 1000.0,
            profiler.cpu_frame.current_ms,
            profiler.present_wait.current_ms,
        },
    ) catch return;
    imgui.text(frame_line);

    drawMetricLine("Input", profiler.input, profiler.total_frame.current_ms);
    drawMetricLine("Collision", profiler.collision, profiler.total_frame.current_ms);
    drawMetricLine("World draw", profiler.world_draw, profiler.total_frame.current_ms);
    drawMetricLine("ImGui", profiler.ui, profiler.total_frame.current_ms);
    drawMetricLine("Overlay", profiler.overlay, profiler.total_frame.current_ms);
    drawMetricLine("CPU frame", profiler.cpu_frame, profiler.total_frame.current_ms);
    drawMetricLine("Present/wait", profiler.present_wait, profiler.total_frame.current_ms);

    imgui.separator();

    const map_line = std.fmt.bufPrintZ(&line_buf, "Map: {s}", .{map.path}) catch return;
    imgui.text(map_line);
    const source_line = std.fmt.bufPrintZ(&line_buf, "PK3 source: {s}", .{source_path}) catch return;
    imgui.text(source_line);

    const content_line = std.fmt.bufPrintZ(
        &line_buf,
        "Entities: {d}  Validation issues: {d}  Scene objects: {d}",
        .{ entity_list.items.len, validation_issue_count, renderer.scene_objects.len },
    ) catch return;
    imgui.text(content_line);

    const batch_line = std.fmt.bufPrintZ(
        &line_buf,
        "Batches: {d}  Drawn: {d}  Faces: {d}  Verts: {d}  Drawn verts: {d}",
        .{
            renderer.stats.batch_count,
            renderer.stats.drawn_batch_count,
            renderer.stats.face_count,
            renderer.stats.vertex_count,
            renderer.stats.drawn_vertex_count,
        },
    ) catch return;
    imgui.text(batch_line);

    const textures_line = std.fmt.bufPrintZ(
        &line_buf,
        "Textures: {d} ({s})  Lightmaps: {d} ({s})  Missing textures: {d}",
        .{
            renderer.stats.loaded_texture_count,
            formatMemorySizeZ(&texture_mem_buf, renderer.stats.texture_memory_bytes),
            renderer.stats.lightmap_texture_count,
            formatMemorySizeZ(&lightmap_mem_buf, renderer.stats.lightmap_memory_bytes),
            renderer.stats.missing_texture_count,
        },
    ) catch return;
    imgui.text(textures_line);

    const scene_line = std.fmt.bufPrintZ(
        &line_buf,
        "Scene models: {d}  BSP submodels: {d}  World batches: {d}  Submodel batches: {d}  Animated batches: {d}",
        .{
            renderer.stats.model_instance_count,
            renderer.stats.bsp_submodel_instance_count,
            renderer.stats.world_batch_count,
            renderer.stats.submodel_batch_count,
            renderer.stats.animated_batch_count,
        },
    ) catch return;
    imgui.text(scene_line);

    const visibility_line = std.fmt.bufPrintZ(
        &line_buf,
        "Visibility: pvs={s}  frustum={s}  leaf={s}  cluster={d}  world visible={d}  pvs culled={d}  frustum culled={d}",
        .{
            if (renderer.visibility_culling) "on" else "off",
            if (renderer.frustum_culling) "on" else "off",
            if (renderer.last_camera_leaf_index != null) "yes" else "no",
            renderer.last_camera_cluster,
            renderer.stats.frustum_visible_world_batch_count,
            renderer.stats.pvs_culled_world_batch_count,
            renderer.stats.frustum_culled_world_batch_count,
        },
    ) catch return;
    imgui.text(visibility_line);

    const memory_line = std.fmt.bufPrintZ(
        &line_buf,
        "CPU est: geom {s}  wire {s}  materials {s}  vis {s}  total tracked {s}",
        .{
            formatMemorySizeZ(&geom_mem_buf, renderer.stats.geometry_memory_bytes),
            formatMemorySizeZ(&wire_mem_buf, renderer.stats.wireframe_memory_bytes),
            formatMemorySizeZ(&material_mem_buf, renderer.stats.material_memory_bytes),
            formatMemorySizeZ(&visibility_mem_buf, renderer.stats.visibility_memory_bytes),
            formatMemorySizeZ(&total_mem_buf, total_tracked_bytes),
        },
    ) catch return;
    imgui.text(memory_line);

    const content_mem_line = std.fmt.bufPrintZ(
        &line_buf,
        "Content: bsp {s}  entities {s}  collision {s}  scene objs {s}  cache meta {s}",
        .{
            formatMemorySizeZ(&bsp_mem_buf, parsed_bsp_bytes),
            formatMemorySizeZ(&entity_mem_buf, entities_bytes),
            formatMemorySizeZ(&collision_mem_buf, collision_bytes),
            formatMemorySizeZ(&object_mem_buf, object_bytes),
            formatMemorySizeZ(&cache_mem_buf, cache_meta_bytes),
        },
    ) catch return;
    imgui.text(content_mem_line);

    if (profiler.process_memory.rss_bytes) |rss_bytes| {
        const process_line = std.fmt.bufPrintZ(
            &line_buf,
            "Process: RSS {s}  VmSize {s}  Untracked gap {s}",
            .{
                formatMemorySizeZ(&rss_mem_buf, rss_bytes),
                formatMemorySizeZ(&vmem_mem_buf, profiler.process_memory.virtual_bytes orelse 0),
                formatMemorySizeZ(&untracked_mem_buf, rss_bytes -| total_tracked_bytes),
            },
        ) catch return;
        imgui.text(process_line);
        const rss_split_line = std.fmt.bufPrintZ(
            &line_buf,
            "RSS split: anon {s}  file {s}  shmem {s}",
            .{
                formatMemorySizeZ(&anon_mem_buf, profiler.process_memory.rss_anon_bytes orelse 0),
                formatMemorySizeZ(&file_mem_buf, profiler.process_memory.rss_file_bytes orelse 0),
                formatMemorySizeZ(&shmem_mem_buf, profiler.process_memory.rss_shmem_bytes orelse 0),
            },
        ) catch return;
        imgui.text(rss_split_line);
    } else {
        imgui.text("Process: RSS unavailable on this platform/runtime.");
    }

    const toggle_line = std.fmt.bufPrintZ(
        &line_buf,
        "UI: inspector={s}  wire={s} fullbright={s} cull={s}",
        .{
            if (inspector_visible) "on" else "off",
            if (renderer.draw_wireframe) "on" else "off",
            if (renderer.fullbright) "on" else "off",
            if (renderer.backface_culling) "on" else "off",
        },
    ) catch return;
    imgui.text(toggle_line);

    if (renderer.selectedSceneObject()) |object| {
        const selected_line = std.fmt.bufPrintZ(
            &line_buf,
            "Selected: {d}/{d} {s}  class={s}  batches={d}",
            .{
                renderer.selected_scene_object_index.? + 1,
                renderer.scene_objects.len,
                object.model_path orelse object.classname,
                object.classname,
                renderer.selectedSceneObjectBatchCount(),
            },
        ) catch return;
        imgui.text(selected_line);
    } else {
        imgui.text("Selected: none");
    }
}

fn totalTrackedBytes(
    map: *const q3.bsp.Map,
    entity_list: *const q3.entities.EntityList,
    collision_world: *const q3.collision.World,
    renderer: *const q3.renderer.SceneRenderer,
) usize {
    return renderer.stats.geometry_memory_bytes +
        renderer.stats.wireframe_memory_bytes +
        renderer.stats.material_memory_bytes +
        renderer.stats.visibility_memory_bytes +
        renderer.stats.texture_memory_bytes +
        renderer.stats.lightmap_memory_bytes +
        map.estimatedMemoryBytes() +
        entity_list.estimatedMemoryBytes() +
        collision_world.estimatedMemoryBytes() +
        renderer.estimatedSceneObjectMemoryBytes() +
        renderer.estimatedCacheMetadataMemoryBytes();
}

fn dumpStatsReport(
    options: RunOptions,
    startup_profile: *const StartupProfile,
    profiler: *const FrameProfiler,
    map: *const q3.bsp.Map,
    entity_list: *const q3.entities.EntityList,
    collision_world: *const q3.collision.World,
    renderer: *const q3.renderer.SceneRenderer,
    camera: rl.Camera,
    validation_issue_count: usize,
) void {
    const tracked_total = totalTrackedBytes(map, entity_list, collision_world, renderer);
    const bsp_bytes = map.estimatedMemoryBytes();
    const entities_bytes = entity_list.estimatedMemoryBytes();
    const collision_bytes = collision_world.estimatedMemoryBytes();
    const object_bytes = renderer.estimatedSceneObjectMemoryBytes();
    const cache_meta_bytes = renderer.estimatedCacheMetadataMemoryBytes();

    std.debug.print("=== zPK3 Runtime Stats ===\n", .{});
    std.debug.print("map: {s}\n", .{map.path});
    std.debug.print("source: {s}\n", .{options.source_path});
    std.debug.print("requested_bsp: {s}\n", .{options.requested_bsp orelse map.path});
    std.debug.print("frames: {d}\n", .{options.max_frames});
    std.debug.print(
        "camera: pos=({d:.2}, {d:.2}, {d:.2}) target=({d:.2}, {d:.2}, {d:.2})\n",
        .{
            camera.position.x,
            camera.position.y,
            camera.position.z,
            camera.target.x,
            camera.target.y,
            camera.target.z,
        },
    );
    std.debug.print("fps: {d}\n", .{rl.getFPS()});
    std.debug.print(
        "frame_ms: {d:.3} cpu_ms: {d:.3} present_ms: {d:.3}\n",
        .{ rl.getFrameTime() * 1000.0, profiler.cpu_frame.current_ms, profiler.present_wait.current_ms },
    );
    std.debug.print(
        "timings_ms: input={d:.3} collision={d:.3} world_draw={d:.3} imgui={d:.3} overlay={d:.3}\n",
        .{
            profiler.input.current_ms,
            profiler.collision.current_ms,
            profiler.world_draw.current_ms,
            profiler.ui.current_ms,
            profiler.overlay.current_ms,
        },
    );
    std.debug.print(
        "content: entities={d} validation_issues={d} scene_objects={d}\n",
        .{ entity_list.items.len, validation_issue_count, renderer.scene_objects.len },
    );
    std.debug.print(
        "batches: total={d} drawn={d} faces={d} verts={d} drawn_verts={d}\n",
        .{
            renderer.stats.batch_count,
            renderer.stats.drawn_batch_count,
            renderer.stats.face_count,
            renderer.stats.vertex_count,
            renderer.stats.drawn_vertex_count,
        },
    );
    std.debug.print(
        "textures: loaded={d} bytes={d} lightmaps={d} lightmap_bytes={d} missing={d}\n",
        .{
            renderer.stats.loaded_texture_count,
            renderer.stats.texture_memory_bytes,
            renderer.stats.lightmap_texture_count,
            renderer.stats.lightmap_memory_bytes,
            renderer.stats.missing_texture_count,
        },
    );
    std.debug.print(
        "scene: models={d} bsp_submodels={d} world_batches={d} submodel_batches={d} animated_batches={d}\n",
        .{
            renderer.stats.model_instance_count,
            renderer.stats.bsp_submodel_instance_count,
            renderer.stats.world_batch_count,
            renderer.stats.submodel_batch_count,
            renderer.stats.animated_batch_count,
        },
    );
    std.debug.print(
        "visibility: pvs={s} frustum={s} camera_leaf={?d} camera_cluster={d} world_visible={d} pvs_culled={d} frustum_culled={d}\n",
        .{
            if (renderer.visibility_culling) "true" else "false",
            if (renderer.frustum_culling) "true" else "false",
            renderer.last_camera_leaf_index,
            renderer.last_camera_cluster,
            renderer.stats.frustum_visible_world_batch_count,
            renderer.stats.pvs_culled_world_batch_count,
            renderer.stats.frustum_culled_world_batch_count,
        },
    );
    std.debug.print(
        "tracked_bytes: total={d} bsp={d} entities={d} collision={d} scene_objects={d} cache_meta={d} geometry={d} wireframe={d} materials={d} visibility={d} textures={d} lightmaps={d}\n",
        .{
            tracked_total,
            bsp_bytes,
            entities_bytes,
            collision_bytes,
            object_bytes,
            cache_meta_bytes,
            renderer.stats.geometry_memory_bytes,
            renderer.stats.wireframe_memory_bytes,
            renderer.stats.material_memory_bytes,
            renderer.stats.visibility_memory_bytes,
            renderer.stats.texture_memory_bytes,
            renderer.stats.lightmap_memory_bytes,
        },
    );
    std.debug.print(
        "process_bytes: rss={?d} vmsize={?d} rss_anon={?d} rss_file={?d} rss_shmem={?d} untracked_gap={?d}\n",
        .{
            profiler.process_memory.rss_bytes,
            profiler.process_memory.virtual_bytes,
            profiler.process_memory.rss_anon_bytes,
            profiler.process_memory.rss_file_bytes,
            profiler.process_memory.rss_shmem_bytes,
            if (profiler.process_memory.rss_bytes) |rss| rss -| tracked_total else null,
        },
    );

    std.debug.print("startup_phases:\n", .{});
    for (startup_profile.snapshots[0..startup_profile.count]) |snapshot| {
        std.debug.print(
            "  - {s}: rss={?d} vmsize={?d} anon={?d} file={?d} shmem={?d} tracked={?d}\n",
            .{
                snapshot.label,
                snapshot.process_memory.rss_bytes,
                snapshot.process_memory.virtual_bytes,
                snapshot.process_memory.rss_anon_bytes,
                snapshot.process_memory.rss_file_bytes,
                snapshot.process_memory.rss_shmem_bytes,
                snapshot.tracked_bytes,
            },
        );
    }
}

fn drawQuickPerformanceSummary(profiler: *const FrameProfiler) void {
    var line_buf: [192]u8 = undefined;
    const summary = std.fmt.bufPrintZ(
        &line_buf,
        "Frame {d:.2} ms  draw {d:.2} ms  ui {d:.2} ms  wait {d:.2} ms",
        .{
            profiler.total_frame.current_ms,
            profiler.world_draw.current_ms,
            profiler.ui.current_ms,
            profiler.present_wait.current_ms,
        },
    ) catch return;
    imgui.text(summary);
}

fn drawMetricLine(label: []const u8, metric: FrameMetric, total_ms: f32) void {
    var line_buf: [192]u8 = undefined;
    const percent = if (total_ms > 0.0) (metric.current_ms / total_ms) * 100.0 else 0.0;
    const line = std.fmt.bufPrintZ(
        &line_buf,
        "{s}: {d:>6.2} ms  avg {d:>6.2} ms  {d:>5.1}%",
        .{ label, metric.current_ms, metric.smoothed_ms, percent },
    ) catch return;
    imgui.text(line);
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
const collision_box_mins = q3.math.Vec3{ .x = -16.0, .y = -24.0, .z = -16.0 };
const collision_box_maxs = q3.math.Vec3{ .x = 16.0, .y = 32.0, .z = 16.0 };

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
    rl.drawLine3D(start, intended_end, .dark_gray);
    rl.drawLine3D(start, actual_end, if (trace.result.hit) .orange else .green);

    if (state.use_box_trace) {
        const box_center = toRlVector3(addVec3(trace.result.end_position, collisionBoxCenterOffset()));
        const box_size = collisionBoxSize();
        const distance_sq =
            (trace.result.end_position.x - trace.start.x) * (trace.result.end_position.x - trace.start.x) +
            (trace.result.end_position.y - trace.start.y) * (trace.result.end_position.y - trace.start.y) +
            (trace.result.end_position.z - trace.start.z) * (trace.result.end_position.z - trace.start.z);
        if (trace.result.start_solid or distance_sq < 1.0) {
            rl.drawSphereWires(box_center, 12.0, 8, 8, .orange);
        } else {
            rl.drawCubeWiresV(box_center, box_size, if (trace.result.hit) .orange else .green);
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

fn collisionBoxCenterOffset() q3.math.Vec3 {
    return .{
        .x = (collision_box_mins.x + collision_box_maxs.x) * 0.5,
        .y = (collision_box_mins.y + collision_box_maxs.y) * 0.5,
        .z = (collision_box_mins.z + collision_box_maxs.z) * 0.5,
    };
}

fn collisionBoxSize() rl.Vector3 {
    return .{
        .x = collision_box_maxs.x - collision_box_mins.x,
        .y = collision_box_maxs.y - collision_box_mins.y,
        .z = collision_box_maxs.z - collision_box_mins.z,
    };
}

fn nsBetween(start_ns: i128, end_ns: i128) u64 {
    if (end_ns <= start_ns) return 0;
    return @intCast(end_ns - start_ns);
}

fn formatMemorySizeZ(buffer: []u8, bytes: usize) [:0]const u8 {
    const kib = 1024.0;
    const mib = kib * 1024.0;
    const gib = mib * 1024.0;
    const value = @as(f64, @floatFromInt(bytes));

    if (value >= gib) {
        return std.fmt.bufPrintZ(buffer, "{d:.2} GiB", .{value / gib}) catch "n/a";
    }
    if (value >= mib) {
        return std.fmt.bufPrintZ(buffer, "{d:.2} MiB", .{value / mib}) catch "n/a";
    }
    if (value >= kib) {
        return std.fmt.bufPrintZ(buffer, "{d:.1} KiB", .{value / kib}) catch "n/a";
    }
    return std.fmt.bufPrintZ(buffer, "{d} B", .{bytes}) catch "n/a";
}

fn readProcSelfStatus(buffer: []u8) ![]const u8 {
    var file = try std.fs.openFileAbsolute("/proc/self/status", .{ .mode = .read_only });
    defer file.close();

    const read_len = try file.readAll(buffer);
    return buffer[0..read_len];
}

fn parseProcStatusKiB(data: []const u8, label: []const u8) ?usize {
    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, label)) continue;

        var tokens = std.mem.tokenizeAny(u8, line[label.len..], " \t\r");
        const value_text = tokens.next() orelse return null;
        const value_kib = std.fmt.parseInt(usize, value_text, 10) catch return null;
        return value_kib * 1024;
    }
    return null;
}
