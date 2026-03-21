const std = @import("std");

const testing = std.testing;
const ArrayList = std.ArrayList;
const Allocator = std.mem.Allocator;

pub fn SlotMap(comptime T: type) type {
    return struct {
        const Self = @This();

        pub const Key = struct {
            index: usize,
            gen: u64,

            pub fn equals(self: Key, other: Key) bool {
                return self.index == other.index and self.gen == other.gen;
            }
        };

        const Slot = struct {
            gen: u64, // even = vacant, odd = occupied
            contents: union {
                data: T,
                next_free: usize,
            },

            inline fn isOccupied(self: @This()) bool {
                return (self.gen % 2) != 0;
            }
        };

        slots: ArrayList(Slot),
        first_free: usize,
        count: usize,

        fn Iter(comptime S: type, comptime V: type) type {
            return struct {
                slot_map: S,
                idx: usize,

                pub const Entry = struct {
                    key: Key,
                    val: V,
                };

                pub fn reset(self: *@This()) void {
                    self.idx = 0;
                }

                pub fn next(self: *@This()) ?Entry {
                    while (self.idx < self.slot_map.slots.items.len) {
                        defer self.idx += 1;
                        const slot = &self.slot_map.slots.items[self.idx];

                        if (slot.isOccupied()) {
                            return .{
                                .key = .{ .index = self.idx, .gen = slot.gen },
                                .val = &slot.contents.data,
                            };
                        }
                    }

                    return null;
                }

                pub fn nextKey(self: *@This()) ?Key {
                    while (self.idx < self.slot_map.slots.items.len) {
                        defer self.idx += 1;
                        const slot = &self.slot_map.slots.items[self.idx];

                        if (slot.isOccupied())
                            return .{ .index = self.idx, .gen = slot.gen };
                    }

                    return null;
                }

                pub fn nextValue(self: *@This()) ?V {
                    while (self.idx < self.slot_map.slots.items.len) {
                        defer self.idx += 1;
                        const slot = &self.slot_map.slots.items[self.idx];

                        if (slot.isOccupied())
                            return &slot.contents.data;
                    }

                    return null;
                }
            };
        }

        pub const ConstIterator = Iter(*const Self, *const T);
        pub const Iterator = Iter(*Self, *T);

        pub const ReverseIterator = struct {
            slot_map: *SlotMap(T),
            idx: usize,

            pub const Entry = struct {
                key: Key,
                val: *T,
            };

            pub fn next(self: *@This()) ?Entry {
                while (self.idx > 0) {
                    self.idx -= 1;
                    const slot = &self.slot_map.slots.items[self.idx];

                    if (slot.isOccupied()) {
                        return .{
                            .key = .{ .index = self.idx, .gen = slot.gen },
                            .val = &slot.contents.data,
                        };
                    }
                }

                return null;
            }

            pub fn nextKey(self: *@This()) ?Key {
                while (self.idx > 0) {
                    self.idx -= 1;
                    const slot = &self.slot_map.slots.items[self.idx];

                    if (slot.isOccupied())
                        return .{ .index = self.idx, .gen = slot.gen };
                }

                return null;
            }

            pub fn nextValue(self: *@This()) ?*T {
                while (self.idx > 0) {
                    self.idx -= 1;
                    const slot = &self.slot_map.slots.items[self.idx];

                    if (slot.isOccupied())
                        return &slot.contents.data;
                }

                return null;
            }
        };

        pub const empty: Self = .{
            .slots = .empty,
            .first_free = 0,
            .count = 0,
        };

        pub fn initCapacity(gpa: Allocator, num: usize) !Self {
            return .{
                .slots = try .initCapacity(gpa, num),
                .first_free = 0,
                .count = 0,
            };
        }

        pub fn deinit(self: *Self, gpa: Allocator) void {
            self.slots.deinit(gpa);
            self.* = undefined;
        }

        pub fn put(self: *Self, gpa: Allocator, value: T) error{OutOfMemory}!Key {
            const slot_idx = self.first_free;

            if (slot_idx == self.slots.items.len) {
                try self.slots.append(gpa, .{
                    .gen = 0,
                    .contents = .{ .next_free = slot_idx + 1 },
                });
            }

            const slot = &self.slots.items[slot_idx];

            self.first_free = slot.contents.next_free;
            slot.contents = .{ .data = value };
            slot.gen += 1;

            self.count += 1;
            return .{ .index = slot_idx, .gen = slot.gen };
        }

        pub fn hasKey(self: Self, key: Key) bool {
            return self.getSlot(key) != null;
        }

        pub fn getPtr(self: *const Self, key: Key) ?*T {
            const slot = self.getSlot(key) orelse return null;
            return &slot.contents.data;
        }

        pub fn get(self: Self, key: Key) ?T {
            const slot = self.getSlot(key) orelse return null;
            return slot.contents.data;
        }

        pub fn remove(self: *Self, key: Key) ?T {
            const slot = self.getSlot(key) orelse return null;
            const data = slot.contents.data;

            slot.gen += 1;
            slot.contents = .{ .next_free = self.first_free };
            self.first_free = key.index;

            self.count -= 1;
            return data;
        }

        pub fn constIterator(self: *const Self) ConstIterator {
            return .{
                .slot_map = self,
                .idx = 0,
            };
        }

        pub fn iterator(self: *Self) Iterator {
            return .{
                .slot_map = self,
                .idx = 0,
            };
        }

        pub fn revIterator(self: *Self) ReverseIterator {
            return .{
                .slot_map = self,
                .idx = self.slots.items.len,
            };
        }

        fn getSlot(self: Self, key: Key) ?*Slot {
            const slot = &self.slots.items[key.index];
            return if (slot.gen == key.gen) slot else null;
        }
    };
}

