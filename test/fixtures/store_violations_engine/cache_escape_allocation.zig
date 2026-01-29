const std = @import("std");
// zwanzig-disable: unused-decl

const Component = struct {
    allocator: std.mem.Allocator,
    cache: ?*Cache = null,
    font_cache: *FontCache,

    const Color = struct {
        r: u8,
        g: u8,
        b: u8,
        a: u8,
    };

    const Texture = struct {
        tex: *u8,
        w: i32,
        h: i32,
    };

    const FontGroup = struct {
        regular: usize,
    };

    const FontCache = struct {
        generation: usize,

        fn get(self: *const FontCache, _: i32) !FontGroup {
            _ = self;
            return .{ .regular = 1 };
        }
    };

    const EntryTex = struct {
        hotkey: Texture,
        path: Texture,
    };

    const Cache = struct {
        ui_scale: f32,
        title_font_size: i32,
        entry_font_size: i32,
        title: Texture,
        entries: []EntryTex,
        theme_fg: Color,
        key_color: Color,
        title_color: Color,
        entry_color: Color,
        font_generation: usize,
    };

    fn makeTextTexture(_: *FontCache, _: usize, _: []const u8, _: Color) !Texture {
        return .{ .tex = undefined, .w = 1, .h = 1 };
    }

    fn destroyEntryTextures(_: []EntryTex) void {}

    fn initCache(cache: *Cache, entries: []EntryTex, title: Texture, fg: Color, key_color: Color, title_color: Color, entry_color: Color, ui_scale: f32, title_font_size: i32, entry_font_size: i32, generation: usize) void {
        cache.* = .{
            .ui_scale = ui_scale,
            .title_font_size = title_font_size,
            .entry_font_size = entry_font_size,
            .title = title,
            .entries = entries,
            .theme_fg = fg,
            .key_color = key_color,
            .title_color = title_color,
            .entry_color = entry_color,
            .font_generation = generation,
        };
    }

    fn entryCount(self: *Component) usize {
        _ = self;
        return 2;
    }

    fn destroyCache(self: *Component) void {
        if (self.cache) |cache| {
            destroyEntryTextures(cache.entries);
            self.allocator.free(cache.entries);
            self.allocator.destroy(cache);
            self.cache = null;
        }
    }

    fn ensureCache(self: *Component, ui_scale: f32) ?*Cache {
        const cache_store = self.font_cache;
        const title_font_size: i32 = 20;
        const entry_font_size: i32 = 16;
        const fg = Color{ .r = 10, .g = 20, .b = 30, .a = 255 };
        const entry_count = self.entryCount();

        if (self.cache) |cache| {
            if (cache.title_font_size == title_font_size and cache.entry_font_size == entry_font_size and cache.ui_scale == ui_scale and cache.entries.len == entry_count and cache.font_generation == cache_store.generation) {
                return cache;
            }
            self.destroyCache();
        }

        const cache = self.allocator.create(Cache) catch return null;
        errdefer self.allocator.destroy(cache);

        const title_fonts = cache_store.get(title_font_size) catch {
            self.allocator.destroy(cache);
            return null;
        };

        const entry_fonts = cache_store.get(entry_font_size) catch {
            self.allocator.destroy(cache);
            return null;
        };

        const title_color = Color{ .r = fg.r, .g = fg.g, .b = fg.b, .a = 255 };
        const title_tex = makeTextTexture(cache_store, title_fonts.regular, "title", title_color) catch {
            self.allocator.destroy(cache);
            return null;
        };

        const key_color = Color{ .r = 97, .g = 175, .b = 239, .a = 255 };
        const entry_color = Color{ .r = 171, .g = 178, .b = 191, .a = 255 };

        const entries = self.allocator.alloc(EntryTex, entry_count) catch {
            self.allocator.destroy(cache);
            return null;
        };
        errdefer self.allocator.free(entries);

        for (0..entry_count) |idx| {
            const key_tex = makeTextTexture(cache_store, entry_fonts.regular, "key", key_color) catch {
                destroyEntryTextures(entries[0..idx]);
                self.allocator.free(entries);
                self.allocator.destroy(cache);
                return null;
            };

            const path_tex = makeTextTexture(cache_store, entry_fonts.regular, "path", entry_color) catch {
                _ = key_tex;
                destroyEntryTextures(entries[0..idx]);
                self.allocator.free(entries);
                self.allocator.destroy(cache);
                return null;
            };

            entries[idx] = .{ .hotkey = key_tex, .path = path_tex };
        }

        initCache(cache, entries, title_tex, fg, key_color, title_color, entry_color, ui_scale, title_font_size, entry_font_size, cache_store.generation);
        self.cache = cache;
        return cache;
    }
};

fn useComponent(allocator: std.mem.Allocator) void {
    var font_cache = Component.FontCache{ .generation = 1 };
    var component = Component{ .allocator = allocator, .font_cache = &font_cache };
    _ = component.ensureCache(1.0);
    component.destroyCache();
}

// EXPECT: none
