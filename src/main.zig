const builtin = @import("builtin");
const std = @import("std");

const clap = @import("clap");

const Allocator = std.mem.Allocator;

const ZIG_DOWNLOAD_INDEX_URL = "https://ziglang.org/download/index.json";
const MASTER_INDEX = "master";
const CURRENT_PLATFORM = @tagName(builtin.cpu.arch) ++ "-" ++ @tagName(builtin.os.tag);

const DefaultAllocator = struct {
    backing_allocator: if (need_debug_allocator) std.heap.DebugAllocator(.{}) else Allocator,

    const need_debug_allocator = builtin.mode == .Debug or builtin.single_threaded;
    const Self = @This();

    fn init() Self {
        return .{
            .backing_allocator = if (need_debug_allocator) .init else std.heap.smp_allocator,
        };
    }

    fn allocator(self: *Self) Allocator {
        return if (need_debug_allocator) self.backing_allocator.allocator() else self.backing_allocator;
    }

    fn deinit(self: *Self) void {
        if (need_debug_allocator) {
            _ = self.backing_allocator.deinit();
        }
    }
};

const Resource = struct {
    tarball: std.Uri,
    shasum: []const u8,
    size: usize,
};

fn fetch(allocator: Allocator, http_client: *std.http.Client, url: []const u8) ![]const u8 {
    var response = std.ArrayList(u8).init(allocator);
    errdefer response.deinit();

    const fetch_res = try http_client.fetch(.{
        .location = .{ .url = url },
        .response_storage = .{ .dynamic = &response },
    });

    const status_class = fetch_res.status.class();
    if (status_class == .client_error or status_class == .server_error) {
        return error.FetchFailed;
    }

    return response.toOwnedSlice();
}

const ZigTarball = struct {
    resource: Resource,
    version: []const u8,
};

fn getNextFieldName(arena: Allocator, scanner: *std.json.Scanner) !?[]const u8 {
    while (true) {
        const next_token_type = try scanner.peekNextTokenType();
        switch (next_token_type) {
            .string => break,
            .object_end, .end_of_document => return null,
            else => {
                try scanner.skipValue();
            },
        }
    }

    const name_token = try scanner.nextAlloc(arena, .alloc_if_needed);
    const field_name = switch (name_token) {
        inline .string, .allocated_string => |slice| slice,
        else => {
            return error.UnexpectedToken;
        },
    };
    return field_name;
}

fn getZigTarball(
    arena: Allocator,
    http_client: *std.http.Client,
    version: []const u8,
    target: []const u8,
) !ZigTarball {
    const resp = try fetch(arena, http_client, ZIG_DOWNLOAD_INDEX_URL);

    var res: ZigTarball = undefined;
    var scanner = std.json.Scanner.initCompleteInput(arena, resp);
    if (.object_begin != try scanner.next()) return error.UnexpectedToken;
    const default_options: std.json.ParseOptions = .{
        .allocate = .alloc_if_needed,
        .max_value_len = std.json.default_max_value_len,
    };
    var found_version = false;
    while (true) {
        const version_field = (try getNextFieldName(arena, &scanner)) orelse break;
        if (std.ascii.eqlIgnoreCase(version_field, version)) {
            if (.object_begin != try scanner.next()) return error.UnexpectedToken;

            while (true) {
                const field_name = (try getNextFieldName(arena, &scanner)) orelse break;
                if (std.ascii.eqlIgnoreCase(field_name, "version")) {
                    res.version = try std.json.innerParse(
                        []const u8,
                        arena,
                        &scanner,
                        default_options,
                    );
                    found_version = true;
                    continue;
                }
                if (std.ascii.eqlIgnoreCase(field_name, target)) {
                    const resource = try std.json.innerParse(
                        struct {
                            tarball: []const u8,
                            shasum: []const u8,
                            size: []const u8,
                        },
                        arena,
                        &scanner,
                        default_options,
                    );
                    res.resource.tarball = try std.Uri.parse(resource.tarball);
                    res.resource.shasum = resource.shasum;
                    res.resource.size = try std.fmt.parseInt(usize, resource.size, 10);
                    continue;
                }
            }

            if (!found_version) {
                res.version = version_field;
            }

            break;
        }
    }

    return res;
}

fn needsToUpdateZig(arena: Allocator, current_exe: []const u8, remote_version: []const u8) !bool {
    const res = std.process.Child.run(.{
        .allocator = arena,
        .argv = &.{
            current_exe,
            "version",
        },
    }) catch |err| {
        if (err == error.FileNotFound) return true;
        return err;
    };

    const current_version = std.mem.trim(u8, res.stdout, &std.ascii.whitespace);
    return !std.ascii.eqlIgnoreCase(current_version, remote_version);
}