test "SlotMap operations" {
    const gpa = std.testing.allocator;

    var map: SlotMap([]const u8) = .empty;
    defer map.deinit(gpa);

    try testing.expectEqual(map.count, 0);

    const foo = try map.put(gpa, "foo");
    const bar = try map.put(gpa, "bar");
    const baz = try map.put(gpa, "baz");

    try testing.expectEqual(map.count, 3);
    try testing.expect(map.hasKey(foo));
    try testing.expect(map.hasKey(bar));
    try testing.expect(map.hasKey(baz));

    try testing.expectEqualStrings(map.getPtr(foo).?.*, "foo");
    try testing.expectEqualStrings(map.getPtr(bar).?.*, "bar");
    try testing.expectEqualStrings(map.getPtr(baz).?.*, "baz");

    try testing.expectEqualStrings(map.remove(bar).?, "bar");

    try testing.expectEqual(map.count, 2);
    try testing.expect(map.hasKey(foo));
    try testing.expect(!map.hasKey(bar));
    try testing.expect(map.hasKey(baz));

    try testing.expectEqualStrings(map.getPtr(foo).?.*, "foo");
    try testing.expectEqual(null, map.getPtr(bar));
    try testing.expectEqualStrings(map.getPtr(baz).?.*, "baz");

    try testing.expectEqualStrings(map.remove(foo).?, "foo");

    try testing.expectEqual(map.count, 1);
    try testing.expect(!map.hasKey(foo));
    try testing.expect(!map.hasKey(bar));
    try testing.expect(map.hasKey(baz));

    try testing.expectEqual(null, map.getPtr(foo));
    try testing.expectEqual(null, map.getPtr(bar));
    try testing.expectEqualStrings(map.getPtr(baz).?.*, "baz");

    const lorem = try map.put(gpa, "lorem");

    try testing.expectEqual(map.count, 2);
    try testing.expect(!map.hasKey(foo));
    try testing.expect(!map.hasKey(bar));
    try testing.expect(map.hasKey(baz));
    try testing.expect(map.hasKey(lorem));

    try testing.expectEqual(null, map.getPtr(foo));
    try testing.expectEqual(null, map.getPtr(bar));
    try testing.expectEqualStrings(map.getPtr(baz).?.*, "baz");
    try testing.expectEqualStrings(map.getPtr(lorem).?.*, "lorem");

    try testing.expectEqualStrings(map.remove(baz).?, "baz");

    try testing.expectEqual(map.count, 1);
    try testing.expect(!map.hasKey(foo));
    try testing.expect(!map.hasKey(bar));
    try testing.expect(!map.hasKey(baz));
    try testing.expect(map.hasKey(lorem));

    try testing.expectEqual(null, map.getPtr(foo));
    try testing.expectEqual(null, map.getPtr(bar));
    try testing.expectEqual(null, map.getPtr(baz));
    try testing.expectEqualStrings(map.getPtr(lorem).?.*, "lorem");

    const ipsum = try map.put(gpa, "ipsum");

    try testing.expectEqual(map.count, 2);
    try testing.expect(!map.hasKey(foo));
    try testing.expect(!map.hasKey(bar));
    try testing.expect(!map.hasKey(baz));
    try testing.expect(map.hasKey(lorem));
    try testing.expect(map.hasKey(ipsum));

    try testing.expectEqual(null, map.getPtr(foo));
    try testing.expectEqual(null, map.getPtr(bar));
    try testing.expectEqual(null, map.getPtr(baz));
    try testing.expectEqualStrings(map.getPtr(lorem).?.*, "lorem");
    try testing.expectEqualStrings(map.getPtr(ipsum).?.*, "ipsum");
}

