const std = @import("std");

pub const FileDiscoveryError = error{
    OutOfMemory,
    AccessDenied,
    InvalidUtf8,
    NotDir,
    FileNotFound,
};

const ignored_dirs = [_][]const u8{
    "zig-cache",
    "zig-out",
    ".zigmod",
    ".gyro",
};

pub fn discoverFiles(allocator: std.mem.Allocator, paths: []const []const u8) FileDiscoveryError![]const []const u8 {
    var files: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (files.items) |file| {
            allocator.free(file);
        }
        files.deinit(allocator);
    }

    if (paths.len == 0) {
        try walkDirectory(allocator, &files, ".");
    } else {
        for (paths) |path| {
            const stat = std.fs.cwd().statFile(path) catch |err| switch (err) {
                error.FileNotFound => return FileDiscoveryError.FileNotFound,
                error.AccessDenied => return FileDiscoveryError.AccessDenied,
                error.NotDir => {
                    if (isZigFile(path)) {
                        const owned = try allocator.dupe(u8, path);
                        try files.append(allocator, owned);
                    }
                    continue;
                },
                else => return FileDiscoveryError.AccessDenied,
            };

            if (stat.kind == .directory) {
                try walkDirectory(allocator, &files, path);
            } else if (isZigFile(path)) {
                const owned = try allocator.dupe(u8, path);
                try files.append(allocator, owned);
            }
        }
    }

    return files.toOwnedSlice(allocator);
}

fn walkDirectory(allocator: std.mem.Allocator, files: *std.ArrayList([]const u8), base_path: []const u8) FileDiscoveryError!void {
    var dir = std.fs.cwd().openDir(base_path, .{ .iterate = true }) catch |err| switch (err) {
        error.AccessDenied => return FileDiscoveryError.AccessDenied,
        error.FileNotFound => return FileDiscoveryError.FileNotFound,
        error.NotDir => return FileDiscoveryError.NotDir,
        else => return FileDiscoveryError.AccessDenied,
    };
    defer dir.close();

    var walker = dir.walk(allocator) catch return FileDiscoveryError.OutOfMemory;
    defer walker.deinit();

    while (true) {
        const entry = walker.next() catch return FileDiscoveryError.AccessDenied;
        if (entry) |e| {
            if (shouldIgnore(e.path)) {
                continue;
            }

            if (e.kind == .file and isZigFile(e.basename)) {
                const full_path = buildPath(allocator, base_path, e.path) catch return FileDiscoveryError.OutOfMemory;
                files.append(allocator, full_path) catch {
                    allocator.free(full_path);
                    return FileDiscoveryError.OutOfMemory;
                };
            }
        } else {
            break;
        }
    }
}

fn buildPath(allocator: std.mem.Allocator, base: []const u8, relative: []const u8) ![]const u8 {
    if (std.mem.eql(u8, base, ".")) {
        return allocator.dupe(u8, relative);
    }
    return std.fmt.allocPrint(allocator, "{s}/{s}", .{ base, relative });
}

fn isZigFile(name: []const u8) bool {
    return std.mem.endsWith(u8, name, ".zig");
}

fn shouldIgnore(path: []const u8) bool {
    for (ignored_dirs) |ignored| {
        if (pathContainsComponent(path, ignored)) {
            return true;
        }
    }
    return false;
}

fn pathContainsComponent(path: []const u8, component: []const u8) bool {
    var it = std.mem.splitScalar(u8, path, '/');
    while (it.next()) |part| {
        if (std.mem.eql(u8, part, component)) {
            return true;
        }
    }

    var it_backslash = std.mem.splitScalar(u8, path, '\\');
    while (it_backslash.next()) |part| {
        if (std.mem.eql(u8, part, component)) {
            return true;
        }
    }

    return false;
}

pub fn freeDiscoveredFiles(allocator: std.mem.Allocator, files: []const []const u8) void {
    for (files) |file| {
        allocator.free(file);
    }
    allocator.free(files);
}

test "isZigFile" {
    try std.testing.expect(isZigFile("main.zig"));
    try std.testing.expect(isZigFile("path/to/file.zig"));
    try std.testing.expect(!isZigFile("main.c"));
    try std.testing.expect(!isZigFile("main.zig.bak"));
    try std.testing.expect(!isZigFile(""));
}

test "shouldIgnore" {
    try std.testing.expect(shouldIgnore("zig-cache/file.zig"));
    try std.testing.expect(shouldIgnore("zig-out/bin/main.zig"));
    try std.testing.expect(shouldIgnore(".zigmod/deps/file.zig"));
    try std.testing.expect(shouldIgnore(".gyro/cache/file.zig"));
    try std.testing.expect(shouldIgnore("src/zig-cache/file.zig"));
    try std.testing.expect(!shouldIgnore("src/main.zig"));
    try std.testing.expect(!shouldIgnore("zig-cache-not/file.zig"));
}

test "pathContainsComponent" {
    try std.testing.expect(pathContainsComponent("zig-cache/file.zig", "zig-cache"));
    try std.testing.expect(pathContainsComponent("src/zig-cache/file.zig", "zig-cache"));
    try std.testing.expect(!pathContainsComponent("zig-cache-extra/file.zig", "zig-cache"));
    try std.testing.expect(!pathContainsComponent("notzig-cache/file.zig", "zig-cache"));
}

test "discoverFiles: explicit files" {
    const allocator = std.testing.allocator;

    const paths = [_][]const u8{"src/main.zig"};
    const files = try discoverFiles(allocator, &paths);
    defer freeDiscoveredFiles(allocator, files);

    try std.testing.expectEqual(@as(usize, 1), files.len);
    try std.testing.expectEqualStrings("src/main.zig", files[0]);
}

test "discoverFiles: walks directory" {
    const allocator = std.testing.allocator;

    const paths = [_][]const u8{"src"};
    const files = try discoverFiles(allocator, &paths);
    defer freeDiscoveredFiles(allocator, files);

    try std.testing.expect(files.len > 0);

    var found_main = false;
    for (files) |f| {
        if (std.mem.endsWith(u8, f, "main.zig")) {
            found_main = true;
            break;
        }
    }
    try std.testing.expect(found_main);
}

test "discoverFiles: empty paths walks current directory" {
    const allocator = std.testing.allocator;

    const paths = [_][]const u8{};
    const files = try discoverFiles(allocator, &paths);
    defer freeDiscoveredFiles(allocator, files);

    try std.testing.expect(files.len > 0);
}

test "discoverFiles: non-zig files filtered" {
    const allocator = std.testing.allocator;

    const paths = [_][]const u8{"."};
    const files = try discoverFiles(allocator, &paths);
    defer freeDiscoveredFiles(allocator, files);

    for (files) |f| {
        try std.testing.expect(std.mem.endsWith(u8, f, ".zig"));
    }
}