const FileType = enum {
    tar,
    @"tar.gz",
    @"tar.xz",
    @"tar.zst",
    zip,

    fn fromPath(file_path: []const u8) ?FileType {
        if (std.ascii.endsWithIgnoreCase(file_path, ".tar")) return .tar;
        if (std.ascii.endsWithIgnoreCase(file_path, ".tgz")) return .@"tar.gz";
        if (std.ascii.endsWithIgnoreCase(file_path, ".tar.gz")) return .@"tar.gz";
        if (std.ascii.endsWithIgnoreCase(file_path, ".txz")) return .@"tar.xz";
        if (std.ascii.endsWithIgnoreCase(file_path, ".tar.xz")) return .@"tar.xz";
        if (std.ascii.endsWithIgnoreCase(file_path, ".tzst")) return .@"tar.zst";
        if (std.ascii.endsWithIgnoreCase(file_path, ".tar.zst")) return .@"tar.zst";
        if (std.ascii.endsWithIgnoreCase(file_path, ".zip")) return .zip;
        if (std.ascii.endsWithIgnoreCase(file_path, ".jar")) return .zip;
        return null;
    }

    /// Parameter is a content-disposition header value.
    fn fromContentDisposition(cd_header: []const u8) ?FileType {
        const attach_end = std.ascii.indexOfIgnoreCase(cd_header, "attachment;") orelse
            return null;

        var value_start = std.ascii.indexOfIgnoreCasePos(cd_header, attach_end + 1, "filename") orelse
            return null;
        value_start += "filename".len;
        if (cd_header[value_start] == '*') {
            value_start += 1;
        }
        if (cd_header[value_start] != '=') return null;
        value_start += 1;

        var value_end = std.mem.indexOfPos(u8, cd_header, value_start, ";") orelse cd_header.len;
        if (cd_header[value_end - 1] == '\"') {
            value_end -= 1;
        }
        return fromPath(cd_header[value_start..value_end]);
    }

    fn asExtension(self: @This()) []const u8 {
        return switch (self) {
            .tar => "." ++ @tagName(.tar),
            .@"tar.gz" => "." ++ @tagName(.@"tar.gz"),
            .@"tar.xz" => "." ++ @tagName(.@"tar.xz"),
            .@"tar.zst" => "." ++ @tagName(.@"tar.zst"),
            .zip => "." ++ @tagName(.zip),
        };
    }
};

fn getFileTypeFromReq(req: *const std.http.Client.Request, uri_path: []const u8) !FileType {
    const content_type = req.response.content_type orelse return error.ContentTypeMissing;

    const mime_type_end = std.mem.indexOf(u8, content_type, ";") orelse content_type.len;
    const mime_type = content_type[0..mime_type_end];

    if (std.ascii.eqlIgnoreCase(mime_type, "application/x-tar"))
        return .tar;

    if (std.ascii.eqlIgnoreCase(mime_type, "application/gzip") or
        std.ascii.eqlIgnoreCase(mime_type, "application/x-gzip") or
        std.ascii.eqlIgnoreCase(mime_type, "application/tar+gzip") or
        std.ascii.eqlIgnoreCase(mime_type, "application/x-tar-gz") or
        std.ascii.eqlIgnoreCase(mime_type, "application/x-gtar-compressed"))
    {
        return .@"tar.gz";
    }

    if (std.ascii.eqlIgnoreCase(mime_type, "application/x-xz"))
        return .@"tar.xz";

    if (std.ascii.eqlIgnoreCase(mime_type, "application/zstd"))
        return .@"tar.zst";

    if (std.ascii.eqlIgnoreCase(mime_type, "application/zip") or
        std.ascii.eqlIgnoreCase(mime_type, "application/x-zip-compressed") or
        std.ascii.eqlIgnoreCase(mime_type, "application/java-archive"))
    {
        return .zip;
    }

    if (!std.ascii.eqlIgnoreCase(mime_type, "application/octet-stream") and
        !std.ascii.eqlIgnoreCase(mime_type, "application/x-compressed"))
    {
        return error.UnknownContentType;
    }

    if (req.response.content_disposition) |cd_header| {
        return FileType.fromContentDisposition(cd_header) orelse error.UnknownFileType;
    }

    return FileType.fromPath(uri_path) orelse error.UnknownFileType;
}

