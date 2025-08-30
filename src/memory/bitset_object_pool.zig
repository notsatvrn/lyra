const std = @import("std");
const lock = @import("utils").lock;
const memory = @import("../memory.zig");
const allocator = memory.allocator;

pub const Config = struct {
    /// Minimum number of objects per bin.
    min_objects: usize = 512,

    /// Minimum number of pages per bin.
    min_pages: usize = 1,
};

pub fn BitSetObjectPool(comptime T: type, comptime config: Config) type {
    return struct {
        const obj_size: usize = @sizeOf(T);
        // Objects will be at least min_objects, and more if they'll all fit in min_pages.
        pub const obj_count = @max(config.min_objects, (config.min_pages * memory.min_page_size) / obj_size);
        const pages = memory.pagesNeeded(obj_size * obj_count, .small);
        const bin_size = pages * memory.min_page_size;

        pub const Objects = [obj_count]T;
        pub const FreeSet = std.bit_set.StaticBitSet(obj_count);
        pub const Bin = struct {
            objects: *Objects,
            free_set: FreeSet,
        };

        bins: std.ArrayListUnmanaged(Bin) = .{},

        const Self = @This();

        // WHOLE BIN OPERATIONS

        inline fn addBin(self: *Self, free: bool) !void {
            const objects = try allocator.alloc(T, obj_count);
            try self.bins.append(allocator, .{
                .objects = @ptrCast(objects),
                .free_set = if (free) .initFull() else .initEmpty(),
            });
        }

        pub fn createBin(self: *Self) !*Objects {
            try self.addBin(false);
            return self.bins.items[self.bins.items.len - 1].objects;
        }

        pub fn destroyBin(self: *Self, bin: *Objects) void {
            for (self.bins.items, 0..) |b, i| {
                if (bin != b.objects) continue;
                memory.allocator.free(b.objects);
                self.bins.swapRemove(i);
                return;
            }
        }

        // SINGLE OBJECT OPERATIONS

        inline fn fromBin(bin: *Bin) ?*T {
            const obj_idx = bin.free_set.findFirstSet() orelse return null;
            bin.free_set.unset(obj_idx);
            return &bin.objects[obj_idx];
        }

        pub fn create(self: *Self) !*T {
            for (self.bins.items) |*bin|
                if (fromBin(bin)) |obj|
                    return obj;

            try self.addBin(true);
            return fromBin(&self.bins.items[self.bins.items.len - 1]).?;
        }

        pub fn destroy(self: *Self, object: *T) void {
            const addr = @intFromPtr(object);
            for (self.bins.items) |*bin| {
                const start = @intFromPtr(bin.objects);
                const end = start + bin_size;
                if (!(addr >= start and addr < end)) continue;
                bin.free_set.set((addr - start) / obj_size);
                return;
            }
        }

        // MULTIPLE OBJECT OPERATIONS

        pub fn createMany(self: *Self, n: usize) ![]T {
            if (n > obj_count) return error.TooManyObjects;
            // fast path: use a whole bin
            if (n == obj_count) {
                for (self.bins.items) |b|
                    if (b.free_set.count() == obj_count)
                        return @ptrCast(b.objects);

                return @ptrCast(try self.createBin());
            }

            try self.addBin(true);
            const bin = &self.bins.items[self.bins.items.len - 1];
            const range = std.bit_set.Range{ .start = 0, .end = n };
            bin.free_set.setRangeValue(range, true);

            return bin.objects[0..n];
        }
    };
}
