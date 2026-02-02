// Tests that method call with catch return guards unwrap of field set by method
// Pattern: self.ensureTexture() catch return; ... self.texture.?
// EXPECT: none
const Texture = struct {
    id: u32,
};

const Component = struct {
    texture: ?Texture = null,

    fn ensureTexture(self: *Component) !void {
        if (self.texture == null) {
            self.texture = Texture{ .id = 42 };
        }
    }

    fn render(self: *Component) void {
        self.ensureTexture() catch return;
        // After catch return, if ensureTexture succeeds, texture is non-null
        const tex = self.texture.?;
        _ = tex;
    }
};

pub fn main() void {
    var c = Component{};
    c.render();
}
