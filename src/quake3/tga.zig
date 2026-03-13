const std = @import("std");

pub const DecodedImage = struct {
    pixels: []u8,
    width: u16,
    height: u16,
};

const Header = extern struct {
    id_length: u8 align(1),
    color_map_type: u8 align(1),
    image_type: u8 align(1),
    color_map_origin: u16 align(1),
    color_map_length: u16 align(1),
    color_map_depth: u8 align(1),
    x_origin: u16 align(1),
    y_origin: u16 align(1),
    width: u16 align(1),
    height: u16 align(1),
    pixel_depth: u8 align(1),
    image_descriptor: u8 align(1),
};

pub fn decode(allocator: std.mem.Allocator, bytes: []const u8) !DecodedImage {
    if (bytes.len < @sizeOf(Header)) return error.InvalidTga;

    var reader = std.Io.Reader.fixed(bytes);
    const header = try reader.takeStruct(Header, .little);

    if (header.color_map_type != 0) return error.UnsupportedTga;
    if (header.width == 0 or header.height == 0) return error.InvalidTga;
    if (header.image_type != 2 and header.image_type != 3 and header.image_type != 10 and header.image_type != 11) {
        return error.UnsupportedTga;
    }
    if (header.pixel_depth != 8 and header.pixel_depth != 24 and header.pixel_depth != 32) {
        return error.UnsupportedTga;
    }
    if ((header.image_type == 2 or header.image_type == 10) and header.pixel_depth == 8) {
        return error.UnsupportedTga;
    }
    if ((header.image_type == 3 or header.image_type == 11) and header.pixel_depth != 8) {
        return error.UnsupportedTga;
    }

    const bytes_per_pixel: usize = header.pixel_depth / 8;
    var offset: usize = @sizeOf(Header) + header.id_length;
    if (offset > bytes.len) return error.InvalidTga;

    const pixel_count: usize = @as(usize, header.width) * @as(usize, header.height);
    const pixels = try allocator.alloc(u8, pixel_count * 4);
    errdefer allocator.free(pixels);

    const top_origin = (header.image_descriptor & 0x20) != 0;
    const right_origin = (header.image_descriptor & 0x10) != 0;

    switch (header.image_type) {
        2, 3 => {
            var pixel_index: usize = 0;
            while (pixel_index < pixel_count) : (pixel_index += 1) {
                if (offset + bytes_per_pixel > bytes.len) return error.InvalidTga;
                writePixel(
                    pixels,
                    destinationIndex(pixel_index, header.width, header.height, top_origin, right_origin),
                    bytes[offset .. offset + bytes_per_pixel],
                );
                offset += bytes_per_pixel;
            }
        },
        10, 11 => {
            var pixel_index: usize = 0;
            while (pixel_index < pixel_count) {
                if (offset >= bytes.len) return error.InvalidTga;
                const packet = bytes[offset];
                offset += 1;
                const run_length: usize = (packet & 0x7f) + 1;

                if ((packet & 0x80) != 0) {
                    if (offset + bytes_per_pixel > bytes.len) return error.InvalidTga;
                    const sample = bytes[offset .. offset + bytes_per_pixel];
                    offset += bytes_per_pixel;
                    var run: usize = 0;
                    while (run < run_length and pixel_index < pixel_count) : (run += 1) {
                        writePixel(
                            pixels,
                            destinationIndex(pixel_index, header.width, header.height, top_origin, right_origin),
                            sample,
                        );
                        pixel_index += 1;
                    }
                } else {
                    var run: usize = 0;
                    while (run < run_length and pixel_index < pixel_count) : (run += 1) {
                        if (offset + bytes_per_pixel > bytes.len) return error.InvalidTga;
                        writePixel(
                            pixels,
                            destinationIndex(pixel_index, header.width, header.height, top_origin, right_origin),
                            bytes[offset .. offset + bytes_per_pixel],
                        );
                        offset += bytes_per_pixel;
                        pixel_index += 1;
                    }
                }
            }
        },
        else => unreachable,
    }

    return .{
        .pixels = pixels,
        .width = header.width,
        .height = header.height,
    };
}

fn destinationIndex(pixel_index: usize, width: u16, height: u16, top_origin: bool, right_origin: bool) usize {
    const width_usize: usize = width;
    const height_usize: usize = height;
    var x = pixel_index % width_usize;
    var y = pixel_index / width_usize;

    if (!top_origin) y = height_usize - 1 - y;
    if (right_origin) x = width_usize - 1 - x;

    return (y * width_usize + x) * 4;
}

fn writePixel(output: []u8, dest_index: usize, src: []const u8) void {
    switch (src.len) {
        1 => {
            output[dest_index + 0] = src[0];
            output[dest_index + 1] = src[0];
            output[dest_index + 2] = src[0];
            output[dest_index + 3] = 255;
        },
        3 => {
            output[dest_index + 0] = src[2];
            output[dest_index + 1] = src[1];
            output[dest_index + 2] = src[0];
            output[dest_index + 3] = 255;
        },
        4 => {
            output[dest_index + 0] = src[2];
            output[dest_index + 1] = src[1];
            output[dest_index + 2] = src[0];
            output[dest_index + 3] = src[3];
        },
        else => unreachable,
    }
}
