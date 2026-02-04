const std = @import("std");
const rl = @import("raylib");

const Vector2 = rl.Vector2;
const Rectangle = rl.Rectangle;
const ArrayList = std.ArrayList;

const WireEnd = struct { mod: usize, port: usize };
const Wire = struct { from: WireEnd, to: WireEnd };

const CustomModule = struct {
    input_cnt: usize,
    output_cnt: usize,
    modules: ArrayList(struct {
        pos: Vector2,
        mod: usize, // index within global modules list
        // wires_out[i] are the wires connected to the output i.
        wires_out: ArrayList(ArrayList(usize)),
    }),
    wires: ArrayList(Wire),
};

const Module = union(enum) {
    and_gate: void,
    or_gate: void,
    not_gate: void,
    custom: CustomModule,
};

const CustomModuleInstance = struct {
    inputs: ArrayList(bool),
    outputs: ArrayList(bool),
    modules: ArrayList(struct {
        pos: Vector2,
        mod: *ModuleInstance,
        wires_out: ArrayList(ArrayList(usize)),
    }),
    wires: ArrayList(Wire),
};

const ModuleInstance = union(enum) {
    and_gate: struct { a: bool, b: bool, out: bool },
    or_gate: struct { a: bool, b: bool, out: bool },
    not_gate: struct { in: bool, out: bool },
    custom: CustomModule,
};

fn checkVec2RectCollision(v: Vector2, r: Rectangle) bool {
    return v.x >= r.x and v.x < r.x + r.width and v.y >= r.y and v.y < r.y + r.height;
}

fn rectPosition(r: Rectangle) Vector2 {
    return .{ .x = r.x, .y = r.y };
}

pub fn main() anyerror!void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer std.debug.assert(gpa.deinit() == .ok);
    const alloc = gpa.allocator();

    const screenWidth = 960;
    const screenHeight = 540;

    rl.setConfigFlags(.{ .window_resizable = true, .window_highdpi = true });
    rl.initWindow(screenWidth, screenHeight, "Logic Simulator");
    defer rl.closeWindow();

    rl.setTargetFPS(60);

    var rects: ArrayList(Rectangle) = .empty;
    defer rects.deinit(alloc);

    var drag: ?struct { offset: Vector2, rect_idx: usize } = null;

    try rects.append(alloc, .{ .x = 400, .y = 200, .width = 100, .height = 60 });

    while (!rl.windowShouldClose()) {
        const mouse = rl.getMousePosition();

        var hovered_idx: ?usize = null;

        for (rects.items, 0..) |rect, i| {
            if (checkVec2RectCollision(mouse, rect)) {
                hovered_idx = i;
                break;
            }
        }

        rl.setMouseCursor(if (hovered_idx) |_| .pointing_hand else .default);

        if (rl.isMouseButtonPressed(.left)) {
            if (hovered_idx) |v| {
                drag = .{
                    .offset = rectPosition(rects.items[v]).subtract(mouse),
                    .rect_idx = v,
                };
            }
        } else if (rl.isMouseButtonReleased(.left)) {
            drag = null;
        }

        if (drag) |v| {
            rects.items[v.rect_idx].x = mouse.x + v.offset.x;
            rects.items[v.rect_idx].y = mouse.y + v.offset.y;
        }

        // Drawing starts here
        rl.beginDrawing();
        defer rl.endDrawing();

        rl.clearBackground(.ray_white);

        for (rects.items) |rect| {
            rl.drawRectangleRec(rect, .red);
        }

        rl.drawText("Congrats! You created your first window!", 190, 200, 20, .dark_gray);
    }
}
