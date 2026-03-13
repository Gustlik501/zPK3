const std = @import("std");

const zip = std.zip;

pub const MapRef = struct {
    archive_index: usize,
    path: []const u8,
};

const EntryInfo = struct {
    zip_entry: zip.Iterator.Entry,
};

pub const Pk3Archive = struct {
    allocator: std.mem.Allocator,
    path: []const u8,
    file: std.fs.File,
    entries: std.StringHashMap(EntryInfo),

    pub fn init(allocator: std.mem.Allocator, path: []const u8) !Pk3Archive {
        const file = try std.fs.cwd().openFile(path, .{});
        errdefer file.close();

        var archive = Pk3Archive{
            .allocator = allocator,
            .path = try allocator.dupe(u8, path),
            .file = file,
            .entries = std.StringHashMap(EntryInfo).init(allocator),
        };
        errdefer archive.deinit();

        try archive.indexEntries();
        return archive;
    }

    pub fn deinit(self: *Pk3Archive) void {
        var it = self.entries.keyIterator();
        while (it.next()) |key| {
            self.allocator.free(key.*);
        }
        self.entries.deinit();
        self.file.close();
        self.allocator.free(self.path);
        self.* = undefined;
    }

    pub fn contains(self: *const Pk3Archive, raw_path: []const u8) bool {
        const normalized = normalizePath(self.allocator, raw_path) catch return false;
        defer self.allocator.free(normalized);
        return self.entries.contains(normalized);
    }

    pub fn getCanonicalPath(self: *const Pk3Archive, raw_path: []const u8) ?[]const u8 {
        const normalized = normalizePath(self.allocator, raw_path) catch return null;
        defer self.allocator.free(normalized);
        return self.entries.getKey(normalized);
    }

    pub fn readFileAlloc(self: *Pk3Archive, allocator: std.mem.Allocator, raw_path: []const u8) ![]u8 {
        const normalized = try normalizePath(self.allocator, raw_path);
        defer self.allocator.free(normalized);

        const info = self.entries.get(normalized) orelse return error.FileNotFound;
        return self.readZipEntryAlloc(allocator, info.zip_entry);
    }

    pub fn findFirstMap(self: *const Pk3Archive) ?[]const u8 {
        var best: ?[]const u8 = null;
        var it = self.entries.keyIterator();
        while (it.next()) |key| {
            if (!std.mem.endsWith(u8, key.*, ".bsp")) continue;
            if (!std.mem.startsWith(u8, key.*, "maps/")) continue;
            if (best == null or std.mem.order(u8, key.*, best.?) == .lt) {
                best = key.*;
            }
        }
        return best;
    }

    fn indexEntries(self: *Pk3Archive) !void {
        var reader_buf: [4096]u8 = undefined;
        var reader = self.file.reader(&reader_buf);
        var iter = try zip.Iterator.init(&reader);

        while (try iter.next()) |entry| {
            const header_offset = entry.header_zip_offset + @sizeOf(zip.CentralDirectoryFileHeader);
            try reader.seekTo(header_offset);

            const raw_name = try self.allocator.alloc(u8, entry.filename_len);
            errdefer self.allocator.free(raw_name);
            try reader.interface.readSliceAll(raw_name);

            normalizePathInPlace(raw_name);
            try self.entries.put(raw_name, .{ .zip_entry = entry });
        }
    }

    fn readZipEntryAlloc(self: *Pk3Archive, allocator: std.mem.Allocator, entry: zip.Iterator.Entry) ![]u8 {
        const local_data_header_offset = try self.readLocalDataHeaderOffset(entry);
        const file_offset =
            entry.file_offset +
            @as(u64, @sizeOf(zip.LocalFileHeader)) +
            local_data_header_offset;

        const output = try allocator.alloc(u8, @intCast(entry.uncompressed_size));
        errdefer allocator.free(output);

        var reader_buf: [4096]u8 = undefined;
        var reader = self.file.reader(&reader_buf);
        try reader.seekTo(file_offset);

        switch (entry.compression_method) {
            .store => {
                try reader.interface.readSliceAll(output);
            },
            .deflate => {
                var flate_buffer: [std.compress.flate.max_window_len]u8 = undefined;
                var decompress = std.compress.flate.Decompress.init(&reader.interface, .raw, &flate_buffer);
                try decompress.reader.readSliceAll(output);
            },
            else => return error.UnsupportedCompressionMethod,
        }

        return output;
    }

    fn readLocalDataHeaderOffset(self: *Pk3Archive, entry: zip.Iterator.Entry) !u64 {
        var reader_buf: [4096]u8 = undefined;
        var reader = self.file.reader(&reader_buf);
        try reader.seekTo(entry.file_offset);

        const local_header = try reader.interface.takeStruct(zip.LocalFileHeader, .little);
        if (!std.mem.eql(u8, &local_header.signature, &zip.local_file_header_sig)) {
            return error.BadLocalFileHeader;
        }

        var extents = EntryExtents{
            .compressed_size = local_header.compressed_size,
            .uncompressed_size = local_header.uncompressed_size,
        };

        if (local_header.extra_len > 0) {
            const extra = try self.allocator.alloc(u8, local_header.extra_len);
            defer self.allocator.free(extra);

            try reader.seekTo(entry.file_offset + @sizeOf(zip.LocalFileHeader) + local_header.filename_len);
            try reader.interface.readSliceAll(extra);
            try applyZip64Extra(local_header, extra, &extents);
        }

        if (extents.compressed_size != 0 and extents.compressed_size != entry.compressed_size) {
            return error.ZipCompressedSizeMismatch;
        }
        if (extents.uncompressed_size != 0 and extents.uncompressed_size != entry.uncompressed_size) {
            return error.ZipUncompressedSizeMismatch;
        }

        return @as(u64, local_header.filename_len) + @as(u64, local_header.extra_len);
    }
};

