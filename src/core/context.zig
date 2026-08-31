const std = @import("std");

// a generic fixed-size memory pool using a bitset.
// excellent for scenarios where you need to check if a specific index is active in o(1) time.
pub fn bitset_pool(comptime T: type, comptime capacity: usize) type {
    if (capacity == 0) @compileError("pool capacity must be greater than zero");
    if (@sizeOf(T) == 0) @compileError("pool element type must have non-zero size");
    if (capacity > std.math.maxInt(usize) / @sizeOf(T)) {
        @compileError("pool storage size overflows usize");
    }

    return struct {
        const Self = @This();

        // contiguous storage for all possible items.
        storage: [capacity]T = undefined,

        // bitset tracking which slots are available (1) or active (0).
        available_mask: std.StaticBitSet(capacity) = std.StaticBitSet(capacity).initFull(),

        // initializes the static pool.
        pub fn init() Self {
            return .{};
        }

        // acquires an unused slot from the pool in o(1) amortized time.
        // returns null if the pool is completely exhausted.
        pub fn acquire(self: *Self) ?*T {
            const free_index = self.available_mask.findFirstSet() orelse return null;
            self.available_mask.unset(free_index);
            return &self.storage[free_index];
        }

        // releases an active slot back into the pool.
        pub fn release(self: *Self, item: *const T) bool {
            const ptr_int = @intFromPtr(item);
            const base_int = @intFromPtr(&self.storage[0]);
            const element_size = @sizeOf(T);
            const end_int = base_int + element_size * capacity;

            if (ptr_int < base_int or ptr_int >= end_int) return false;
            const offset = ptr_int - base_int;
            if (offset % element_size != 0) return false;

            const index = offset / element_size;
            if (self.available_mask.isSet(index)) return false;
            self.available_mask.set(index);
            return true;
        }

        // returns the current number of active items.
        pub fn count_active(self: *const Self) usize {
            return capacity - self.available_mask.count();
        }
    };
}
