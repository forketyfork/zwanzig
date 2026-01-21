const std = @import("std");
const BuildMetadata = @import("build_metadata.zig").BuildMetadata;

pub const CacheError = error{
    CacheCorrupted,
    VersionMismatch,
    OutOfMemory,
    FileNotFound,
    AccessDenied,
    InvalidCacheEntry,
};

const CACHE_VERSION: u32 = 1;
const CACHE_DIR_NAME = ".zwanzig-cache";

pub const CacheKey = struct {
    file_hash: [32]u8,
    target_hash: [32]u8,

    pub fn init(file_content: []const u8, target: ?*const BuildMetadata) CacheKey {
        var key: CacheKey = undefined;
        std.crypto.hash.sha2.Sha256.hash(file_content, &key.file_hash, .{});

        if (target) |t| {
            var hasher = std.crypto.hash.sha2.Sha256.init(.{});
            const arch_name = @tagName(t.target.arch);
            hasher.update(arch_name);
            const os_name = @tagName(t.target.os);
            hasher.update(os_name);
            if (t.target.abi) |abi| {
                hasher.update(abi);
            }
            hasher.final(&key.target_hash);
        } else {
            @memset(&key.target_hash, 0);
        }

        return key;
    }

    pub fn format(self: CacheKey, comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
        for (self.file_hash) |byte| {
            try writer.print("{x:0>2}", .{byte});
        }
        try writer.writeByte('_');
        for (self.target_hash) |byte| {
            try writer.print("{x:0>2}", .{byte});
        }
    }

    pub fn eql(self: CacheKey, other: CacheKey) bool {
        return std.mem.eql(u8, &self.file_hash, &other.file_hash) and
            std.mem.eql(u8, &self.target_hash, &other.target_hash);
    }
};

pub const CacheEntry = struct {
    version: u32,
    key: CacheKey,
    timestamp: i64,
    data_len: u32,

    pub fn init(key: CacheKey, data_len: u32) CacheEntry {
        return CacheEntry{
            .version = CACHE_VERSION,
            .key = key,
            .timestamp = std.time.timestamp(),
            .data_len = data_len,
        };
    }

    pub fn writeToFile(self: CacheEntry, file: std.fs.File) !void {
        var buf: [4 + 32 + 32 + 8 + 4]u8 = undefined;
        std.mem.writeInt(u32, buf[0..4], self.version, .little);
        @memcpy(buf[4..36], &self.key.file_hash);
        @memcpy(buf[36..68], &self.key.target_hash);
        std.mem.writeInt(i64, buf[68..76], self.timestamp, .little);
        std.mem.writeInt(u32, buf[76..80], self.data_len, .little);
        try file.writeAll(&buf);
    }

    pub fn readFromFile(file: std.fs.File) !CacheEntry {
        var buf: [4 + 32 + 32 + 8 + 4]u8 = undefined;
        const bytes_read = try file.readAll(&buf);
        if (bytes_read != buf.len) {
            return CacheError.CacheCorrupted;
        }

        const version = std.mem.readInt(u32, buf[0..4], .little);
        if (version != CACHE_VERSION) {
            return CacheError.VersionMismatch;
        }

        var entry: CacheEntry = undefined;
        entry.version = version;
        @memcpy(&entry.key.file_hash, buf[4..36]);
        @memcpy(&entry.key.target_hash, buf[36..68]);
        entry.timestamp = std.mem.readInt(i64, buf[68..76], .little);
        entry.data_len = std.mem.readInt(u32, buf[76..80], .little);

        return entry;
    }
};

