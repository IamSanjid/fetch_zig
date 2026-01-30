const builtin = @import("builtin");
const std = @import("std");

const Allocator = std.mem.Allocator;

const ZIG_DOWNLOAD_INDEX_URL = "https://ziglang.org/download/index.json";
const MASTER_INDEX = "master";
const CURRENT_PLATFORM = @tagName(builtin.cpu.arch) ++ "-" ++ @tagName(builtin.os.tag);

const DefaultAllocator = if (builtin.single_threaded) @compileError("TODO: Handle single-threaded Io.") else struct {
    backing_allocator: if (builtin.mode == .Debug) std.heap.DebugAllocator(.{}) else Allocator,

    const need_debug_allocator = builtin.mode == .Debug;
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

fn getDefaultOutDir(arena: Allocator, io: std.Io, environ: std.process.Environ) ![]const u8 {
    var env = try environ.createMap(arena);
    defer env.deinit();

    const zig_bins: *const [2][]const u8 = &.{ "zig", "zig.exe" };

    const path = env.get("PATH") orelse env.get("Path") orelse env.get("path") orelse "";
    var paths = std.mem.splitScalar(u8, path, std.fs.path.delimiter);
    while (paths.next()) |p| {
        if (p.len == 0) continue;
        for (zig_bins) |zig_bin| {
            const candidate_path = std.fs.path.join(arena, &.{ p, zig_bin }) catch continue;
            const file_info = std.Io.Dir.cwd().statFile(io, candidate_path, .{}) catch continue;
            if (file_info.kind == .file) {
                return arena.dupe(u8, p);
            }
        }
    }

    return std.process.executableDirPathAlloc(io, arena);
}

const Config = struct {
    zig_version: []const u8 = MASTER_INDEX,
    platform: []const u8 = CURRENT_PLATFORM,
    check: bool = false,
    out_dir: []const u8,
};

fn getConfig(arena: Allocator, args: std.process.Args, default_out_dir: []const u8) !Config {
    var args_iter = try args.iterateAllocator(arena);
    defer args_iter.deinit();

    var config: Config = .{ .out_dir = try arena.dupe(u8, default_out_dir) };

    if (!args_iter.skip()) return config;

    var show_help = true;
    while (args_iter.next()) |arg| {
        if (std.ascii.eqlIgnoreCase(arg, "-v") or
            std.ascii.eqlIgnoreCase(arg, "--version"))
        {
            const zig_version_arg = args_iter.next() orelse {
                std.log.err("Missing version argument.", .{});
                break;
            };
            config.zig_version = try arena.dupe(u8, zig_version_arg);
            continue;
        }

        if (std.ascii.eqlIgnoreCase(arg, "-t") or
            std.ascii.eqlIgnoreCase(arg, "--target"))
        {
            const target_arg = args_iter.next() orelse {
                std.log.err("Missing target argument.", .{});
                break;
            };
            config.platform = try arena.dupe(u8, target_arg);
            continue;
        }

        if (std.ascii.eqlIgnoreCase(arg, "-c") or
            std.ascii.eqlIgnoreCase(arg, "--check"))
        {
            config.check = true;
            continue;
        }

        if (std.ascii.eqlIgnoreCase(arg, "-o") or
            std.ascii.eqlIgnoreCase(arg, "--out-dir"))
        {
            const out_dir_arg = args_iter.next() orelse {
                std.log.err("Missing out dir argument.", .{});
                break;
            };
            config.out_dir = try arena.dupe(u8, out_dir_arg);
            continue;
        }

        break;
    } else {
        // all arguments processed successfully
        show_help = false;
    }

    if (show_help) {
        std.debug.print(
            \\  -h, --help              Prints this message.
            \\  -v, --version <str>     Optional Zig version specification. eg. 0.14.1
            \\  -t, --target <str>      Optional platform target specification. eg. x86_64-windows
            \\  -o, --out-dir <str>     Optional output directory to install Zig into. Defaults to the directory containing the current executable.
            \\  -c, --check             Check whether the current version matches the latest or specified version by `-v`.
            \\
        ,
            .{},
        );
        return error.Help;
    }

    return config;
}

const Resource = struct {
    tarball: std.Uri,
    shasum: []const u8,
    size: usize,
};

fn fetch(
    allocator: Allocator,
    io: std.Io,
    http_client: *std.http.Client,
    url: []const u8,
) ![]const u8 {
    var body: std.Io.Writer.Allocating = .init(allocator);
    defer body.deinit();
    try body.ensureUnusedCapacity(1024);

    var fetch_fut = io.async(std.http.Client.fetch, .{
        http_client, std.http.Client.FetchOptions{
            .location = .{ .url = url },
            .response_writer = &body.writer,
        },
    });
    // nothing else can cause early return here so no need to do defer cancel.
    const fetch_res: std.http.Client.FetchResult = try fetch_fut.await(io);

    const status_class = fetch_res.status.class();
    if (status_class == .client_error or status_class == .server_error) {
        return error.FetchFailed;
    }

    return body.toOwnedSlice();
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
    io: std.Io,
    http_client: *std.http.Client,
    version: []const u8,
    target: []const u8,
) !ZigTarball {
    var resp_fut = io.async(fetch, .{ arena, io, http_client, ZIG_DOWNLOAD_INDEX_URL });
    // nothing else can cause early return here so no need to do defer cancel.
    const resp: []const u8 = try resp_fut.await(io);

    var found_tarball: ?ZigTarball = null;
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

            var res: ZigTarball = undefined;
            res.resource.size = 0;
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
            if (res.resource.size > 0) {
                found_tarball = res;
            }

            break;
        }
    }

    return found_tarball orelse error.TarballNotFound;
}

