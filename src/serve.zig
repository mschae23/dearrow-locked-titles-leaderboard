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
const chrono = @import("chrono");
const root = @import("./main.zig");
const utils = @import("./utils.zig");

const log = std.log.scoped(.server);

pub const ServeError = std.mem.Allocator.Error || std.http.Server.Response.WriteError || std.fmt.ParseIntError || utils.FormatHttpDateError;

pub const CACHE_CONTROL = "max-age=86400, stale-while-revalidate=604800";
pub const FILE_CACHE_CONTROL = "max-age=86400, stale-while-revalidate=604800";

pub fn serve(allocator: std.mem.Allocator, data: *const root.Data, request: *std.http.Server.Request) ServeError!void {
    const http_date = date: {
        const timestamp = std.time.timestamp();
        break :date utils.formatHttpDateAlloc(allocator, timestamp) catch return try request.respond("500 Internal server error", .{
            .status = .internal_server_error,
            .extra_headers = &.{
                .{ .name = "content-type", .value = "text/plain", },
            },
        });
    };

    if (std.mem.eql(u8, request.head.target, "/") and (request.head.method == .GET or request.head.method == .HEAD)) {
        const modified_days_since_epoch: i32 = @intCast(@divFloor(data.last_updated, std.time.s_per_day));
        const ymd = chrono.date.YearMonthDay.fromDaysSinceUnixEpoch(modified_days_since_epoch);
        const time = try chrono.Time.fromNumSecondsFromMidnight(@intCast(@mod(data.last_updated, std.time.s_per_day)), 0);

        const http_last_modified = date: {
            break :date utils.formatHttpDateAlloc(allocator, data.last_updated) catch return try request.respond("500 Internal server error", .{
                .status = .internal_server_error,
                .extra_headers = &.{
                    .{ .name = "content-type", .value = "text/plain", },
                },
            });
        };

        if (request.head.method == .HEAD) {
            try request.respond("", .{
                .extra_headers = &.{
                    .{ .name = "content-type", .value = "text/html", },
                    .{ .name = "date", .value = http_date, },
                    .{ .name = "last-modified", .value = http_last_modified, },
                    .{ .name = "cache-control", .value = CACHE_CONTROL, },
                 },
            });
        }

        cache: {
            var headers = request.iterateHeaders();

            while (headers.next()) |header| {
                if (std.ascii.eqlIgnoreCase(header.name, "if-modified-since")) {
                    const provided_timestamp = utils.parseHttpDate(header.value) catch return try request.respond("500 Internal server error", .{
                        .status = .internal_server_error,
                        .extra_headers = &.{
                            .{ .name = "content-type", .value = "text/plain", },
                        },
                    });

                    if (provided_timestamp >= data.last_updated) {
                        try request.respond("", .{
                            .status = .not_modified,
                            .extra_headers = &.{
                                .{ .name = "date", .value = http_date, },
                                .{ .name = "last-modified", .value = http_last_modified, },
                                .{ .name = "cache-control", .value = CACHE_CONTROL, },

                            },
                        });
                        return;
                    }

                    break :cache;
                }
            }
        }

        var send_buffer: [8192]u8 = .{undefined} ** 8192;

        var response = request.respondStreaming(.{
            .send_buffer = &send_buffer,
            .respond_options = .{
                .extra_headers = &.{
                    .{ .name = "content-type", .value = "text/html", },
                    .{ .name = "date", .value = http_date, },
                    .{ .name = "last-modified", .value = http_last_modified, },
                    .{ .name = "cache-control", .value = CACHE_CONTROL, },
             },
            }
        });
        const writer = response.writer();

        {
            const head_fmt =
                \\<!DOCTYPE html><html><head><meta charset="UTF-8"/><meta name="viewport" content="width=device-width"/><title>DeArrow locked titles leaderboard</title><link rel="stylesheet" type="text/css" href="{s}style.css"><link rel="icon" href="https://dearrow.ajay.app/favicon-32x32.png?v=6f203adf3dc83cd564c279fa5c263c62" type="image/png"></head><body><header id="title"><a href="https://dearrow.ajay.app/"><img class="sb-logo" src="https://dearrow.ajay.app/logo.svg" alt="DeArrow icon"></a><h1>DeArrow locked titles leaderboard</h1></header><div id="main"><table class="userstats"><tbody><tr><th>Rank</th><th title="User ID is shown where the username is not set.">Username</th><th>Count</th></tr>
                ;

            const row_fmt =
                \\<tr><td>{d}</td><td><a href="https://dearrow.minibomba.pro/user_id/{s}">{s}</a></td><td>{d}</td></tr>
                ;

            const tail_fmt =
                \\</tbody></table></div><footer id="attribution"><a href="https://mschae23.de/git/mschae23/dearrow-locked-titles-leaderboard/">DeArrow locked titles leaderboard</a> Copyright (C) 2024 mschae23. Licensed under <a href="https://www.gnu.org/licenses/agpl-3.0.html">GNU AGPL v3</a> (or any later version).<br>Leaderboard data was last updated {s} {s} UTC. Uses DeArrow data licensed under <a href="https://creativecommons.org/licenses/by-nc-sa/4.0/">CC BY-NC-SA 4.0</a> from <a href="https://dearrow.ajay.app/">https://dearrow.ajay.app/</a>.</footer></body></html>
                ;

            std.fmt.format(writer, head_fmt, .{data.path_prefix}) catch |err| {
                log.err("Error writing into response body: {}", .{err});
                return;
            };

            for (0..data.leaderboard_all.row_count) |i| {
                const row = data.leaderboard_all.rows[i];

                const unsanitized_username = if (row.username) |username| username else row.user_id;
                var sanitized_username = std.ArrayListUnmanaged(u8).initCapacity(allocator, unsanitized_username.len) catch |err| {
                    log.err("Error allocating memory: {}", .{err});
                    return;
                };
                defer sanitized_username.deinit(allocator);

                for (unsanitized_username) |username_byte| {
                    switch (username_byte) {
                        '&' => @memcpy(sanitized_username.addManyAsSlice(allocator, 5) catch |err| {
                            log.err("Error allocating memory: {}", .{err});
                            return;
                        }, "&amp;"),
                        '<' => @memcpy(sanitized_username.addManyAsSlice(allocator, 4) catch |err| {
                            log.err("Error allocating memory: {}", .{err});
                            return;
                        }, "&lt;"),
                        '>' => @memcpy(sanitized_username.addManyAsSlice(allocator, 4) catch |err| {
                            log.err("Error allocating memory: {}", .{err});
                            return;
                        }, "&gt;"),
                        '"' => @memcpy(sanitized_username.addManyAsSlice(allocator, 6) catch |err| {
                            log.err("Error allocating memory: {}", .{err});
                            return;
                        }, "&quot;"),
                        '\'' => @memcpy(sanitized_username.addManyAsSlice(allocator, 5) catch |err| {
                            log.err("Error allocating memory: {}", .{err});
                            return;
                        }, "&#39;"),
                        else => (sanitized_username.addOne(allocator) catch |err| {
                            log.err("Error allocating memory: {}", .{err});
                            return;
                        }).* = username_byte,
                    }
                }

                std.fmt.format(writer, row_fmt, .{i + 1, row.user_id, sanitized_username.items, row.count, }) catch |err| {
                    log.err("Error writing into response body: {}", .{err});
                    return;
                };
            }

            std.fmt.format(writer, tail_fmt, .{ymd, time}) catch |err| {
                log.err("Error writing into response body: {}", .{err});
                return;
            };
        }

        try response.end();
        return;
    } else if (std.mem.eql(u8, request.head.target, "/style.css")) {
        const http_last_modified = date: {
            break :date utils.formatHttpDateAlloc(allocator, data.stylesheet.last_modified) catch return try request.respond("500 Internal server error", .{
                .status = .internal_server_error,
                .extra_headers = &.{
                    .{ .name = "content-type", .value = "text/plain", },
                },
            });
        };

        if (request.head.method == .HEAD) {
            try request.respond("", .{
                .extra_headers = &.{
                    .{ .name = "content-type", .value = "text/html", },
                    .{ .name = "date", .value = http_date, },
                    .{ .name = "last-modified", .value = http_last_modified, },
                    .{ .name = "cache-control", .value = FILE_CACHE_CONTROL, },
                 },
            });
        }

        cache: {
            var headers = request.iterateHeaders();

            while (headers.next()) |header| {
                if (std.ascii.eqlIgnoreCase(header.name, "if-modified-since")) {
                    const provided_timestamp = utils.parseHttpDate(header.value) catch return try request.respond("500 Internal server error", .{
                        .status = .internal_server_error,
                        .extra_headers = &.{
                            .{ .name = "content-type", .value = "text/plain", },
                        },
                    });

                    if (provided_timestamp >= data.last_updated) {
                        try request.respond("", .{
                            .status = .not_modified,
                            .extra_headers = &.{
                                .{ .name = "date", .value = http_date, },
                                .{ .name = "last-modified", .value = http_last_modified, },
                                .{ .name = "cache-control", .value = FILE_CACHE_CONTROL, },

                            },
                        });
                        return;
                    }

                    break :cache;
                }
            }
        }

        try request.respond(data.stylesheet.contents, .{
            .extra_headers = &.{
                .{ .name = "content-type", .value = "text/css", },
                .{ .name = "date", .value = http_date, },
                .{ .name = "last-modified", .value = http_last_modified, },
                .{ .name = "cache-control", .value = CACHE_CONTROL, },
            },
        });
    }

    try request.respond("404 Not found", .{
        .status = .not_found,
        .extra_headers = &.{
            .{ .name = "content-type", .value = "text/plain", },
        },
    });
}
