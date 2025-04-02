//! A set of collections, mainly based on trees.

const RBTree = @import("util/trees/rb.zig").RBTree;
const AVLTree = @import("util/trees/avl.zig").AVLTree;

const std = @import("std");
const Order = std.math.Order;

const memory = @import("memory.zig");
const Lock = @import("util/lock.zig").SharedLock;

// TREE

pub const TreeType = enum { rb, avl };

pub fn Tree(
    comptime T: type,
    comptime cmp: fn (T, T) Order,
    comptime typ: TreeType,
) type {
    return struct {
        const Self = @This();
        const Impl = if (typ == .rb)
            RBTree(T, cmp)
        else
            AVLTree(T, cmp);

        pub const Node = Impl.Node;

        inner: Impl = .{},
        lock: Lock = .{},

        // RE-EXPORTS

        pub inline fn findNode(self: *Self, value: T) ?*Node {
            self.lock.lockShared();
            defer self.lock.unlockShared();
            return self.inner.findNode(value);
        }

        pub inline fn insert(self: *Self, value: T) !void {
            self.lock.lock();
            defer self.lock.unlock();
            try self.inner.insert(value);
        }

        pub inline fn remove(self: *Self, value: T) bool {
            self.lock.lock();
            defer self.lock.unlock();
            return self.inner.delete(value);
        }

        // EXTRA METHODS

        pub inline fn contains(self: Self, value: T) bool {
            return self.findNode(value) != null;
        }

        pub inline fn min(self: Self) ?*Node {
            self.lock.lockShared();
            defer self.lock.unlockShared();
            if (self.inner.root) |root| {
                return root.?.min();
            } else return null;
        }

        pub inline fn max(self: Self) ?*Node {
            self.lock.lockShared();
            defer self.lock.unlockShared();
            if (self.inner.root) |root| {
                return root.?.max();
            } else return null;
        }

        // ITERATOR

        pub inline fn iterator(self: *Self) Iterator {
            return .{ .tree = self, .stack = std.ArrayList(*Node).init(memory.allocator) };
        }

        pub const Iterator = struct {
            tree: *Self,
            lock_held: bool = false,

            stack: std.ArrayList(*Node),
            exhausted: bool = false,

            pub fn next(self: *Iterator) !?T {
                if (self.exhausted) return null;

                var node: *Node = undefined;
                if (self.stack.pop()) |n| {
                    node = n;
                } else {
                    if (self.tree.inner.root == null) {
                        self.exhausted = true;
                        return null;
                    }

                    if (!self.lock_held) {
                        self.tree.lock.lockShared();
                        self.lock_held = true;
                    }

                    node = self.tree.inner.root.?;
                }

                if (node.left) |left| try self.stack.append(left);
                if (node.right) |right| try self.stack.append(right);

                if (self.stack.items.len == 0) {
                    self.tree.lock.unlockShared();
                    self.lock_held = false;
                    self.exhausted = true;
                }

                return node.value;
            }

            pub fn reset(self: *Iterator) void {
                if (self.lock_held) {
                    self.tree.lock.unlockShared();
                    self.lock_held = false;
                }

                if (!self.exhausted) {
                    self.stack.clearRetainingCapacity();
                } else self.exhausted = false;
            }

            pub fn deinit(self: *Iterator) void {
                self.reset();
                self.stack.deinit();
            }
        };
    };
}

// TREE MAP

pub fn TreeMap(
    comptime K: type,
    comptime V: type,
    comptime cmp: fn (K, K) Order,
    comptime typ: TreeType,
) type {
    return struct {
        const Self = @This();
        const TreeT = Tree(KV, cmpKV, typ);

        tree: TreeT = .{},

        const KV = struct { key: K, value: V };
        fn cmpKV(kv1: KV, kv2: KV) Order {
            return cmp(kv1.key, kv2.key);
        }

        // READING

        pub inline fn get(self: Self, key: K) ?V {
            return (self.getEntry(key) orelse return null).value;
        }

        pub fn getEntry(self: Self, key: K) ?*KV {
            const needle = KV{ .key = key, .value = undefined };
            const node = self.tree.findNode(needle) orelse return null;
            return node.value;
        }

        pub inline fn contains(self: Self, key: K) bool {
            return self.getEntry(key) != null;
        }

        // WRITING

        pub inline fn put(self: *Self, key: K, value: V) !void {
            try self.tree.insert(.{ .key = key, .value = value });
        }

        pub inline fn remove(self: *Self, key: K) bool {
            return self.tree.remove(.{ .key = key, .value = undefined });
        }

        // ITERATOR

        pub inline fn iterator(self: *Self) Iterator {
            return self.tree.iterator();
        }

        pub const Iterator = TreeT.Iterator;
    };
}

// MULTI HASH MAP

pub fn AutoMultiHashMap(comptime K: type, comptime V: type) type {
    return MultiHashMap(K, V, std.hash_map.AutoContext(K), std.hash_map.default_max_load_percentage);
}

pub fn StringMultiHashMap(comptime T: type) type {
    return MultiHashMap([]const u8, T, std.hash_map.StringContext, std.hash_map.default_max_load_percentage);
}

pub fn MultiHashMap(comptime K: type, comptime V: type, comptime Context: type, comptime max_load_percentage: u64) type {
    const Map = std.HashMapUnmanaged(K, std.ArrayListUnmanaged(V), Context, max_load_percentage);

    return struct {
        inner: Map,
    };
}