fn unpackTarball(arena: Allocator, out_dir: std.fs.Dir, reader: anytype) !void {
    var diagnostics: std.tar.Diagnostics = .{ .allocator = arena };

    try std.tar.pipeToFileSystem(out_dir, reader, .{
        .diagnostics = &diagnostics,
        .strip_components = 0,
        .exclude_empty_directories = true,
    });

    if (diagnostics.errors.items.len > 0) {
        for (diagnostics.errors.items) |item| {
            switch (item) {
                .unable_to_create_file => |i| {
                    std.debug.print("Unable to create file({}): {s}\n", .{ i.code, i.file_name });
                },
                .unable_to_create_sym_link => |i| {
                    std.debug.print("Unable to create symlink({}): {s} as {s}\n", .{ i.code, i.file_name, i.link_name });
                },
                .unsupported_file_type => |i| {
                    std.debug.print("Unsupported file type: {s} type: {}\n", .{ i.file_name, @intFromEnum(i.file_type) });
                },
                .components_outside_stripped_prefix => unreachable, // unreachable with strip_components = 0
            }
        }
        return error.UnpackTarFailed;
    }
}

fn unzip(arena: Allocator, out_dir: std.fs.Dir, reader: anytype) !void {
    const cache_root = out_dir;

    const prefix = "./tmp_";
    const suffix = ".zip";

    const random_bytes_count = 20;
    const random_path_len = comptime std.fs.base64_encoder.calcSize(random_bytes_count);
    var zip_path: [prefix.len + random_path_len + suffix.len]u8 = undefined;
    @memcpy(zip_path[0..prefix.len], prefix);
    @memcpy(zip_path[prefix.len + random_path_len ..], suffix);
    {
        var random_bytes: [random_bytes_count]u8 = undefined;
        std.crypto.random.bytes(&random_bytes);
        _ = std.fs.base64_encoder.encode(
            zip_path[prefix.len..][0..random_path_len],
            &random_bytes,
        );
    }

    defer cache_root.deleteFile(&zip_path) catch {};

    {
        var zip_file = try cache_root.createFile(&zip_path, .{});
        defer zip_file.close();
        var buf: [4096]u8 = undefined;
        while (true) {
            const len = try reader.readAll(&buf);
            if (len == 0) break;
            // TODO: adapt to new std.Io.Writer.
            if (@hasDecl(@TypeOf(zip_file), "deprecatedWriter")) {
                try zip_file.deprecatedWriter().writeAll(buf[0..len]);
            } else {
                try zip_file.writer().writeAll(buf[0..len]);
            }
        }
    }

    var diagnostics: std.zip.Diagnostics = .{ .allocator = arena };

    {
        var zip_file = try cache_root.openFile(&zip_path, .{});
        defer zip_file.close();

        try std.zip.extract(out_dir, zip_file.seekableStream(), .{
            .allow_backslashes = true,
            .diagnostics = &diagnostics,
        });
    }

    try cache_root.deleteFile(&zip_path);
}

fn existingZigTarballDir(
    arena: Allocator,
    expected_extract_dir: []const u8,
    tarball: ZigTarball,
    out_dir: std.fs.Dir,
) ?std.fs.Dir {
    var need_to_close_dir = blk: {
        const dir = out_dir.openDir(expected_extract_dir, .{}) catch return null;
        const zig_file = if (std.ascii.indexOfIgnoreCase(expected_extract_dir, "windows") != null) "zig.exe" else "zig";
        const path = dir.realpathAlloc(arena, zig_file) catch break :blk dir;
        const need_update = needsToUpdateZig(arena, path, tarball.version) catch break :blk dir;
        if (!need_update) {
            return dir;
        }
        break :blk dir;
    };
    need_to_close_dir.close();
    return null;
}