pub const Cache = struct {
    allocator: std.mem.Allocator,
    cache_dir: ?std.fs.Dir,

    pub fn init(allocator: std.mem.Allocator) !Cache {
        const cache_dir = std.fs.cwd().makeOpenPath(CACHE_DIR_NAME, .{}) catch |err| {
            switch (err) {
                error.AccessDenied => return Cache{
                    .allocator = allocator,
                    .cache_dir = null,
                },
                else => return err,
            }
        };

        return Cache{
            .allocator = allocator,
            .cache_dir = cache_dir,
        };
    }

    pub fn deinit(self: *Cache) void {
        if (self.cache_dir) |*dir| {
            dir.close();
        }
    }

    pub fn getCachePath(key: CacheKey, buf: []u8) ![]const u8 {
        var offset: usize = 0;
        for (key.file_hash) |byte| {
            const written = try std.fmt.bufPrint(buf[offset..], "{x:0>2}", .{byte});
            offset += written.len;
        }
        const written = try std.fmt.bufPrint(buf[offset..], "_", .{});
        offset += written.len;
        for (key.target_hash) |byte| {
            const written2 = try std.fmt.bufPrint(buf[offset..], "{x:0>2}", .{byte});
            offset += written2.len;
        }
        const ext = try std.fmt.bufPrint(buf[offset..], ".cache", .{});
        offset += ext.len;
        return buf[0..offset];
    }

    pub fn get(self: *Cache, key: CacheKey) !?[]u8 {
        if (self.cache_dir == null) {
            return null;
        }

        var path_buf: [256]u8 = undefined;
        const cache_path = try Cache.getCachePath(key, &path_buf);

        const file = self.cache_dir.?.openFile(cache_path, .{}) catch |err| {
            return switch (err) {
                error.FileNotFound => null,
                error.AccessDenied => CacheError.AccessDenied,
                else => err,
            };
        };
        defer file.close();

        const entry = CacheEntry.readFromFile(file) catch |err| {
            return switch (err) {
                error.VersionMismatch => null,
                else => err,
            };
        };

        if (!entry.key.eql(key)) {
            return CacheError.CacheCorrupted;
        }

        const data = try self.allocator.alloc(u8, entry.data_len);
        errdefer self.allocator.free(data);

        const bytes_read = try file.readAll(data);
        if (bytes_read != entry.data_len) {
            self.allocator.free(data);
            return CacheError.CacheCorrupted;
        }

        return data;
    }

    pub fn put(self: *Cache, key: CacheKey, data: []const u8) !void {
        if (self.cache_dir == null) {
            return;
        }

        var path_buf: [256]u8 = undefined;
        const cache_path = try Cache.getCachePath(key, &path_buf);

        const file = try self.cache_dir.?.createFile(cache_path, .{});
        defer file.close();

        const entry = CacheEntry.init(key, @intCast(data.len));
        try entry.writeToFile(file);
        try file.writeAll(data);
    }

    pub fn invalidate(self: *Cache, key: CacheKey) !void {
        if (self.cache_dir == null) {
            return;
        }

        var path_buf: [256]u8 = undefined;
        const cache_path = try Cache.getCachePath(key, &path_buf);

        self.cache_dir.?.deleteFile(cache_path) catch |err| {
            if (err != error.FileNotFound) {
                return err;
            }
        };
    }

    pub fn clear(self: *Cache) !void {
        if (self.cache_dir == null) {
            return;
        }

        var iter = self.cache_dir.?.iterate();
        while (try iter.next()) |entry| {
            if (entry.kind == .file and std.mem.endsWith(u8, entry.name, ".cache")) {
                try self.cache_dir.?.deleteFile(entry.name);
            }
        }
    }
};

test "CacheKey: init and format" {
    const target = BuildMetadata{
        .target = .{
            .arch = .x86_64,
            .os = .linux,
            .abi = "gnu",
        },
        .optimize_mode = null,
        .root_source_file = null,
    };

    const key = CacheKey.init("test content", &target);

    var buf: [512]u8 = undefined;
    const path = try Cache.getCachePath(key, &buf);

    try std.testing.expect(path.len > 0);
    try std.testing.expect(std.mem.endsWith(u8, path, ".cache"));
    try std.testing.expect(std.mem.indexOf(u8, path, "_") != null);
}

