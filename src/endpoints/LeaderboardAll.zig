// dearrow-locked-titles-leaderboard - webserver
// Copyright (C) 2024  mschae23
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU Affero General Public License for more details.
//
// You should have received a copy of the GNU Affero General Public License
// along with this program.  If not, see <https://www.gnu.org/licenses/>.

const std = @import("std");
const zap = @import("zap");
const root = @import("../main.zig");

const log = std.log.scoped(.leaderboard_all);

pub const Self = @This();

allocator: std.mem.Allocator,
ep: zap.Endpoint,
data: *const root.Data,

pub fn init(allocator: std.mem.Allocator, path: []const u8, data: *const root.Data) Self {
    return .{
        .allocator = allocator,
        .data = data,
        .ep = zap.Endpoint.init(.{
            .path = path,
            .get = getLeaderboard,
        }),
    };
}

pub fn deinit(self: *Self) void {
    _ = self;
}

pub fn endpoint(self: *Self) *zap.Endpoint {
    return &self.ep;
}

fn getLeaderboard(e: *zap.Endpoint, r: zap.Request) void {
    const self: *Self = @fieldParentPtr("ep", e);

    if (r.path) |path| {
        if (path.len == e.settings.path.len) {
            const body = body: {
                errdefer {
                    r.setStatus(.internal_server_error);
                    r.sendBody("<!DOCTYPE html><html><head><meta charset=\"UTF-8\"/><meta name=\"viewport\" content=\"width=device-width\"/><title>Internal server error – DeArrow locked titles leaderboard</title></head><body><h1>500 Internal server error</h1></body></html>") catch {};
                }

                const head_fmt =
                    \\<!DOCTYPE html><html><head><meta charset="UTF-8"/><meta name="viewport" content="width=device-width"/><title>DeArrow locked titles leaderboard</title><link rel="stylesheet" type="text/css" href="{s}style.css"><link rel="icon" href="https://dearrow.ajay.app/favicon-32x32.png?v=6f203adf3dc83cd564c279fa5c263c62" type="image/png"></head><body><header id="title"><a href="https://dearrow.ajay.app/"><img class="sb-logo" src="https://dearrow.ajay.app/logo.svg"></a><h1>DeArrow locked titles leaderboard</h1></header><div id="main"><table class="userstats"><tbody><tr><th>Rank</th><th title="User ID is shown where the username is not set.">Username</th><th>Count</th></tr>
                    ;

                const row_fmt =
                    \\<tr><td>{d}</td><td><a href="https://dearrow.minibomba.pro/user_id/{s}">{s}</a></td><td>{d}</td></tr>
                    ;

                const tail =
                    \\</tbody></table></div><footer id="attribution">Leaderboard data was last updated 2024-05-19 18:27 UTC. Uses DeArrow data licensed used under <a href="https://creativecommons.org/licenses/by-nc-sa/4.0/">CC BY-NC-SA 4.0</a> from <a href="https://dearrow.ajay.app/">https://dearrow.ajay.app/</a>.</footer></body></html>
                    ;

                var body = std.ArrayListUnmanaged(u8).initCapacity(self.allocator, head_fmt.len + tail.len) catch |err| {
                    log.err("Error creating array list for response body: {}", .{err});
                    return;
                };
                errdefer body.deinit(self.allocator);

                std.fmt.format(body.writer(self.allocator), head_fmt, .{self.data.path_prefix}) catch |err| {
                    log.err("Error writing into response body: {}", .{err});
                    return;
                };

                for (0..self.data.leaderboard_all.row_count) |i| {
                    const row = self.data.leaderboard_all.rows[i];

                    const unsanitized_username = if (row.username) |username| username else row.user_id;
                    var replacement_size = std.mem.replacementSize(u8, unsanitized_username, "&", "&amp;");
                    var final_username = std.ArrayListUnmanaged(u8).initCapacity(self.allocator, replacement_size) catch |err| {
                        log.err("Error while allocating memory: {}", .{err});
                        return;
                    };
                    defer final_username.deinit(self.allocator);
                    final_username.items.len = replacement_size;
                    _ = std.mem.replace(u8, unsanitized_username, "&", "&amp;", final_username.items);

                    replacement_size = std.mem.replacementSize(u8, final_username.items, "<", "&lt;");
                    var temp_buf = std.ArrayListUnmanaged(u8).initCapacity(self.allocator, replacement_size) catch |err| {
                        log.err("Error while allocating memory: {}", .{err});
                        return;
                    };
                    defer temp_buf.deinit(self.allocator);
                    temp_buf.items.len = replacement_size;
                    _ = std.mem.replace(u8, final_username.items, "<", "&lt;", temp_buf.items);

                    replacement_size = std.mem.replacementSize(u8, temp_buf.items, ">", "&gt;");
                    final_username.ensureTotalCapacity(self.allocator, replacement_size) catch |err| {
                        log.err("Error while allocating memory: {}", .{err});
                        return;
                    };
                    final_username.items.len = replacement_size;
                    _ = std.mem.replace(u8, temp_buf.items, ">", "&gt;", final_username.items);

                    replacement_size = std.mem.replacementSize(u8, final_username.items, "\"", "&quot;");
                    temp_buf.ensureTotalCapacity(self.allocator, replacement_size) catch |err| {
                        log.err("Error while allocating memory: {}", .{err});
                        return;
                    };
                    temp_buf.items.len = replacement_size;
                    _ = std.mem.replace(u8, final_username.items, "\"", "&quot;", temp_buf.items);

                    replacement_size = std.mem.replacementSize(u8, temp_buf.items, "'", "&#39;");
                    final_username.ensureTotalCapacity(self.allocator, replacement_size) catch |err| {
                        log.err("Error while allocating memory: {}", .{err});
                        return;
                    };
                    final_username.items.len = replacement_size;
                    _ = std.mem.replace(u8, temp_buf.items, "'", "&#39;", final_username.items);

                    std.fmt.format(body.writer(self.allocator), row_fmt, .{i + 1, row.user_id, final_username.items, row.count, }) catch |err| {
                        log.err("Error writing into response body: {}", .{err});
                        return;
                    };
                }

                const slice = body.addManyAsSlice(self.allocator, tail.len) catch |err| {
                    log.err("Error writing into response body: {}", .{err});
                    return;
                };
                @memcpy(slice, tail);

                break :body body.toOwnedSlice(self.allocator) catch |err| {
                    log.err("Error finalizing response body: {}", .{err});
                    return;
                };
            };
            defer self.allocator.free(body);

            r.sendBody(body) catch return;
            return;
        }

        r.setStatus(.not_found);
        r.sendBody("<!DOCTYPE html><html><head><meta charset=\"UTF-8\"/><meta name=\"viewport\" content=\"width=device-width\"/><title>Not found – DeArrow locked titles leaderboard</title></head><body><h1>404 Not found</h1></body></html>") catch return;
    }
}
