const std = @import("std");
const qmath = @import("math.zig");

pub const Pair = struct {
    key: []const u8,
    value: []const u8,
};

pub const Entity = struct {
    pairs: []Pair,

    pub fn deinit(self: *Entity, allocator: std.mem.Allocator) void {
        for (self.pairs) |pair| {
            allocator.free(pair.key);
            allocator.free(pair.value);
        }
        allocator.free(self.pairs);
        self.* = undefined;
    }

    pub fn get(self: *const Entity, key: []const u8) ?[]const u8 {
        for (self.pairs) |pair| {
            if (std.mem.eql(u8, pair.key, key)) return pair.value;
        }
        return null;
    }

    pub fn classname(self: *const Entity) ?[]const u8 {
        return self.get("classname");
    }

    pub fn model(self: *const Entity) ?[]const u8 {
        return self.get("model");
    }

    pub fn target(self: *const Entity) ?[]const u8 {
        return self.get("target");
    }

    pub fn targetname(self: *const Entity) ?[]const u8 {
        return self.get("targetname");
    }

    pub fn origin(self: *const Entity) ?qmath.Vec3 {
        return parseVec3(self.get("origin") orelse return null);
    }

    pub fn angles(self: *const Entity) ?qmath.Vec3 {
        return parseVec3(self.get("angles") orelse return null);
    }
};

pub const EntityList = struct {
    allocator: std.mem.Allocator,
    items: []Entity,

    pub fn deinit(self: *EntityList) void {
        for (self.items) |*entity| entity.deinit(self.allocator);
        self.allocator.free(self.items);
        self.* = undefined;
    }

    pub fn firstByClassname(self: *const EntityList, classname: []const u8) ?*const Entity {
        for (self.items) |*entity| {
            if (entity.classname()) |value| {
                if (std.mem.eql(u8, value, classname)) return entity;
            }
        }
        return null;
    }
};

pub fn parse(allocator: std.mem.Allocator, source: []const u8) !EntityList {
    var parser = Parser{ .allocator = allocator, .source = source };
    var entities: std.ArrayList(Entity) = .empty;
    errdefer {
        for (entities.items) |*entity| entity.deinit(allocator);
        entities.deinit(allocator);
    }

    while (true) {
        parser.skipWhitespace();
        if (parser.eof()) break;

        try parser.expect('{');
        var pairs: std.ArrayList(Pair) = .empty;
        errdefer {
            for (pairs.items) |pair| {
                allocator.free(pair.key);
                allocator.free(pair.value);
            }
            pairs.deinit(allocator);
        }

        while (true) {
            parser.skipWhitespace();
            if (parser.eof()) return error.UnexpectedEndOfInput;
            if (parser.peek() == '}') {
                parser.index += 1;
                break;
            }

            const key = try parser.parseQuoted();
            parser.skipWhitespace();
            const value = try parser.parseQuoted();
            pairs.append(allocator, .{ .key = key, .value = value }) catch |err| {
                allocator.free(key);
                allocator.free(value);
                return err;
            };
        }

        const entity_pairs = try pairs.toOwnedSlice(allocator);
        errdefer {
            for (entity_pairs) |pair| {
                allocator.free(pair.key);
                allocator.free(pair.value);
            }
            allocator.free(entity_pairs);
        }

        try entities.append(allocator, .{ .pairs = entity_pairs });
    }

    return .{
        .allocator = allocator,
        .items = try entities.toOwnedSlice(allocator),
    };
}

const Parser = struct {
    allocator: std.mem.Allocator,
    source: []const u8,
    index: usize = 0,

    fn eof(self: *const Parser) bool {
        return self.index >= self.source.len;
    }

    fn peek(self: *const Parser) u8 {
        return self.source[self.index];
    }

    fn skipWhitespace(self: *Parser) void {
        while (!self.eof()) {
            const ch = self.source[self.index];
            if (ch == 0 or std.ascii.isWhitespace(ch)) {
                self.index += 1;
                continue;
            }

            if (ch == '/' and self.index + 1 < self.source.len) {
                const next = self.source[self.index + 1];
                if (next == '/') {
                    self.index += 2;
                    while (!self.eof() and self.source[self.index] != '\n') : (self.index += 1) {}
                    continue;
                }
                if (next == '*') {
                    self.index += 2;
                    while (self.index + 1 < self.source.len) : (self.index += 1) {
                        if (self.source[self.index] == '*' and self.source[self.index + 1] == '/') {
                            self.index += 2;
                            break;
                        }
                    }
                    continue;
                }
            }

            break;
        }
    }

    fn expect(self: *Parser, byte: u8) !void {
        self.skipWhitespace();
        if (self.eof() or self.source[self.index] != byte) return error.UnexpectedToken;
        self.index += 1;
    }

    fn parseQuoted(self: *Parser) ![]const u8 {
        self.skipWhitespace();
        try self.expect('"');

        const start = self.index;
        while (!self.eof() and self.source[self.index] != '"') : (self.index += 1) {}
        if (self.eof()) return error.UnexpectedEndOfInput;

        const value = try self.allocator.dupe(u8, self.source[start..self.index]);
        self.index += 1;
        return value;
    }
};

fn parseVec3(text: []const u8) ?qmath.Vec3 {
    var parts = std.mem.tokenizeAny(u8, text, " \t\r\n");
    const x_text = parts.next() orelse return null;
    const y_text = parts.next() orelse return null;
    const z_text = parts.next() orelse return null;
    if (parts.next() != null) return null;

    const x = std.fmt.parseFloat(f32, x_text) catch return null;
    const y = std.fmt.parseFloat(f32, y_text) catch return null;
    const z = std.fmt.parseFloat(f32, z_text) catch return null;
    return .{ .x = x, .y = y, .z = z };
}