pub const Pk3Collection = struct {
    allocator: std.mem.Allocator,
    archives: []Pk3Archive,

    pub fn initFromPath(allocator: std.mem.Allocator, source_path: []const u8) !Pk3Collection {
        const cwd = std.fs.cwd();
        var dir = cwd.openDir(source_path, .{ .iterate = true }) catch |err| switch (err) {
            error.NotDir => return initFromFile(allocator, source_path),
            else => return err,
        };
        defer dir.close();

        var names: std.ArrayList([]const u8) = .empty;
        defer {
            for (names.items) |name| allocator.free(name);
            names.deinit(allocator);
        }

        var walker = dir.iterate();
        while (try walker.next()) |entry| {
            if (entry.kind != .file) continue;
            if (!std.mem.endsWith(u8, entry.name, ".pk3")) continue;
            try names.append(allocator, try std.fs.path.join(allocator, &.{ source_path, entry.name }));
        }

        std.mem.sort([]const u8, names.items, {}, struct {
            fn lessThan(_: void, lhs: []const u8, rhs: []const u8) bool {
                const lhs_key = sortKey(lhs);
                const rhs_key = sortKey(rhs);

                if (lhs_key.is_base_pak != rhs_key.is_base_pak) {
                    return lhs_key.is_base_pak;
                }
                if (lhs_key.is_base_pak and lhs_key.pak_number != rhs_key.pak_number) {
                    return lhs_key.pak_number < rhs_key.pak_number;
                }
                return std.mem.order(u8, lhs_key.basename, rhs_key.basename) == .lt;
            }
        }.lessThan);

        var archives = try allocator.alloc(Pk3Archive, names.items.len);
        errdefer allocator.free(archives);

        var built: usize = 0;
        errdefer {
            for (archives[0..built]) |*archive| archive.deinit();
        }

        for (names.items, 0..) |name, index| {
            archives[index] = try Pk3Archive.init(allocator, name);
            built += 1;
        }

        return .{ .allocator = allocator, .archives = archives };
    }

    pub fn deinit(self: *Pk3Collection) void {
        for (self.archives) |*archive| archive.deinit();
        self.allocator.free(self.archives);
        self.* = undefined;
    }

    pub fn findFirstMap(self: *const Pk3Collection) ?MapRef {
        var archive_index = self.archives.len;
        while (archive_index > 0) : (archive_index -= 1) {
            const index = archive_index - 1;
            if (self.archives[index].findFirstMap()) |path| {
                return .{ .archive_index = index, .path = path };
            }
        }
        return null;
    }

    pub fn findMap(self: *const Pk3Collection, raw_path: []const u8) ?MapRef {
        var archive_index = self.archives.len;
        while (archive_index > 0) : (archive_index -= 1) {
            const index = archive_index - 1;
            if (self.archives[index].getCanonicalPath(raw_path)) |path| {
                return .{ .archive_index = index, .path = path };
            }
        }
        return null;
    }

    pub fn readFileAlloc(self: *Pk3Collection, allocator: std.mem.Allocator, raw_path: []const u8) ![]u8 {
        var archive_index = self.archives.len;
        while (archive_index > 0) : (archive_index -= 1) {
            const index = archive_index - 1;
            if (self.archives[index].contains(raw_path)) {
                return self.archives[index].readFileAlloc(allocator, raw_path);
            }
        }
        return error.FileNotFound;
    }

    pub fn collectFilesWithSuffixAlloc(self: *const Pk3Collection, allocator: std.mem.Allocator, suffix: []const u8) ![][]const u8 {
        var files: std.ArrayList([]const u8) = .empty;
        defer {
            if (@errorReturnTrace()) |_| {
                for (files.items) |file| allocator.free(file);
                files.deinit(allocator);
            }
        }

        for (self.archives) |*archive_item| {
            var it = archive_item.entries.keyIterator();
            while (it.next()) |key| {
                if (!std.mem.endsWith(u8, key.*, suffix)) continue;
                try files.append(allocator, try allocator.dupe(u8, key.*));
            }
        }

        return files.toOwnedSlice(allocator);
    }

    fn initFromFile(allocator: std.mem.Allocator, source_path: []const u8) !Pk3Collection {
        var archives = try allocator.alloc(Pk3Archive, 1);
        errdefer allocator.free(archives);
        archives[0] = try Pk3Archive.init(allocator, source_path);
        return .{ .allocator = allocator, .archives = archives };
    }
};

