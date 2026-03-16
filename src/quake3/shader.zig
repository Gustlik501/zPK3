const std = @import("std");

pub const BlendMode = enum {
    solid,
    filter,
    alpha,
    additive,
};

pub const CullMode = enum {
    back,
    front,
    none,
};

pub const MapKind = enum {
    map,
    clampmap,
    animmap,
    oneshotanimmap,
    lightmap,
};

pub const ColorGen = enum {
    identity,
    identity_lighting,
    vertex,
    constant,
};

pub const AlphaGen = enum {
    identity,
    vertex,
    constant,
};

pub const BillboardMode = enum {
    none,
    auto_sprite,
    auto_sprite2,
};

pub const TcGen = enum {
    base,
    environment,
};

pub const max_tcmods = 4;

pub const TcModKind = enum(i32) {
    scroll = 1,
    scale = 2,
    rotate = 3,
    turb = 4,
};

pub const TcMod = struct {
    kind: TcModKind,
    values: [4]f32 = .{ 0.0, 0.0, 0.0, 0.0 },
};

pub const Stage = struct {
    map_kind: MapKind = .map,
    blend_mode: BlendMode = .solid,
    alpha_cutout: bool = false,
    fps: f32 = 0.0,
    tcgen: TcGen = .base,
    tcmods: [max_tcmods]TcMod = [_]TcMod{.{ .kind = .scroll }} ** max_tcmods,
    tcmod_count: u8 = 0,
    rgb_gen: ColorGen = .identity,
    alpha_gen: AlphaGen = .identity,
    const_color: [4]f32 = .{ 1.0, 1.0, 1.0, 1.0 },
    texture: ?[]const u8 = null,
    anim_frames: [][]const u8 = &.{},

    pub fn deinit(self: *Stage, allocator: std.mem.Allocator) void {
        if (self.texture) |texture| allocator.free(texture);
        for (self.anim_frames) |frame| allocator.free(frame);
        allocator.free(self.anim_frames);
        self.* = undefined;
    }

    pub fn resolveImage(self: *const Stage, time_seconds: f64) ?[]const u8 {
        switch (self.map_kind) {
            .lightmap => return null,
            .map, .clampmap => return self.texture,
            .animmap, .oneshotanimmap => {
                if (self.anim_frames.len == 0) return null;
                if (self.fps <= 0.0) return self.anim_frames[0];

                const frame_float = @floor(time_seconds * @as(f64, self.fps));
                const raw_index: usize = @intFromFloat(@max(frame_float, 0.0));
                const index = switch (self.map_kind) {
                    .animmap => raw_index % self.anim_frames.len,
                    .oneshotanimmap => @min(raw_index, self.anim_frames.len - 1),
                    else => unreachable,
                };
                return self.anim_frames[index];
            },
        }
    }
};

pub const Definition = struct {
    editor_image: ?[]const u8 = null,
    cull_mode: CullMode = .back,
    billboard_mode: BillboardMode = .none,
    surfaceparm_nolightmap: bool = false,
    surfaceparm_fog: bool = false,
    surfaceparm_sky: bool = false,
    surfaceparm_nodraw: bool = false,
    surfaceparm_trans: bool = false,
    stages: []Stage = &.{},

    pub fn deinit(self: *Definition, allocator: std.mem.Allocator) void {
        if (self.editor_image) |editor_image| allocator.free(editor_image);
        for (self.stages) |*stage| stage.deinit(allocator);
        allocator.free(self.stages);
        self.* = undefined;
    }

    pub fn resolveImage(self: *const Definition, time_seconds: f64) ?[]const u8 {
        for (self.stages) |stage| {
            if (stage.resolveImage(time_seconds)) |image| return image;
        }
        return self.editor_image;
    }

    pub fn hasLightmapStage(self: *const Definition) bool {
        for (self.stages) |stage| {
            if (stage.map_kind == .lightmap) return true;
        }
        return false;
    }
};