test "CacheKey: eql" {
    const key1 = CacheKey.init("test", null);
    const key2 = CacheKey.init("test", null);
    const key3 = CacheKey.init("different", null);

    try std.testing.expect(key1.eql(key2));
    try std.testing.expect(!key1.eql(key3));
}

test "CacheEntry: write and read" {
    const allocator = std.testing.allocator;
    const key = CacheKey.init("test", null);
    const entry = CacheEntry.init(key, 42);

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const file = try tmp_dir.dir.createFile("test.cache", .{ .read = true });
    defer file.close();

    try entry.writeToFile(file);

    try file.seekTo(0);
    const read_entry = try CacheEntry.readFromFile(file);

    try std.testing.expectEqual(entry.version, read_entry.version);
    try std.testing.expectEqual(entry.data_len, read_entry.data_len);
    try std.testing.expect(entry.key.eql(read_entry.key));
    _ = allocator;
}

test "Cache: put and get" {
    const allocator = std.testing.allocator;

    const cache_dir = try std.fs.cwd().makeOpenPath("test-cache-tmp", .{});
    defer {
        std.fs.cwd().deleteTree("test-cache-tmp") catch {};
    }

    var cache = Cache{
        .allocator = allocator,
        .cache_dir = cache_dir,
    };
    defer cache.deinit();

    const key = CacheKey.init("test content", null);
    const data = "cached data";

    try cache.put(key, data);

    const retrieved = try cache.get(key);
    if (retrieved) |r| {
        defer allocator.free(r);
        try std.testing.expectEqualStrings(data, r);
    } else {
        return error.CacheMiss;
    }
}

test "Cache: get non-existent key returns null" {
    const allocator = std.testing.allocator;

    var cache = Cache{
        .allocator = allocator,
        .cache_dir = null,
    };
    defer cache.deinit();

    const key = CacheKey.init("non-existent", null);
    const result = try cache.get(key);

    try std.testing.expectEqual(@as(?[]u8, null), result);
}

test "Cache: invalidate removes entry" {
    const allocator = std.testing.allocator;

    const cache_dir = try std.fs.cwd().makeOpenPath("test-cache-tmp2", .{});
    defer {
        std.fs.cwd().deleteTree("test-cache-tmp2") catch {};
    }

    var cache = Cache{
        .allocator = allocator,
        .cache_dir = cache_dir,
    };
    defer cache.deinit();

    const key = CacheKey.init("test", null);
    try cache.put(key, "data");

    try cache.invalidate(key);

    const result = try cache.get(key);
    try std.testing.expectEqual(@as(?[]u8, null), result);
}

test "Cache: clear removes all entries" {
    const allocator = std.testing.allocator;

    const cache_dir = try std.fs.cwd().makeOpenPath("test-cache-tmp3", .{});
    defer {
        std.fs.cwd().deleteTree("test-cache-tmp3") catch {};
    }

    var cache = Cache{
        .allocator = allocator,
        .cache_dir = cache_dir,
    };
    defer cache.deinit();

    const key1 = CacheKey.init("test1", null);
    const key2 = CacheKey.init("test2", null);

    try cache.put(key1, "data1");
    try cache.put(key2, "data2");

    try cache.clear();

    const result1 = try cache.get(key1);
    const result2 = try cache.get(key2);

    try std.testing.expectEqual(@as(?[]u8, null), result1);
    try std.testing.expectEqual(@as(?[]u8, null), result2);
}

test "Cache: handles access denied gracefully" {
    const allocator = std.testing.allocator;

    var cache = Cache{
        .allocator = allocator,
        .cache_dir = null,
    };
    defer cache.deinit();

    const key = CacheKey.init("test", null);

    try cache.put(key, "data");

    const result = try cache.get(key);
    try std.testing.expectEqual(@as(?[]u8, null), result);
}