const header_buffer_size = 16 * 1024;
fn downloadAndExtractZigTarball(
    arena: Allocator,
    http_client: *std.http.Client,
    tarball: ZigTarball,
    out_dir: std.fs.Dir,
) !std.fs.Dir {
    var server_header_buffer: [header_buffer_size]u8 = undefined;
    var req = try http_client.open(.GET, tarball.resource.tarball, .{
        .server_header_buffer = &server_header_buffer,
    });
    defer req.deinit();
    try req.send();
    try req.wait();
    if (req.response.status != .ok) {
        return error.DownloadFailed;
    }

    const uri_path = try tarball.resource.tarball.path.toRawMaybeAlloc(arena);
    const file_type = try getFileTypeFromReq(&req, uri_path);

    const filename = std.fs.path.basename(uri_path);
    const ext = file_type.asExtension();
    const expected_extract_dir = filename[0 .. filename.len - ext.len];
    std.log.info("Downloading and extracting `{s}`...", .{filename});
    // deleting the default extracted dir if exists...
    if (existingZigTarballDir(arena, expected_extract_dir, tarball, out_dir)) |dir| {
        return dir;
    } else {
        out_dir.deleteDir(expected_extract_dir) catch {};
    }

    switch (file_type) {
        .tar => try unpackTarball(arena, out_dir, req.reader()),
        .@"tar.gz" => {
            const reader = req.reader();
            var br = std.io.bufferedReaderSize(std.crypto.tls.max_ciphertext_record_len, reader);
            var dcp = std.compress.gzip.decompressor(br.reader());
            try unpackTarball(arena, out_dir, dcp.reader());
        },
        .@"tar.xz" => {
            const reader = req.reader();
            var br = std.io.bufferedReaderSize(std.crypto.tls.max_ciphertext_record_len, reader);
            var dcp = try std.compress.xz.decompress(arena, br.reader());
            defer dcp.deinit();
            try unpackTarball(arena, out_dir, dcp.reader());
        },
        .@"tar.zst" => {
            const window_size = std.compress.zstd.DecompressorOptions.default_window_buffer_len;
            const window_buffer = try arena.create([window_size]u8);
            const reader = req.reader();
            var br = std.io.bufferedReaderSize(std.crypto.tls.max_ciphertext_record_len, reader);
            var dcp = std.compress.zstd.decompressor(br.reader(), .{
                .window_buffer = window_buffer,
            });
            try unpackTarball(arena, out_dir, dcp.reader());
        },
        .zip => try unzip(arena, out_dir, req.reader()),
    }

    return out_dir.openDir(expected_extract_dir, .{});
}

const Target = struct {
    zig_version: []const u8 = MASTER_INDEX,
    platform: []const u8 = CURRENT_PLATFORM,
};

fn getTarget(arena: Allocator) !Target {
    var args = try std.process.argsWithAllocator(arena);
    defer args.deinit();
    if (!args.skip()) return .{};

    var target: Target = .{};

    var expecting_version = false;
    var expecting_target = false;
    var should_print_help = false;

    while (args.next()) |arg| {
        if (expecting_version) {
            target.zig_version = try arena.dupe(u8, arg);
            expecting_version = false;
            continue;
        }

        if (expecting_target) {
            target.platform = try arena.dupe(u8, arg);
            expecting_target = false;
            continue;
        }

        if (std.ascii.eqlIgnoreCase(arg, "-v") or
            std.ascii.eqlIgnoreCase(arg, "--version"))
        {
            expecting_version = true;
            continue;
        }

        if (std.ascii.eqlIgnoreCase(arg, "-t") or
            std.ascii.eqlIgnoreCase(arg, "--target"))
        {
            expecting_target = true;
            continue;
        }

        should_print_help = true;
        break;
    }

    if (should_print_help) {
        std.debug.print(
            \\  -h, --help             Prints this message.
            \\  -v, --version <str>    Optional Zig version specification. eg. 0.14.1
            \\  -t, --target <str>     Optional platform target specification. eg. x86_64-windows
            \\
        ,
            .{},
        );
        return error.Help;
    }
    return target;
}

pub fn main() !void {
    var default_allocator = DefaultAllocator.init();
    defer default_allocator.deinit();

    var arena = std.heap.ArenaAllocator.init(default_allocator.allocator());
    defer arena.deinit();

    const allocator = arena.allocator();

    const target = getTarget(allocator) catch |err| {
        if (err == error.Help) return;
        return err;
    };

    var http_client: std.http.Client = .{ .allocator = allocator };
    defer http_client.deinit();

    const remote_zig = try getZigTarball(allocator, &http_client, target.zig_version, target.platform);
    std.log.info("Found remote version: {s}", .{remote_zig.version});

    if (!try needsToUpdateZig(allocator, "zig", remote_zig.version)) {
        std.log.info("Zig is up-to-date.", .{});
        return;
    }

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;

    const out_dir_path = try std.fs.selfExeDirPath(path_buffer[0..]);
    var out_dir = try std.fs.openDirAbsolute(out_dir_path, .{});
    defer out_dir.close();

    var final_dir = try downloadAndExtractZigTarball(allocator, &http_client, remote_zig, out_dir);
    defer final_dir.close();

    const zig_file = if (std.ascii.indexOfIgnoreCase(target.platform, "windows") != null) "zig.exe" else "zig";
    _ = final_dir.statFile(zig_file) catch {
        std.log.err("Failed to exract the new Zig compiler.", .{});
        return;
    };

    std.log.info("Creating symlink at: `{s}`", .{out_dir_path});
    const zig_exe_path = try final_dir.realpath(zig_file, path_buffer[0..]);
    out_dir.deleteFile(zig_file) catch {};
    try out_dir.symLink(zig_exe_path, zig_file, .{});
    std.log.info("Successfully updated zig!", .{});
}