pub const Library = struct {
    allocator: std.mem.Allocator,
    definitions: std.StringHashMap(Definition),

    pub fn init(allocator: std.mem.Allocator, packs: anytype) !Library {
        var library: Library = .{
            .allocator = allocator,
            .definitions = std.StringHashMap(Definition).init(allocator),
        };
        errdefer library.deinit();

        try library.loadFromPacks(packs);
        return library;
    }

    pub fn deinit(self: *Library) void {
        var it = self.definitions.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit(self.allocator);
        }
        self.definitions.deinit();
        self.* = undefined;
    }

    pub fn get(self: *const Library, name: []const u8) ?*const Definition {
        return self.definitions.getPtr(name);
    }

    pub fn estimatedMemoryBytes(self: *const Library) usize {
        var total: usize = @sizeOf(Library);
        var it = self.definitions.iterator();
        while (it.next()) |entry| {
            total += entry.key_ptr.*.len;
            total += @sizeOf(Definition);
            total += definitionMemoryBytes(entry.value_ptr.*);
        }
        return total;
    }

    fn loadFromPacks(self: *Library, packs: anytype) !void {
        const shader_files = try packs.collectFilesWithSuffixAlloc(self.allocator, ".shader");
        defer {
            for (shader_files) |path| self.allocator.free(path);
            self.allocator.free(shader_files);
        }

        for (shader_files) |path| {
            const data = try packs.readFileAlloc(self.allocator, path);
            defer self.allocator.free(data);
            try self.parseFile(data);
        }
    }

    fn parseFile(self: *Library, data: []const u8) !void {
        var lines = std.mem.splitScalar(u8, data, '\n');
        var current_name: ?[]const u8 = null;
        var depth: usize = 0;
        var definition: Definition = .{};
        var stages: std.ArrayList(Stage) = .empty;
        defer {
            if (current_name != null) {
                definition.deinit(self.allocator);
                for (stages.items) |*stage| stage.deinit(self.allocator);
            }
            stages.deinit(self.allocator);
        }
        var stage: Stage = .{};
        var stage_has_data = false;

        while (lines.next()) |raw_line| {
            const line = trimShaderLine(raw_line);
            if (line.len == 0) continue;

            if (current_name == null) {
                if (std.mem.eql(u8, line, "{") or std.mem.eql(u8, line, "}")) continue;
                if (std.mem.indexOfScalar(u8, line, '{')) |brace_index| {
                    const name = std.mem.trim(u8, line[0..brace_index], " \t\r");
                    if (name.len == 0) continue;
                    current_name = name;
                    depth = 1;
                    definition = .{};
                    continue;
                }
                current_name = line;
                depth = 0;
                definition = .{};
                continue;
            }

            if (std.mem.eql(u8, line, "{")) {
                depth += 1;
                if (depth == 2) {
                    stage = .{};
                    stage_has_data = false;
                }
                continue;
            }

            if (std.mem.eql(u8, line, "}")) {
                if (depth == 2) {
                    if (stage_has_data) try stages.append(self.allocator, stage);
                    depth = 1;
                    stage = .{};
                    stage_has_data = false;
                    continue;
                }
                if (depth == 1) {
                    definition.stages = try stages.toOwnedSlice(self.allocator);
                    stages = .empty;
                    try self.putDefinition(current_name.?, definition);
                    current_name = null;
                    depth = 0;
                    definition = .{};
                    continue;
                }
            }

            if (depth == 1) {
                try applyDefinitionKeyword(self.allocator, &definition, line);
            } else if (depth >= 2) {
                stage_has_data = try consumeStageLine(self.allocator, &stage, line) or stage_has_data;
            }
        }
    }

    fn putDefinition(self: *Library, shader_name: []const u8, definition: Definition) !void {
        const owned_key = try normalizeOwned(self.allocator, shader_name);
        errdefer self.allocator.free(owned_key);

        if (self.definitions.getEntry(owned_key)) |entry| {
            self.allocator.free(owned_key);
            entry.value_ptr.deinit(self.allocator);
            entry.value_ptr.* = definition;
            return;
        }

        try self.definitions.put(owned_key, definition);
    }
};

