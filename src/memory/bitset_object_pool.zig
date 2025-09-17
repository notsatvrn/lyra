const std = @import("std");
const lock = @import("utils").lock;
const memory = @import("../memory.zig");
const UsedSet = @import("UsedSet.zig");
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
            used_set: UsedSet,
        };

        bins: std.ArrayList(Bin) = .{},

        const Self = @This();

        // DEINIT

        pub fn deinit(self: *Self) void {
            for (self.bins.items) |*bin| {
                allocator.free(@as([*]T, @ptrCast(bin.objects))[0..]);
                bin.used_set.deinit(allocator);
            }
            self.bins.deinit(allocator);
            self.* = undefined;
        }

        // WHOLE BIN OPERATIONS

        inline fn addBin(self: *Self, n: usize) !void {
            const objects = try allocator.alloc(T, obj_count);
            var used_set = try UsedSet.init(allocator, obj_size);
            _ = used_set.claimRangeFast(n);

            try self.bins.append(allocator, .{
                .objects = @ptrCast(objects),
                .used_set = used_set,
            });
        }

        pub fn createBin(self: *Self) !*Objects {
            try self.addBin(obj_count);
            return self.bins.items[self.bins.items.len - 1].objects;
        }

        pub fn destroyBin(self: *Self, bin: *Objects) void {
            for (self.bins.items, 0..) |b, i| {
                if (bin != b.objects) continue;
                memory.allocator.free(b.objects);
                memory.allocator.free(b.used_set.ptr[0..obj_count]);
                self.bins.swapRemove(i);
                return;
            }
        }

        // SINGLE OBJECT OPERATIONS

        pub fn create(self: *Self) !*T {
            for (self.bins.items) |*bin|
                if (bin.used_set.claimRange(1)) |idx|
                    return &bin.objects[idx];

            try self.addBin(1); // add a bin with one allocated
            return &self.bins.items[self.bins.items.len - 1].objects[0];
        }

        pub fn destroy(self: *Self, object: *T) void {
            const addr = @intFromPtr(object);
            for (self.bins.items) |*bin| {
                const start = @intFromPtr(bin.objects);
                const end = start + bin_size;
                if (!(addr >= start and addr < end)) continue;
                const idx = (addr - start) / obj_size;
                bin.used_set.unclaimRange(idx, 1);
                return;
            }
        }

        // MULTIPLE OBJECT OPERATIONS

        pub fn createMany(self: *Self, n: usize) ![]T {
            if (n > obj_count) return error.TooManyObjects;
            // fast path: use a whole bin
            if (n == obj_count) {
                for (self.bins.items) |*bin| {
                    if (bin.used_set.used != 0) continue;
                    _ = bin.used_set.claimRangeFast(obj_count);
                    return @ptrCast(bin.objects);
                }
                return @ptrCast(try self.createBin());
            }

            for (self.bins.items) |*bin|
                if (bin.used_set.claimRange(n)) |idx|
                    return bin.objects[idx .. idx + n];

            try self.addBin(n); // add a bin with n allocated
            return self.bins.items[self.bins.items.len - 1].objects[0..n];
        }

        pub fn destroyMany(self: *Self, objects: []T) !void {
            if (objects.len > obj_count) return error.TooManyObjects;
            const start = @intFromPtr(objects.ptr);
            const end = start + (objects.len * obj_size);
            for (self.bins.items) |*bin| {
                const b_start = @intFromPtr(bin.objects);
                const b_end = start + bin_size;
                if (!(start >= b_start and end < b_end)) continue;
                const idx = (start - b_start) / obj_size;
                bin.used_set.unclaimRange(idx, objects.len);
                return;
            }
        }
    };
}
