const rl = @import("raylib");

const Vector2 = rl.Vector2;
const Rectangle = rl.Rectangle;

pub fn checkVec2RectCollision(v: Vector2, r: Rectangle) bool {
    return v.x >= r.x and v.x < r.x + r.width and v.y >= r.y and v.y < r.y + r.height;
}

pub fn interpolate(total_cnt: usize, idx: usize, len: f32) f32 {
    const step = len / @as(f32, @floatFromInt(total_cnt + 1));
    return @as(f32, @floatFromInt(idx + 1)) * step;
}