fn applyDefinitionKeyword(allocator: std.mem.Allocator, definition: *Definition, line: []const u8) !void {
    var tokens = std.mem.tokenizeAny(u8, line, " \t\r");
    const keyword = tokens.next() orelse return;

    if (std.mem.eql(u8, keyword, "qer_editorimage")) {
        if (tokens.next()) |value| {
            if (!isShaderImageTarget(value)) return;
            if (definition.editor_image) |editor_image| allocator.free(editor_image);
            definition.editor_image = try normalizeOwned(allocator, value);
        }
        return;
    }

    if (std.mem.eql(u8, keyword, "surfaceparm")) {
        const parm = tokens.next() orelse return;
        if (std.mem.eql(u8, parm, "nolightmap")) {
            definition.surfaceparm_nolightmap = true;
        } else if (std.mem.eql(u8, parm, "fog")) {
            definition.surfaceparm_fog = true;
        } else if (std.mem.eql(u8, parm, "sky")) {
            definition.surfaceparm_sky = true;
        } else if (std.mem.eql(u8, parm, "nodraw")) {
            definition.surfaceparm_nodraw = true;
        } else if (std.mem.eql(u8, parm, "trans")) {
            definition.surfaceparm_trans = true;
        }
        return;
    }

    if (std.mem.eql(u8, keyword, "cull")) {
        const mode = tokens.next() orelse return;
        if (std.mem.eql(u8, mode, "disable") or std.mem.eql(u8, mode, "none")) {
            definition.cull_mode = .none;
        } else if (std.mem.eql(u8, mode, "front") or std.mem.eql(u8, mode, "frontsided")) {
            definition.cull_mode = .front;
        } else {
            definition.cull_mode = .back;
        }
        return;
    }

    if (std.mem.eql(u8, keyword, "deformvertexes") or std.mem.eql(u8, keyword, "deformVertexes")) {
        const mode = tokens.next() orelse return;
        if (std.mem.eql(u8, mode, "autosprite") or std.mem.eql(u8, mode, "autoSprite")) {
            definition.billboard_mode = .auto_sprite;
        } else if (std.mem.eql(u8, mode, "autosprite2") or std.mem.eql(u8, mode, "autoSprite2")) {
            definition.billboard_mode = .auto_sprite2;
        }
    }
}

