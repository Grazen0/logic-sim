const std = @import("std");

const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;

const assert = std.debug.assert;

pub fn BinaryHeap(comptime T: type, lessThan: fn (T, T) bool) type {
    return struct {
        const Self = @This();

        data: ArrayList(T),

        pub const empty: Self = .{
            .data = .empty,
        };

        pub fn deinit(self: *Self, gpa: Allocator) void {
            self.data.deinit(gpa);
            self.* = undefined;
        }

        pub inline fn count(self: Self) usize {
            return self.data.items.len;
        }

        pub fn add(self: *Self, gpa: Allocator, value: T) !void {
            try self.data.append(gpa, value);
            self.bubbleUp(self.data.items.len - 1);
        }

        pub fn peek(self: *const Self) ?T {
            return if (self.data.items.len > 0) self.data.items[0] else null;
        }

        pub fn remove(self: *Self) T {
            assert(self.data.items.len > 0);
            return self.removeOrNull().?;
        }

        pub fn removeOrNull(self: *Self) ?T {
            if (self.data.items.len == 0)
                return null;

            if (self.data.items.len == 1)
                return self.data.pop().?;

            const top = self.data.items[0];
            self.data.items[0] = self.data.pop().?;
            self.bubbleDown(0);

            return top;
        }

        fn bubbleDown(self: *Self, idx: usize) void {
            assert(idx < self.data.items.len);

            const value = self.data.items[idx];
            var i = idx;

            while (true) {
                const l = (2 * i) + 1;
                const r = (2 * i) + 2;

                if (l >= self.data.items.len)
                    break;

                var best = l;

                if (r < self.data.items.len and lessThan(self.data.items[l], self.data.items[r]))
                    best = r;

                if (!lessThan(value, self.data.items[best]))
                    break;

                self.data.items[i] = self.data.items[best];
                i = best;
            }

            self.data.items[i] = value;
        }

        fn bubbleUp(self: *Self, idx: usize) void {
            assert(idx < self.data.items.len);

            const value = self.data.items[idx];
            var i = idx;

            while (i > 0) {
                const par = (i - 1) / 2;

                if (!lessThan(self.data.items[par], value))
                    break;

                self.data.items[i] = self.data.items[par];
                i = par;
            }

            self.data.items[i] = value;
        }
    };
}
