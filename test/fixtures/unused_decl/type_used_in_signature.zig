// EXPECT: none
const Payload = struct {
    value: i32,
};

fn takes(_: Payload) void {}

pub fn main() void {
    takes(.{ .value = 1 });
}