fn consumeStageLine(allocator: std.mem.Allocator, stage: *Stage, line: []const u8) !bool {
    var tokens = std.mem.tokenizeAny(u8, line, " \t\r");
    const keyword = tokens.next() orelse return false;

    if (std.mem.eql(u8, keyword, "map") or std.mem.eql(u8, keyword, "clampmap")) {
        const target = tokens.next() orelse return false;
        if (std.mem.eql(u8, target, "$lightmap")) {
            stage.map_kind = .lightmap;
            return true;
        }
        if (!isShaderImageTarget(target)) return false;
        if (stage.texture) |texture| allocator.free(texture);
        stage.texture = try normalizeOwned(allocator, target);
        stage.map_kind = if (std.mem.eql(u8, keyword, "clampmap")) .clampmap else .map;
        return true;
    }

    if (std.mem.eql(u8, keyword, "animmap") or std.mem.eql(u8, keyword, "oneshotanimmap")) {
        const fps_text = tokens.next() orelse return false;
        const fps = std.fmt.parseFloat(f32, fps_text) catch return false;

        for (stage.anim_frames) |frame| allocator.free(frame);
        allocator.free(stage.anim_frames);
        stage.anim_frames = &.{};
        if (stage.texture) |texture| {
            allocator.free(texture);
            stage.texture = null;
        }

        var frames: std.ArrayList([]const u8) = .empty;
        defer {
            if (frames.capacity != 0) {
                for (frames.items) |frame| allocator.free(frame);
                frames.deinit(allocator);
            }
        }

        while (tokens.next()) |frame| {
            if (!isShaderImageTarget(frame)) continue;
            try frames.append(allocator, try normalizeOwned(allocator, frame));
        }
        if (frames.items.len == 0) return false;

        stage.anim_frames = try frames.toOwnedSlice(allocator);
        frames = .empty;
        stage.fps = fps;
        stage.map_kind = if (std.mem.eql(u8, keyword, "oneshotanimmap")) .oneshotanimmap else .animmap;
        return true;
    }

    if (std.mem.eql(u8, keyword, "blendfunc") or std.mem.eql(u8, keyword, "blendFunc")) {
        if (tokens.next()) |first| {
            if (parseBlendMode(first, tokens.next())) |blend| {
                stage.blend_mode = blend;
                return true;
            }
        }
        return false;
    }

    if (std.mem.eql(u8, keyword, "alphafunc") or std.mem.eql(u8, keyword, "alphaFunc")) {
        stage.alpha_cutout = true;
        return true;
    }

    if (std.mem.eql(u8, keyword, "rgbgen") or std.mem.eql(u8, keyword, "rgbGen")) {
        const mode = tokens.next() orelse return false;
        if (std.mem.eql(u8, mode, "identity")) {
            stage.rgb_gen = .identity;
            return true;
        }
        if (std.mem.eql(u8, mode, "identitylighting") or std.mem.eql(u8, mode, "identityLighting")) {
            stage.rgb_gen = .identity_lighting;
            return true;
        }
        if (std.mem.eql(u8, mode, "vertex") or std.mem.eql(u8, mode, "exactvertex") or std.mem.eql(u8, mode, "exactVertex")) {
            stage.rgb_gen = .vertex;
            return true;
        }
        if (std.mem.eql(u8, mode, "const")) {
            stage.rgb_gen = .constant;
            stage.const_color[0] = std.fmt.parseFloat(f32, tokens.next() orelse return false) catch return false;
            stage.const_color[1] = std.fmt.parseFloat(f32, tokens.next() orelse return false) catch return false;
            stage.const_color[2] = std.fmt.parseFloat(f32, tokens.next() orelse return false) catch return false;
            return true;
        }
        return false;
    }

    if (std.mem.eql(u8, keyword, "alphagen") or std.mem.eql(u8, keyword, "alphaGen")) {
        const mode = tokens.next() orelse return false;
        if (std.mem.eql(u8, mode, "identity")) {
            stage.alpha_gen = .identity;
            return true;
        }
        if (std.mem.eql(u8, mode, "vertex")) {
            stage.alpha_gen = .vertex;
            return true;
        }
        if (std.mem.eql(u8, mode, "const")) {
            stage.alpha_gen = .constant;
            stage.const_color[3] = std.fmt.parseFloat(f32, tokens.next() orelse return false) catch return false;
            return true;
        }
        return false;
    }

    if (std.mem.eql(u8, keyword, "tcmod") or std.mem.eql(u8, keyword, "tcMod")) {
        const mode = tokens.next() orelse return false;
        if (std.mem.eql(u8, mode, "scroll")) {
            const s = std.fmt.parseFloat(f32, tokens.next() orelse return false) catch return false;
            const t = std.fmt.parseFloat(f32, tokens.next() orelse return false) catch return false;
            return appendTcMod(stage, .{ .kind = .scroll, .values = .{ s, t, 0.0, 0.0 } });
        }
        if (std.mem.eql(u8, mode, "scale")) {
            const s = std.fmt.parseFloat(f32, tokens.next() orelse return false) catch return false;
            const t = std.fmt.parseFloat(f32, tokens.next() orelse return false) catch return false;
            return appendTcMod(stage, .{ .kind = .scale, .values = .{ s, t, 0.0, 0.0 } });
        }
        if (std.mem.eql(u8, mode, "rotate")) {
            const speed = std.fmt.parseFloat(f32, tokens.next() orelse return false) catch return false;
            return appendTcMod(stage, .{ .kind = .rotate, .values = .{ speed, 0.0, 0.0, 0.0 } });
        }
        if (std.mem.eql(u8, mode, "turb")) {
            const base = std.fmt.parseFloat(f32, tokens.next() orelse return false) catch return false;
            const amplitude = std.fmt.parseFloat(f32, tokens.next() orelse return false) catch return false;
            const phase = std.fmt.parseFloat(f32, tokens.next() orelse return false) catch return false;
            const frequency = std.fmt.parseFloat(f32, tokens.next() orelse return false) catch return false;
            return appendTcMod(stage, .{ .kind = .turb, .values = .{ base, amplitude, phase, frequency } });
        }
        return false;
    }

    if (std.mem.eql(u8, keyword, "tcgen") or std.mem.eql(u8, keyword, "tcGen")) {
        const mode = tokens.next() orelse return false;
        if (std.mem.eql(u8, mode, "environment")) {
            stage.tcgen = .environment;
            return true;
        }
        return false;
    }

    return false;
}

