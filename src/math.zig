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

pub fn snap(ref: Vector2, pos: Vector2) Vector2 {
    const dx = @abs(ref.x - pos.x);
    const dy = @abs(ref.y - pos.y);

    return if (dx < dy) .init(ref.x, pos.y) else .init(pos.x, ref.y);
}

pub fn distanceToSegment(point: Vector2, seg_a: Vector2, seg_b: Vector2) f32 {
    const a = seg_b.y - seg_a.y;
    const b = seg_a.x - seg_b.x;
    const c = (seg_b.x * seg_a.y) - (seg_a.x * seg_b.y);

    return @abs((a * point.x) + (b * point.y) + c) / @sqrt((a * a) + (b * b));
}

pub fn touchesSegment(point: Vector2, seg_a: Vector2, seg_b: Vector2, seg_thick: f32) bool {
    const x_min = @min(seg_a.x, seg_b.x);
    const x_max = @max(seg_a.x, seg_b.x);

    return point.x >= x_min and point.x <= x_max and distanceToSegment(point, seg_a, seg_b) < (seg_thick / 2);
}