const EntryExtents = struct {
    compressed_size: u64,
    uncompressed_size: u64,
};

fn normalizePath(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const normalized = try allocator.dupe(u8, path);
    normalizePathInPlace(normalized);
    return normalized;
}

fn normalizePathInPlace(path: []u8) void {
    for (path) |*byte| {
        if (byte.* == '\\') byte.* = '/';
        byte.* = std.ascii.toLower(byte.*);
    }
}

fn applyZip64Extra(header: zip.LocalFileHeader, extra: []const u8, extents: *EntryExtents) !void {
    var offset: usize = 0;
    while (offset + 4 <= extra.len) {
        const header_id = std.mem.readInt(u16, extra[offset..][0..2], .little);
        const data_size = std.mem.readInt(u16, extra[offset + 2 ..][0..2], .little);
        const end = offset + 4 + data_size;
        if (end > extra.len) return error.BadZipExtraField;

        if (header_id == @intFromEnum(zip.ExtraHeader.zip64_info)) {
            const data = extra[offset + 4 .. end];
            var cursor: usize = 0;
            if (header.uncompressed_size == std.math.maxInt(u32)) {
                if (cursor + 8 > data.len) return error.BadZip64Extra;
                extents.uncompressed_size = std.mem.readInt(u64, data[cursor..][0..8], .little);
                cursor += 8;
            }
            if (header.compressed_size == std.math.maxInt(u32)) {
                if (cursor + 8 > data.len) return error.BadZip64Extra;
                extents.compressed_size = std.mem.readInt(u64, data[cursor..][0..8], .little);
            }
        }

        offset = end;
    }
}

const SortKey = struct {
    is_base_pak: bool,
    pak_number: u32,
    basename: []const u8,
};

fn sortKey(path: []const u8) SortKey {
    const basename = std.fs.path.basename(path);
    if (std.mem.startsWith(u8, basename, "pak") and std.mem.endsWith(u8, basename, ".pk3")) {
        var index: usize = 3;
        var pak_number: u32 = 0;
        var saw_digit = false;
        while (index < basename.len) : (index += 1) {
            const ch = basename[index];
            if (!std.ascii.isDigit(ch)) break;
            saw_digit = true;
            pak_number = pak_number * 10 + (ch - '0');
        }
        if (saw_digit) {
            return .{
                .is_base_pak = true,
                .pak_number = pak_number,
                .basename = basename,
            };
        }
    }

    return .{
        .is_base_pak = false,
        .pak_number = 0,
        .basename = basename,
    };
}