fn appendTcMod(stage: *Stage, mod: TcMod) bool {
    if (stage.tcmod_count >= max_tcmods) return false;
    stage.tcmods[stage.tcmod_count] = mod;
    stage.tcmod_count += 1;
    return true;
}

fn trimShaderLine(raw_line: []const u8) []const u8 {
    const comment_index = std.mem.indexOf(u8, raw_line, "//") orelse raw_line.len;
    return std.mem.trim(u8, raw_line[0..comment_index], " \t\r");
}

fn isShaderImageTarget(target: []const u8) bool {
    if (target.len == 0) return false;
    if (target[0] == '$') return false;
    return true;
}

fn parseBlendMode(first: []const u8, second: ?[]const u8) ?BlendMode {
    if (std.mem.eql(u8, first, "add")) return .additive;
    if (std.mem.eql(u8, first, "blend")) return .alpha;
    if (std.mem.eql(u8, first, "filter")) return .filter;

    if (second) |rhs| {
        if ((std.mem.eql(u8, first, "GL_DST_COLOR") or std.mem.eql(u8, first, "gl_dst_color")) and
            (std.mem.eql(u8, rhs, "GL_ZERO") or std.mem.eql(u8, rhs, "gl_zero")))
        {
            return .filter;
        }
        if ((std.mem.eql(u8, first, "GL_DST_COLOR") or std.mem.eql(u8, first, "gl_dst_color")) and
            (std.mem.eql(u8, rhs, "GL_ONE") or std.mem.eql(u8, rhs, "gl_one")))
        {
            // Common on Quake 3 water/liquid shaders; multiply is a closer approximation
            // than treating it as opaque alpha in the current single-pass runtime.
            return .filter;
        }
        if ((std.mem.eql(u8, first, "GL_ONE") or std.mem.eql(u8, first, "gl_one")) and
            (std.mem.eql(u8, rhs, "GL_ONE") or std.mem.eql(u8, rhs, "gl_one")))
        {
            return .additive;
        }
        if ((std.mem.eql(u8, first, "GL_SRC_ALPHA") or std.mem.eql(u8, first, "gl_src_alpha")) and
            (std.mem.eql(u8, rhs, "GL_ONE") or std.mem.eql(u8, rhs, "gl_one")))
        {
            return .additive;
        }
        if ((std.mem.eql(u8, first, "GL_SRC_ALPHA") or std.mem.eql(u8, first, "gl_src_alpha")) and
            (std.mem.eql(u8, rhs, "GL_ONE_MINUS_SRC_ALPHA") or std.mem.eql(u8, rhs, "gl_one_minus_src_alpha")))
        {
            return .alpha;
        }
    }

    return null;
}

fn normalizeOwned(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    const owned = try allocator.dupe(u8, text);
    for (owned) |*byte| {
        if (byte.* == '\\') byte.* = '/';
        byte.* = std.ascii.toLower(byte.*);
    }
    return owned;
}

fn definitionMemoryBytes(definition: Definition) usize {
    var total: usize = 0;
    if (definition.editor_image) |editor_image| total += editor_image.len;
    total += definition.stages.len * @sizeOf(Stage);
    for (definition.stages) |stage| {
        if (stage.texture) |texture| total += texture.len;
        total += stage.anim_frames.len * @sizeOf([]const u8);
        for (stage.anim_frames) |frame| total += frame.len;
    }
    return total;
}

