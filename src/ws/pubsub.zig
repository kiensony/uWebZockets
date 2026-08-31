const std = @import("std");
const WebSocket = @import("socket.zig").WebSocket;
const zslay = @import("zslay");

pub const max_topics = 1024;
pub const max_subscriptions = 8192;
pub const max_topic_length = 127;

pub const PubSubEngine = struct {
    topic_names: [max_topics][max_topic_length]u8 = undefined,
    topic_name_lengths: [max_topics]u8 = .{0} ** max_topics,
    topic_subscriber_counts: [max_topics]u16 = .{0} ** max_topics,
    sub_sockets: [max_subscriptions]*WebSocket = undefined,
    sub_topic_ids: [max_subscriptions]u16 = undefined,
    topic_count: usize = 0,
    sub_count: usize = 0,

    fn topic_name(self: *const PubSubEngine, topic_id: usize) []const u8 {
        return self.topic_names[topic_id][0..self.topic_name_lengths[topic_id]];
    }

    fn find_topic(self: *const PubSubEngine, name: []const u8) ?usize {
        for (0..self.topic_count) |topic_id| {
            if (std.mem.eql(u8, self.topic_name(topic_id), name)) return topic_id;
        }
        return null;
    }

    fn get_or_create_topic(self: *PubSubEngine, name: []const u8) !usize {
        if (self.find_topic(name)) |topic_id| return topic_id;
        if (name.len == 0) return error.EmptyTopic;
        if (name.len > max_topic_length) return error.TopicTooLong;
        if (self.topic_count >= max_topics) return error.TopicCapacityReached;

        const topic_id = self.topic_count;
        @memcpy(self.topic_names[topic_id][0..name.len], name);
        self.topic_name_lengths[topic_id] = @intCast(name.len);
        self.topic_subscriber_counts[topic_id] = 0;
        self.topic_count += 1;
        return topic_id;
    }

    pub fn subscribe(self: *PubSubEngine, socket: *WebSocket, topic: []const u8) !void {
        const existing_topic_id = self.find_topic(topic);

        if (existing_topic_id) |topic_id| {
            for (0..self.sub_count) |subscription_id| {
                if (self.sub_sockets[subscription_id] == socket and
                    self.sub_topic_ids[subscription_id] == topic_id)
                {
                    return;
                }
            }
        }

        if (self.sub_count >= max_subscriptions) return error.SubscriptionCapacityReached;
        const topic_id = existing_topic_id orelse try self.get_or_create_topic(topic);
        if (self.topic_subscriber_counts[topic_id] == std.math.maxInt(u16)) {
            return error.TopicSubscriberCapacityReached;
        }

        self.sub_sockets[self.sub_count] = socket;
        self.sub_topic_ids[self.sub_count] = @intCast(topic_id);
        self.sub_count += 1;
        self.topic_subscriber_counts[topic_id] += 1;
    }

    pub fn unsubscribe(self: *PubSubEngine, socket: *WebSocket, topic: []const u8) bool {
        const topic_id = self.find_topic(topic) orelse return false;

        for (0..self.sub_count) |subscription_id| {
            if (self.sub_sockets[subscription_id] != socket) continue;
            if (self.sub_topic_ids[subscription_id] != topic_id) continue;

            self.remove_subscription(subscription_id);
            if (self.topic_subscriber_counts[topic_id] == 0) self.remove_topic(topic_id);
            return true;
        }
        return false;
    }

    pub fn unsubscribe_all(self: *PubSubEngine, socket: *WebSocket) void {
        var subscription_id: usize = 0;
        while (subscription_id < self.sub_count) {
            if (self.sub_sockets[subscription_id] != socket) {
                subscription_id += 1;
                continue;
            }
            self.remove_subscription(subscription_id);
        }

        var topic_id: usize = 0;
        while (topic_id < self.topic_count) {
            if (self.topic_subscriber_counts[topic_id] != 0) {
                topic_id += 1;
                continue;
            }
            self.remove_topic(topic_id);
        }
    }

    pub fn publish(self: *PubSubEngine, topic: []const u8, message: []const u8, is_text: bool) usize {
        const topic_id = self.find_topic(topic) orelse return 0;
        const opcode: zslay.Opcode = if (is_text) .text else .binary;
        var delivered: usize = 0;

        for (0..self.sub_count) |subscription_id| {
            if (self.sub_topic_ids[subscription_id] != topic_id) continue;
            // A slow subscriber must not block delivery to bounded peers.
            self.sub_sockets[subscription_id].send(message, opcode) catch continue;
            delivered += 1;
        }
        return delivered;
    }

    fn remove_subscription(self: *PubSubEngine, subscription_id: usize) void {
        const topic_id = self.sub_topic_ids[subscription_id];
        self.topic_subscriber_counts[topic_id] -= 1;

        self.sub_count -= 1;
        if (subscription_id == self.sub_count) return;
        self.sub_sockets[subscription_id] = self.sub_sockets[self.sub_count];
        self.sub_topic_ids[subscription_id] = self.sub_topic_ids[self.sub_count];
    }

    fn remove_topic(self: *PubSubEngine, topic_id: usize) void {
        std.debug.assert(self.topic_subscriber_counts[topic_id] == 0);

        self.topic_count -= 1;
        if (topic_id == self.topic_count) {
            self.topic_name_lengths[topic_id] = 0;
            return;
        }

        const moved_topic_id = self.topic_count;
        const moved_name = self.topic_name(moved_topic_id);
        @memcpy(self.topic_names[topic_id][0..moved_name.len], moved_name);
        self.topic_name_lengths[topic_id] = self.topic_name_lengths[moved_topic_id];
        self.topic_subscriber_counts[topic_id] = self.topic_subscriber_counts[moved_topic_id];
        self.topic_name_lengths[moved_topic_id] = 0;

        for (self.sub_topic_ids[0..self.sub_count]) |*subscription_topic_id| {
            if (subscription_topic_id.* == moved_topic_id) {
                subscription_topic_id.* = @intCast(topic_id);
            }
        }
    }
};
