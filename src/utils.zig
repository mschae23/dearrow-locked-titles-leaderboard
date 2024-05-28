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

pub const FormatHttpDateError = std.mem.Allocator.Error || error { InvalidTime };

pub fn formatHttpDateAlloc(allocator: std.mem.Allocator, timestamp: i64) FormatHttpDateError![]u8 {
    const days_since_epoch: i32 = @intCast(@divFloor(timestamp, std.time.s_per_day));
    const ymd = chrono.date.YearMonthDay.fromDaysSinceUnixEpoch(days_since_epoch);
    const weekday = chrono.date.Weekday.fromDaysSinceUnixEpoch(days_since_epoch);
    const time = try chrono.Time.fromNumSecondsFromMidnight(@intCast(@mod(timestamp, std.time.s_per_day)), 0);

    return try std.fmt.allocPrint(allocator, "{s}, {d} {s} {d} {d:0>2}:{d:0>2}:{d:0>2} {s}", .{
        weekday.shortName(),
        ymd.day,
        ymd.month.shortName(),
        ymd.year,
        time.hour(),
        time.minute(),
        time.second(),
        "GMT",
    });
}

pub fn parseHttpDate(value: []const u8) !i64 {
    if (value.len != 29) {
        return error.BadRequest;
    }

    const timestamp_fmt = "{3}, {2} {3} {4} {2}:{2}:{2} GMT";
    var parts: [7][]const u8 = .{""} ** 7;
    comptime var i: usize = 0;
    var j: usize = 0;
    var part_index: usize = 0;

    inline while (i < timestamp_fmt.len) : (i += 1) {
        const c = timestamp_fmt[i];
        const d = value[j];

        if (c == '{') {
            comptime var end_index: usize = i;

            inline while (end_index < timestamp_fmt.len and timestamp_fmt[end_index] != '}') {
                end_index += 1;
            }

            const number = comptime std.fmt.parseInt(usize, timestamp_fmt[i + 1..end_index], 10) catch |err| @compileError("Timestamp format string contains invalid number: " ++ @errorName(err));
            parts[part_index] = value[j..][0..number];
            part_index += 1;
            i = end_index;
            j += number;
        } else if (c == d) {
            j += 1;
        } else {
            return error.BadRequest;
        }
    }

    // Ignore weekday part
    const day = parts[1];
    const month = parts[2];
    const year = parts[3];
    const hour = parts[4];
    const minute = parts[5];
    const second = parts[6];

    const day_number = try std.fmt.parseInt(chrono.date.Month.DayInt, day, 10);
    const year_number = try std.fmt.parseInt(chrono.date.YearMonthDay.YearInt, year, 10);
    const hour_number = try std.fmt.parseInt(chrono.Time.HoursInt, hour, 10);
    const minute_number = try std.fmt.parseInt(chrono.Time.MinutesInt, minute, 10);
    const second_number = try std.fmt.parseInt(chrono.Time.SecondsInt, second, 10);

    const month_number: chrono.date.Month.Int = month: {
        inline for (@typeInfo(chrono.date.Month).Enum.fields) |f| {
            if (std.mem.eql(u8, month, &@as(chrono.date.Month, @enumFromInt(f.value)).shortName())) {
                break :month f.value;
            }
        }

        return error.BadRequest;
    };

    const ymd = chrono.date.YearMonthDay.fromNumbers(year_number, month_number, day_number);
    const time = try chrono.Time.hms(hour_number, minute_number, second_number);
    const timestamp: i64 = (24 * 60 * 60 * @as(i64, ymd.toDaysSinceUnixEpoch())) + @as(i64, time.secs);
    return timestamp;
}

pub fn getLastModificationTimeForFile(file: std.fs.File) !i64 {
    const timestamp_nanos = (try file.metadata()).modified();
    // Convert from nanoseconds since Unix epoch to seconds since Unix epoch
    return @as(i64, @intCast(@divTrunc(timestamp_nanos, 1_000_000_000)));
}