test "parse shader definition with animmap and material flags" {
    const source =
        \\textures/test/flame
        \\{
        \\    cull disable
        \\    surfaceparm trans
        \\    qer_editorimage textures/test/flame01.tga
        \\    {
        \\        animmap 8 textures/test/flame01.tga textures/test/flame02.tga textures/test/flame03.tga
        \\        blendfunc add
        \\    }
        \\}
    ;

    var library = Library{
        .allocator = std.testing.allocator,
        .definitions = std.StringHashMap(Definition).init(std.testing.allocator),
    };
    defer library.deinit();

    try library.parseFile(source);

    const definition = library.get("textures/test/flame") orelse return error.TestExpectedEqual;
    try std.testing.expect(definition.cull_mode == .none);
    try std.testing.expect(definition.surfaceparm_trans);
    try std.testing.expectEqualStrings("textures/test/flame01.tga", definition.editor_image.?);
    try std.testing.expectEqual(@as(usize, 1), definition.stages.len);
    try std.testing.expect(definition.stages[0].map_kind == .animmap);
    try std.testing.expect(definition.stages[0].blend_mode == .additive);
    try std.testing.expectEqual(@as(usize, 3), definition.stages[0].anim_frames.len);
    try std.testing.expectEqualStrings("textures/test/flame01.tga", definition.resolveImage(0.0).?);
    try std.testing.expectEqualStrings("textures/test/flame02.tga", definition.resolveImage(0.13).?);
}

test "parse shader stage color alpha and tcmod" {
    const source =
        \\textures/test/water
        \\{
        \\    {
        \\        map textures/test/water01.tga
        \\        rgbGen vertex
        \\        alphaGen const 0.5
        \\        tcMod scroll 0.25 -0.5
        \\        tcMod scale 2 3
        \\        tcMod rotate 45
        \\        tcMod turb 0 0.125 0 1
        \\        tcGen environment
        \\    }
        \\}
    ;

    var library = Library{
        .allocator = std.testing.allocator,
        .definitions = std.StringHashMap(Definition).init(std.testing.allocator),
    };
    defer library.deinit();

    try library.parseFile(source);

    const definition = library.get("textures/test/water") orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(@as(usize, 1), definition.stages.len);
    try std.testing.expect(definition.stages[0].rgb_gen == .vertex);
    try std.testing.expect(definition.stages[0].alpha_gen == .constant);
    try std.testing.expectEqual(@as(f32, 0.5), definition.stages[0].const_color[3]);
    try std.testing.expectEqual(@as(u8, 4), definition.stages[0].tcmod_count);
    try std.testing.expect(definition.stages[0].tcmods[0].kind == .scroll);
    try std.testing.expectEqual(@as(f32, 0.25), definition.stages[0].tcmods[0].values[0]);
    try std.testing.expectEqual(@as(f32, -0.5), definition.stages[0].tcmods[0].values[1]);
    try std.testing.expect(definition.stages[0].tcmods[1].kind == .scale);
    try std.testing.expectEqual(@as(f32, 2.0), definition.stages[0].tcmods[1].values[0]);
    try std.testing.expectEqual(@as(f32, 3.0), definition.stages[0].tcmods[1].values[1]);
    try std.testing.expect(definition.stages[0].tcmods[2].kind == .rotate);
    try std.testing.expectEqual(@as(f32, 45.0), definition.stages[0].tcmods[2].values[0]);
    try std.testing.expect(definition.stages[0].tcmods[3].kind == .turb);
    try std.testing.expectEqual(@as(f32, 0.125), definition.stages[0].tcmods[3].values[1]);
    try std.testing.expectEqual(@as(f32, 1.0), definition.stages[0].tcmods[3].values[3]);
    try std.testing.expect(definition.stages[0].tcgen == .environment);
}

test "parse shader deform autosprite mode" {
    const source =
        \\textures/test/flame
        \\{
        \\    deformVertexes autoSprite2
        \\    {
        \\        map textures/test/flame01.tga
        \\        blendfunc add
        \\    }
        \\}
    ;

    var library = Library{
        .allocator = std.testing.allocator,
        .definitions = std.StringHashMap(Definition).init(std.testing.allocator),
    };
    defer library.deinit();

    try library.parseFile(source);

    const definition = library.get("textures/test/flame") orelse return error.TestExpectedEqual;
    try std.testing.expect(definition.billboard_mode == .auto_sprite2);
}
