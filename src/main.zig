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
const pg = @import("pg");
const serve = @import("./serve.zig");

const log = std.log.scoped(.main);

const query_leaderboard_all = "select u.user_id, u.username, count(*) from votes v join users u on v.submitter = u.internal_user_id group by v.submitter, u.user_id, u.username order by count(*) desc limit 20;";

pub const Data = struct {
    leaderboard_all: LeaderboardAllData,
    path_prefix: []const u8,
    stylesheet: []const u8,
    last_updated: i64,
};

pub const LeaderboardAllData = struct {
    rows: [20]LeaderboardCacheRow,
    row_count: usize,
};

pub const LeaderboardCacheRow = struct {
    user_id: []const u8,
    username: ?[]const u8,
    count: i64,
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{.thread_safe = true,}) {};
    defer std.debug.assert(gpa.deinit() == .ok);
    const allocator = gpa.allocator();

    var pool = pool: {
        const database_name = try std.process.getEnvVarOwned(allocator, "DATABASE_NAME");
        defer allocator.free(database_name);
        const database_username = try std.process.getEnvVarOwned(allocator, "DATABASE_USERNAME");
        defer allocator.free(database_username);
        const database_password = try std.process.getEnvVarOwned(allocator, "DATABASE_PASSWORD");
        defer allocator.free(database_password);

        break :pool try pg.Pool.init(allocator, .{
          .auth = .{
            .username = database_username,
            .database = database_name,
            .password = database_password,
          }
        });
    };
    defer pool.deinit();

    const conn = try pool.acquire();
    defer pool.release(conn);

    log.info("Connected to database.", .{});

    const data = builddata: {
        const path_prefix = try std.process.getEnvVarOwned(allocator, "PATH_PREFIX");
        errdefer allocator.free(path_prefix);

        var result = conn.query(query_leaderboard_all, .{}) catch |err| {
            if (err == error.PG) {
                if (conn.err) |pge| {
                    log.err("PostgreSQL error: {s}\n", .{pge.message});
                }
            }

            return err;
        };
        defer result.deinit();

        var data_rows = LeaderboardAllData { .rows = .{undefined} ** 20, .row_count = 0, };
        var i: usize = 0;

        errdefer {
            for (0..i) |j| {
                const row = data_rows.rows[j];

                allocator.free(row.user_id);

                if (row.username) |username| {
                    allocator.free(username);
                }
            }
        }

        while (try result.next()) |row| {
            if (i >= 20) {
                continue;
            }

            // u.user_id, u.username, count(*)
            const user_id = try allocator.dupe(u8, row.get([]u8, 0));
            errdefer allocator.free(user_id);
            const username = row.get(?[]u8, 1);

            const final_username: ?[]u8 = if (username == null or username.?.len == 0) null else
                try allocator.dupe(u8, username.?);

            const count = row.get(i64, 2);

            data_rows.rows[i] = LeaderboardCacheRow {
                .user_id = user_id,
                .username = final_username,
                .count = count,
            };
            i += 1;
        }

        data_rows.row_count = i;

        var file = try std.fs.cwd().openFile("public/style.css", .{});
        defer file.close();
        const stylesheet = try file.readToEndAlloc(allocator, 16384);
        errdefer allocator.free(stylesheet);

        var last_updated_file = try std.fs.cwd().openFile("last_updated", .{});
        defer last_updated_file.close();
        const last_updated_timestamp = (try last_updated_file.metadata()).modified();

        break :builddata Data {
            .leaderboard_all = data_rows,
            .path_prefix = path_prefix,
            .stylesheet = stylesheet,
            // Convert from nanoseconds since Unix epoch to seconds since Unix epoch
            .last_updated = @as(i64, @intCast(@divTrunc(last_updated_timestamp, 1_000_000_000))),
        };
    };

    defer {
        allocator.free(data.stylesheet);

        for (0..data.leaderboard_all.row_count) |i| {
            const row = data.leaderboard_all.rows[i];
            allocator.free(row.user_id);

            if (row.username) |username| {
                allocator.free(username);
            }
        }

        allocator.free(data.path_prefix);
    }

    log.info("Data rows: {d}", .{data.leaderboard_all.row_count});

    {
        var listen_port_number: u16 = 3000;

        if (try std.process.hasEnvVar(allocator, "LISTEN_PORT")) {
            const listen_port = try std.process.getEnvVarOwned(allocator, "LISTEN_PORT");
            defer allocator.free(listen_port);
            listen_port_number = try std.fmt.parseInt(u16, listen_port, 10);
        }

        const address = try std.net.Address.resolveIp("127.0.0.1", listen_port_number);
        var http_server = try address.listen(.{});
        log.info("Listening on {}", .{address});

        var connection_arena = std.heap.ArenaAllocator.init(allocator);
        defer connection_arena.deinit();
        const connection_allocator = connection_arena.allocator();

        var read_buffer: [8192]u8 = undefined;
        accept: while (true) {
            defer _ = connection_arena.reset(.{.retain_with_limit = 16384});

            const connection = try http_server.accept();
            defer connection.stream.close();

            var request_arena = std.heap.ArenaAllocator.init(connection_allocator);
            defer request_arena.deinit();
            const request_allocator = request_arena.allocator();

            var server = std.http.Server.init(connection, &read_buffer);
            while (server.state == .ready) {
                defer _ = request_arena.reset(.retain_capacity);

                var request = server.receiveHead() catch |err| switch(err) {
                    error.HttpConnectionClosing => continue :accept,
                    else => {
                        log.err("Receive head error: {s}", .{@errorName(err)});
                        continue :accept;
                    },
                };
                try serve.serve(request_allocator, &data, &request);
            }
        }
    }
}

test {
    std.testing.refAllDeclsRecursive(@This());
}