pub fn SecondaryMap(comptime K: type, comptime T: type) type {
    return struct {
        const Self = @This();

        pub const Slot = union(enum) {
            vacant,
            occupied: struct {
                gen: u64,
                data: T,
            },
        };

        slots: ArrayList(Slot),
        count: usize,

        fn Iter(comptime S: type, comptime V: type) type {
            return struct {
                map: S,
                idx: usize,

                pub const Entry = struct { key: K, val: V };

                pub fn reset(self: *@This()) void {
                    self.idx = 0;
                }

                pub fn next(self: *@This()) ?Entry {
                    while (self.idx < self.map.slots.items.len) {
                        defer self.idx += 1;
                        const slot = &self.map.slots.items[self.idx];

                        switch (slot.*) {
                            .vacant => {},
                            .occupied => |*slot_v| return .{
                                .key = .{ .index = self.idx, .gen = slot_v.gen },
                                .val = &slot_v.data,
                            },
                        }
                    }

                    return null;
                }

                pub fn nextKey(self: *@This()) ?K {
                    while (self.idx < self.map.slots.items.len) {
                        defer self.idx += 1;
                        const slot = &self.map.slots.items[self.idx];

                        switch (slot.*) {
                            .vacant => {},
                            .occupied => |*slot_v| return .{ .index = self.idx, .gen = slot_v.gen },
                        }
                    }

                    return null;
                }

                pub fn nextValue(self: *@This()) ?V {
                    while (self.idx < self.map.slots.items.len) {
                        defer self.idx += 1;
                        const slot = &self.map.slots.items[self.idx];

                        switch (slot.*) {
                            .vacant => {},
                            .occupied => |*slot_v| return &slot_v.data,
                        }
                    }

                    return null;
                }
            };
        }

        pub const ConstIterator = Iter(*const Self, *const T);
        pub const Iterator = Iter(*Self, *T);

        pub const empty: Self = .{
            .slots = .empty,
            .count = 0,
        };

        pub fn deinit(self: *Self, gpa: Allocator) void {
            self.slots.deinit(gpa);
            self.* = undefined;
        }

        pub fn put(self: *Self, gpa: Allocator, key: K, value: T) error{OutOfMemory}!?T {
            if (key.index >= self.slots.items.len)
                try self.slots.appendNTimes(gpa, .vacant, key.index - self.slots.items.len + 1);

            return self.putAssumeCapacity(key, value);
        }

        pub fn putAssumeCapacity(self: *Self, key: K, value: T) ?T {
            std.debug.assert(key.index < self.slots.items.len);

            const slot = &self.slots.items[key.index];

            switch (slot.*) {
                .vacant => {
                    slot.* = .{ .occupied = .{ .data = value, .gen = key.gen } };
                    self.count += 1;
                    return null;
                },
                .occupied => |*slot_v| {
                    if (key.gen < slot_v.gen)
                        return null;

                    const prev_data = slot_v.data;
                    slot_v.data = value;
                    slot_v.gen = key.gen;
                    return prev_data;
                },
            }
        }

        pub fn getPtr(self: *const Self, key: K) ?*T {
            return switch (self.slots.items[key.index]) {
                .vacant => null,
                .occupied => |*slot| if (key.gen == slot.gen) &slot.data else null,
            };
        }

        pub fn get(self: Self, key: K) ?T {
            return switch (self.slots.items[key.index]) {
                .vacant => null,
                .occupied => |slot| if (key.gen == slot.gen) slot.data else null,
            };
        }

        pub fn hasKey(self: Self, key: K) bool {
            if (key.index >= self.slots.items.len)
                return false;

            return switch (self.slots.items[key.index]) {
                .vacant => false,
                .occupied => |*slot| key.gen == slot.gen,
            };
        }

        pub fn remove(self: *Self, key: K) ?T {
            if (key.index >= self.slots.items.len)
                return null;

            const slot = &self.slots.items[key.index];

            switch (slot.*) {
                .vacant => return null,
                .occupied => |*slot_v| {
                    if (key.gen != slot_v.gen)
                        return null;

                    const prev_data = slot_v.data;
                    slot.* = .vacant;
                    self.count -= 1;

                    return prev_data;
                },
            }
        }

        pub fn constIterator(self: Self) ConstIterator {
            return .{ .map = self, .idx = 0 };
        }

        pub fn iterator(self: *Self) Iterator {
            return .{ .map = self, .idx = 0 };
        }

        pub fn clone(self: Self, gpa: Allocator) !Self {
            return .{
                .slots = try self.slots.clone(gpa),
                .count = self.count,
            };
        }
    };
}

test {
    std.testing.refAllDecls(@This());
}