fn needsToUpdateZig(
    arena: Allocator,
    io: std.Io,
    current_exe: []const u8,
    remote_version: []const u8,
) !bool {
    const res = std.process.run(arena, io, .{
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

fn getFileTypeFromResp(
    resp: *const std.http.Client.Response,
    uri_path: []const u8,
) !FileType {
    const head = &resp.head;
    // Content-Type takes first precedence.
    const content_type = head.content_type orelse return error.ContentTypeMissing;

    // Extract the MIME type, ignoring charset and boundary directives
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

    if (head.content_disposition) |cd_header| {
        return FileType.fromContentDisposition(cd_header) orelse error.UnknownFileType;
    }

    return FileType.fromPath(uri_path) orelse error.UnknownFileType;
}

fn unpackTarball(
    arena: Allocator,
    io: std.Io,
    out_dir: std.Io.Dir,
    reader: *std.Io.Reader,
) !void {
    var diagnostics: std.tar.Diagnostics = .{ .allocator = arena };

    try std.tar.pipeToFileSystem(io, out_dir, reader, .{
        .diagnostics = &diagnostics,
        .strip_components = 0,
        .exclude_empty_directories = true,
    });

    if (diagnostics.errors.items.len > 0) {
        for (diagnostics.errors.items) |item| {
            switch (item) {
                .unable_to_create_file => |i| {
                    std.log.err("Unable to create file({}): {s}\n", .{ i.code, i.file_name });
                },
                .unable_to_create_sym_link => |i| {
                    std.log.err("Unable to create symlink({}): {s} as {s}\n", .{ i.code, i.file_name, i.link_name });
                },
                .unsupported_file_type => |i| {
                    std.log.err("Unsupported file type: {s} type: {}\n", .{ i.file_name, @intFromEnum(i.file_type) });
                },
                .components_outside_stripped_prefix => unreachable, // unreachable with strip_components = 0
            }
        }
        return error.UnpackTarFailed;
    }
}

fn unzip(
    arena: Allocator,
    io: std.Io,
    out_dir: std.Io.Dir,
    reader: *std.Io.Reader,
) !void {
    const cache_root = out_dir;
    const prefix = "./tmp_";
    const suffix = ".zip";
    const random_len = @sizeOf(u64) * 2;

    var zip_path: [prefix.len + random_len + suffix.len]u8 = undefined;
    zip_path[0..prefix.len].* = prefix.*;
    zip_path[prefix.len + random_len ..].* = suffix.*;

    var zip_file: std.Io.File = while (true) {
        const random_integer = r: {
            var x: u64 = undefined;
            io.random(@ptrCast(&x));
            break :r x;
        };
        zip_path[prefix.len..][0..random_len].* = std.fmt.hex(random_integer);

        break cache_root.createFile(io, &zip_path, .{
            .exclusive = true,
            .read = true,
        }) catch |err| switch (err) {
            error.PathAlreadyExists => continue,
            error.Canceled => return error.Canceled,
            else => return error.FileCreateFailed,
        };
    };
    defer zip_file.close(io);
    var zip_file_buffer: [4096]u8 = undefined;
    var zip_file_reader = b: {
        var zip_file_writer = zip_file.writer(io, &zip_file_buffer);

        _ = try reader.streamRemaining(&zip_file_writer.interface);
        try zip_file_writer.interface.flush();
        break :b zip_file_writer.moveToReader();
    };

    errdefer cache_root.deleteFile(io, &zip_path) catch {};

    var diagnostics: std.zip.Diagnostics = .{ .allocator = arena };
    try zip_file_reader.seekTo(0);
    try std.zip.extract(out_dir, &zip_file_reader, .{
        .allow_backslashes = true,
        .diagnostics = &diagnostics,
    });

    try cache_root.deleteFile(io, &zip_path);
}

fn existingZigTarballDir(
    arena: Allocator,
    io: std.Io,
    expected_extract_dir: []const u8,
    tarball: ZigTarball,
    out_dir: std.Io.Dir,
) ?std.Io.Dir {
    var need_to_close_dir = blk: {
        const dir = out_dir.openDir(io, expected_extract_dir, .{}) catch return null;
        const zig_file = if (std.ascii.indexOfIgnoreCase(expected_extract_dir, "windows") != null) "zig.exe" else "zig";
        const path = dir.realPathFileAlloc(io, zig_file, arena) catch break :blk dir;
        const need_update = needsToUpdateZig(arena, io, path, tarball.version) catch break :blk dir;
        if (!need_update) {
            return dir;
        }
        break :blk dir;
    };
    need_to_close_dir.close(io);
    return null;
}

const tarball_buffer_size = 16 * 1024;
fn downloadAndExtractZigTarball(
    arena: Allocator,
    io: std.Io,
    http_client: *std.http.Client,
    tarball: ZigTarball,
    out_dir: std.Io.Dir,
) !std.Io.Dir {
    var req = try http_client.request(.GET, tarball.resource.tarball, .{});
    defer req.deinit();

    var send_fut = io.async(std.http.Client.Request.sendBodiless, .{&req});
    try send_fut.await(io);

    var resp_fut = io.async(std.http.Client.Request.receiveHead, .{ &req, &.{} });
    var resp: std.http.Client.Response = try resp_fut.await(io);
    if (resp.head.status != .ok) return error.DownloadFailed;

    const uri_path = try tarball.resource.tarball.path.toRawMaybeAlloc(arena);
    const file_type = try getFileTypeFromResp(&resp, uri_path);

    var buffer: [tarball_buffer_size]u8 = undefined;
    var decompress_resp: std.http.Decompress = undefined;
    const decompress_buffer = try arena.alloc(u8, resp.head.content_encoding.minBufferCapacity());
    const reader = resp.readerDecompressing(&buffer, &decompress_resp, decompress_buffer);

    const filename = std.fs.path.basename(uri_path);
    const ext = file_type.asExtension();
    const expected_extract_dir = filename[0 .. filename.len - ext.len];
    std.log.info("Downloading and extracting `{s}`...", .{filename});
    // deleting the default extracted dir if exists...
    if (existingZigTarballDir(arena, io, expected_extract_dir, tarball, out_dir)) |dir| {
        std.log.warn(
            "There already exists an up-to-date Zig installation at `{s}`. Skipping download and extraction.",
            .{expected_extract_dir},
        );
        return dir;
    } else {
        out_dir.deleteDir(io, expected_extract_dir) catch {};
    }

    const awaitUnpack = struct {
        inline fn func(
            unpackFunc: anytype,
            inner_arena: Allocator,
            inner_io: std.Io,
            inner_out_dir: std.Io.Dir,
            inner_reader: *std.Io.Reader,
        ) @typeInfo(@TypeOf(unpackFunc)).@"fn".return_type.? {
            var fut = inner_io.async(unpackFunc, .{ inner_arena, inner_io, inner_out_dir, inner_reader });
            return fut.await(inner_io);
        }
    }.func;

    switch (file_type) {
        .tar => try awaitUnpack(unpackTarball, arena, io, out_dir, reader),
        .@"tar.gz" => {
            var flate_buffer: [std.compress.flate.max_window_len]u8 = undefined;
            var decompress: std.compress.flate.Decompress = .init(reader, .gzip, &flate_buffer);
            try awaitUnpack(unpackTarball, arena, io, out_dir, &decompress.reader);
        },
        .@"tar.xz" => {
            const gpa = arena;
            var decompress = try std.compress.xz.Decompress.init(reader, gpa, &.{});
            defer decompress.deinit();
            try awaitUnpack(unpackTarball, arena, io, out_dir, &decompress.reader);
        },
        .@"tar.zst" => {
            const window_len = std.compress.zstd.default_window_len;
            const window_buffer = try arena.alloc(u8, window_len + std.compress.zstd.block_size_max);
            var decompress: std.compress.zstd.Decompress = .init(reader, window_buffer, .{
                .verify_checksum = false,
                .window_len = window_len,
            });
            try awaitUnpack(unpackTarball, arena, io, out_dir, &decompress.reader);
        },
        .zip => try awaitUnpack(unzip, arena, io, out_dir, reader),
    }

    return out_dir.openDir(io, expected_extract_dir, .{});
}

pub fn main(init: std.process.Init.Minimal) !void {
    var default_allocator = DefaultAllocator.init();
    defer default_allocator.deinit();

    var arena = std.heap.ArenaAllocator.init(default_allocator.allocator());
    defer arena.deinit();

    const allocator = arena.allocator();

    var threaded = std.Io.Threaded.init(allocator, .{ .environ = init.environ });
    defer threaded.deinit();

    var io = threaded.io();

    const config = config_res: {
        const default_out_dir = try getDefaultOutDir(allocator, io, init.environ);
        defer allocator.free(default_out_dir);

        break :config_res getConfig(allocator, init.args, default_out_dir) catch |err| {
            if (err == error.Help) return;
            return err;
        };
    };

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const out_dir_path = path_buffer[0..out_dir_res: {
        break :out_dir_res std.Io.Dir.cwd().realPathFile(io, config.out_dir, path_buffer[0..]) catch |err| {
            if (err == error.FileNotFound) {
                try std.Io.Dir.cwd().createDirPath(io, config.out_dir);
                break :out_dir_res std.Io.Dir.cwd().realPathFile(io, config.out_dir, path_buffer[0..]) catch unreachable;
            }
            return err;
        };
    }];

    var out_dir = std.Io.Dir.openDirAbsolute(io, out_dir_path, .{}) catch |err| res: {
        if (err == error.FileNotFound) {
            // logically shouldn't happen because we created it above, but different os'es might behave differently.
            try std.Io.Dir.cwd().createDirPath(io, out_dir_path);
            break :res try std.Io.Dir.openDirAbsolute(io, out_dir_path, .{});
        }
        return err;
    };
    defer out_dir.close(io);

    var http_client: std.http.Client = .{ .allocator = allocator, .io = io };
    defer http_client.deinit();

    var remote_zig_fut = io.async(getZigTarball, .{
        allocator,
        io,
        &http_client,
        config.zig_version,
        config.platform,
    });
    var remote_zig: ZigTarball = try remote_zig_fut.await(io);
    std.log.info("Found remote version: {s}", .{remote_zig.version});

    const zig_bin = if (std.ascii.indexOfIgnoreCase(config.platform, "windows") != null) "zig.exe" else "zig";

    // I love this cursed syntax!
    if (!needs_update: {
        const index = out_dir.realPathFile(io, zig_bin, path_buffer[0..]) catch |err| {
            if (err == error.FileNotFound) break :needs_update true;
            return err;
        };
        const current_zig_exe_path = path_buffer[0..index];
        break :needs_update try needsToUpdateZig(allocator, io, current_zig_exe_path, remote_zig.version);
    }) {
        std.log.info("Zig is up-to-date.", .{});
        return;
    }

    // only wanted to check the current version.
    if (config.check) {
        std.log.info("Zig is NOT up-to-date.", .{});
        return;
    }

    var download_fut = io.async(downloadAndExtractZigTarball, .{
        allocator, io, &http_client, remote_zig, out_dir,
    });
    var final_dir: std.Io.Dir = try download_fut.await(io);
    defer final_dir.close(io);

    _ = final_dir.statFile(io, zig_bin, .{}) catch {
        std.log.err("Failed to exract the new Zig compiler.", .{});
        return;
    };

    const zig_exe_path = path_buffer[0..try final_dir.realPathFile(io, zig_bin, path_buffer[0..])];
    std.log.info("Creating symlink to: `{s}{s}{s}` from `{s}`", .{ out_dir_path, std.fs.path.sep_str, zig_bin, zig_exe_path });
    out_dir.deleteFile(io, zig_bin) catch {};
    try out_dir.symLink(io, zig_exe_path, zig_bin, .{});
    std.log.info("Successfully updated zig!", .{});
}
