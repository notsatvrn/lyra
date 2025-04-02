//! An implementation of the AVL tree, a self-balancing BST.
//!
//! Based on:
//! - https://github.com/msambol/dsa/blob/master/trees/avl_tree.py
//! - https://www.geeksforgeeks.org/deletion-in-an-avl-tree/

const std = @import("std");
const Order = std.math.Order;

const memory = @import("../../memory.zig");

// NODE

pub fn AVLNode(comptime T: type) type {
    return struct {
        const Self = @This();

        value: T,
        height: isize = 1,

        // left < self < right
        left: ?*Self = null,
        right: ?*Self = null,

        // SEARCHING

        pub fn min(x: *Self) *Self {
            var out = x;
            while (out.left != null)
                out = out.left.?;

            return x;
        }

        pub fn max(x: *Self) *Self {
            var out = x;
            while (out.right != null)
                out = out.right.?;

            return x;
        }
    };
}

// TREE

pub fn AVLTree(comptime T: type, comptime cmp: fn (T, T) Order) type {
    return struct {
        const Self = @This();
        pub const Node = AVLNode(T);
        const Pool = std.heap.MemoryPoolExtra(Node, .{ .alignment = @alignOf(Node) });

        pool: Pool = Pool.init(memory.allocator),
        root: ?*Node = null,

        // SEARCHING

        pub fn findNode(self: Self, value: T) ?*Node {
            var current = self.root;
            if (current == null) return null;
            var ord = cmp(value, current.?.value);

            while (true) {
                current = switch (ord) {
                    .lt => current.?.left,
                    .gt => current.?.right,
                    .eq => return current,
                };

                if (current == null) return null;
                ord = cmp(value, current.?.value);
            }
        }

        // ROTATION

        inline fn height(node: ?*Node) isize {
            return if (node) |n| n.height else 0;
        }

        fn leftRotate(node: *Node) *Node {
            const b = node.right.?;
            const y = b.left.?;

            b.left = node;
            node.right = y;

            node.height = 1 + @max(height(node.left), height(node.right));
            b.height = 1 + @max(height(b.left), height(b.right));

            return b;
        }

        fn rightRotate(node: *Node) *Node {
            const a = node.left.?;
            const y = a.right.?;

            a.right = node;
            node.left = y;

            node.height = 1 + @max(height(node.left), height(node.right));
            a.height = 1 + @max(height(a.left), height(a.right));

            return a;
        }

        // INSERTION

        inline fn getBalance(node: ?*Node) isize {
            if (node) |n| {
                return height(n.left) - height(n.right);
            } else return 0;
        }

        fn insertRoot(self: *Self, r: ?*Node, value: T) !*Node {
            if (r == null) {
                const node = try self.pool.create();
                node.* = .{ .value = value };
                return node;
            }

            const root = r.?;

            switch (cmp(value, root.value)) {
                .lt => root.left = try self.insertRoot(root.left, value),
                .gt => root.right = try self.insertRoot(root.right, value),
                .eq => {
                    root.value = value;
                    return root;
                },
            }

            root.height = 1 + @max(height(root.left), height(root.right));

            const balance = getBalance(root);

            if (root.left) |left| {
                if (balance > 1) switch (cmp(value, left.value)) {
                    .lt => return rightRotate(root),
                    .gt => {
                        root.left = leftRotate(left);
                        return rightRotate(root);
                    },
                    .eq => {},
                    //.eq => left.value = value,
                };
            }

            if (root.right) |right| {
                if (balance < -1) switch (cmp(value, right.value)) {
                    .gt => return leftRotate(root),
                    .lt => {
                        root.right = rightRotate(right);
                        return leftRotate(root);
                    },
                    .eq => {},
                    //.eq => right.value = value,
                };
            }

            return root;
        }

        pub inline fn insert(self: *Self, value: T) !void {
            self.root = try self.insertRoot(self.root, value);
        }

        // DELETION

        fn deleteRoot(self: *Self, r: ?*Node, value: T) ?*Node {
            const root = r orelse return null;

            switch (cmp(value, root.value)) {
                .lt => root.left = self.deleteRoot(root.left, value),
                .gt => root.right = self.deleteRoot(root.right, value),
                .eq => {
                    if (root.left == null) {
                        const temp = root.right;
                        self.pool.destroy(root);
                        return temp;
                    } else if (root.right == null) {
                        const temp = root.left;
                        self.pool.destroy(root);
                        return temp;
                    }

                    const temp = root.right.?.min();
                    root.value = temp.value;
                    root.right = self.deleteRoot(root.right, temp.value);
                },
            }

            root.height = 1 + @max(height(root.left), height(root.right));

            const balance = getBalance(root);

            if (root.left) |left| {
                if (balance > 1) {
                    if (getBalance(left) < 0)
                        root.left = leftRotate(left);
                    return rightRotate(root);
                }
            }

            if (root.right) |right| {
                if (balance < -1) {
                    if (getBalance(right) > 0)
                        root.right = rightRotate(right);
                    return leftRotate(root);
                }
            }

            return root;
        }

        pub fn delete(self: *Self, value: T) bool {
            const old_root = self.root;
            self.root = self.deleteRoot(self.root, value);
            if (self.root == null) return false;
            return self.root.? != old_root.?;
        }
    };
}
