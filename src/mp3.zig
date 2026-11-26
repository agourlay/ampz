//! MPEG Layer III frame decoder. All state belongs to one stream.
const std = @import("std");
const tables = @import("tables.zig");
const pi: f64 = std.math.pi;
const Spectrum = [576]f32;
pub const Header = struct {
    rate: u32,
    channels: usize,
    size: usize,
    band_index: usize,
    mpeg1: bool,
    crc: bool,
    ms: bool,
    intensity: bool,

    pub fn parse(data: []const u8) ?Header {
        if (data.len < 4 or data[0] != 255 or data[1] & 0xe6 != 0xe2) return null;
        const version = data[1] >> 3 & 3;
        const freq = data[2] >> 2 & 3;
        const index = data[2] >> 4;
        if (version == 1 or freq == 3 or index == 0 or index == 15) return null;
        const mpeg1 = version == 3;
        const rates = [3]u32{ 44100, 48000, 32000 };
        const high = [15]u32{ 0, 32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320 };
        const low = [15]u32{ 0, 8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160 };
        const group: usize = if (mpeg1) 0 else if (version == 2) 1 else 2;
        const rate = rates[freq] >> @intCast(group);
        const mode = data[3] >> 6;
        return .{ .rate = rate, .size = (if (mpeg1) high[index] * 144000 else low[index] * 72000) / rate + (data[2] >> 1 & 1), .band_index = group * 3 + freq, .channels = if (mode == 3) 1 else 2, .mpeg1 = mpeg1, .crc = data[1] & 1 == 0, .ms = mode == 1 and data[3] & 32 != 0, .intensity = mode == 1 and data[3] & 16 != 0 };
    }
    pub fn samples(h: Header) usize {
        return if (h.mpeg1) 1152 else 576;
    }
    pub fn dataStart(h: Header) usize {
        const side: usize = if (h.mpeg1) (if (h.channels == 1) @as(usize, 17) else 32) else (if (h.channels == 1) @as(usize, 9) else 17);
        return 4 + @as(usize, if (h.crc) 2 else 0) + side;
    }
};

const Bits = struct {
    bytes: []const u8,
    pos: usize = 0,
    end: usize,
    fn read(b: *Bits, count: usize) !usize {
        if (b.pos + count > b.end) return error.InvalidFrame;
        var value: usize = 0;
        for (0..count) |_| {
            value = (value << 1) | ((b.bytes[b.pos / 8] >> @intCast(7 - b.pos % 8)) & 1);
            b.pos += 1;
        }
        return value;
    }
    fn flag(b: *Bits) !bool {
        return try b.read(1) != 0;
    }
};

const Info = struct {
    length: usize,
    pairs: usize,
    gain: usize,
    compression: usize,
    block: usize = 0,
    mixed: bool = false,
    book: [3]usize = .{ 0, 0, 0 },
    subgain: [3]usize = .{ 0, 0, 0 },
    region: [2]usize,
    pre: bool,
    scale: bool,
    quad: usize,

    fn parse(b: *Bits, h: Header) !Info {
        var g: Info = .{ .length = try b.read(12), .pairs = try b.read(9), .gain = try b.read(8), .compression = try b.read(if (h.mpeg1) 4 else 9), .region = undefined, .pre = false, .scale = false, .quad = 0 };
        if (g.pairs > 288) return error.InvalidFrame;
        if (try b.flag()) {
            g.block = try b.read(2);
            if (g.block == 0) return error.InvalidFrame;
            g.mixed = try b.flag();
            for (g.book[0..2]) |*v| v.* = try b.read(5);
            for (&g.subgain) |*v| v.* = try b.read(3);
            const bands = &tables.bands[h.band_index];
            const boundary: usize = if (h.mpeg1 or g.block == 2) @as(usize, bands.short[3]) * 3 else bands.long[8];
            g.region = .{ boundary, 576 };
        } else {
            for (&g.book) |*v| v.* = try b.read(5);
            const a = try b.read(4) + 1;
            const z = a + try b.read(3) + 1;
            const bands = &tables.bands[h.band_index].long;
            g.region = .{ bands[a], bands[@min(z, 22)] };
        }
        if (h.mpeg1) g.pre = try b.flag();
        g.scale = try b.flag();
        g.quad = 32 + try b.read(1);
        return g;
    }
};

const Scales = struct {
    value: [40]usize = @splat(0),
    invalid_is: [40]bool = @splat(false),
    fn read(s: *Scales, b: *Bits, g: *Info, h: Header, reuse: usize, is_channel: bool) !void {
        if (h.mpeg1) {
            const first = [_]usize{ 0, 0, 0, 0, 3, 1, 1, 1, 2, 2, 2, 3, 3, 3, 4, 4 };
            const second = [_]usize{ 0, 1, 2, 3, 0, 1, 2, 3, 1, 2, 3, 1, 2, 3, 2, 3 };
            const groups: [4]usize = if (g.block == 2) (if (g.mixed) [4]usize{ 17, 0, 18, 0 } else [4]usize{ 18, 0, 18, 0 }) else .{ 6, 5, 5, 5 };
            var i: usize = 0;
            for (groups, 0..) |len, k| {
                if (g.block == 2 or reuse & (@as(usize, 8) >> @intCast(k)) == 0) {
                    for (s.value[i..][0..len]) |*v| v.* = try b.read(if (k < 2) first[g.compression] else second[g.compression]);
                }
                i += len;
            }
            @memset(s.value[i..], 0);
            return;
        }
        const partitions = [6][3][4]usize{
            .{ .{ 6, 5, 5, 5 }, .{ 9, 9, 9, 9 }, .{ 6, 9, 9, 9 } },       .{ .{ 6, 5, 7, 3 }, .{ 9, 9, 12, 6 }, .{ 6, 9, 12, 6 } },
            .{ .{ 11, 10, 0, 0 }, .{ 18, 18, 0, 0 }, .{ 15, 18, 0, 0 } }, .{ .{ 7, 7, 7, 0 }, .{ 12, 12, 12, 0 }, .{ 6, 15, 12, 0 } },
            .{ .{ 6, 6, 6, 3 }, .{ 12, 9, 9, 6 }, .{ 6, 12, 9, 6 } },     .{ .{ 8, 8, 5, 0 }, .{ 15, 12, 9, 0 }, .{ 6, 18, 9, 0 } },
        };
        var n = g.compression;
        var p: usize = 0;
        if (is_channel) {
            n /= 2;
            p = if (n < 180) 3 else if (n < 244) 4 else 5;
        } else p = if (n < 400) 0 else if (n < 500) 1 else 2;
        n -= ([_]usize{ 0, 400, 500, 0, 180, 244 })[p];
        const radix = ([6][4]usize{ .{ 5, 5, 4, 4 }, .{ 5, 5, 4, 1 }, .{ 4, 3, 1, 1 }, .{ 5, 6, 6, 1 }, .{ 4, 4, 4, 1 }, .{ 4, 3, 1, 1 } })[p];
        var sizes: [4]usize = undefined;
        for (0..4) |rev| {
            const k = 3 - rev;
            sizes[k] = n % radix[k];
            n /= radix[k];
        }
        g.pre = p == 2;
        const kind: usize = if (g.block != 2) 0 else if (g.mixed) 2 else 1;
        var i: usize = 0;
        for (partitions[p][kind], sizes) |count, width| {
            for (0..count) |_| {
                s.value[i] = try b.read(width);
                // A zero-width partition implies position 0 (equal channels).
                // Only an explicitly transmitted all-ones value is reserved.
                s.invalid_is[i] = width != 0 and s.value[i] == (@as(usize, 1) << @intCast(width)) - 1;
                i += 1;
            }
        }
    }
};

fn symbol(b: *Bits, book: usize) !usize {
    if (book == 0) return 0;
    const tree = tables.books[book];
    if (tree.len == 0) return error.InvalidFrame;
    var node: i16 = 0;
    while (node >= 0) node = tree[@intCast(node)][try b.read(1)];
    return @intCast(-node - 1);
}
fn signed(b: *Bits, magnitude: usize, extra: usize) !i16 {
    if (magnitude == 0) return 0;
    const v: i16 = @intCast(magnitude + if (magnitude == 15) try b.read(extra) else 0);
    return if (try b.flag()) -v else v;
}
const Band = struct { start: usize, width: usize, stride: usize, window: usize, pre: usize };
const BandList = struct {
    items: [40]Band = undefined,
    len: usize = 0,
    fn init(h: Header, g: Info) BandList {
        const pretab = [_]usize{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 3, 3, 3, 2, 0 };
        const bands = &tables.bands[h.band_index];
        var list: BandList = .{};
        const longs: usize = if (g.block != 2) 22 else if (!g.mixed) 0 else if (h.mpeg1) 8 else 6;
        for (0..longs) |i| {
            list.items[list.len] = .{ .start = bands.long[i], .width = bands.long[i + 1] - bands.long[i], .stride = 1, .window = 0, .pre = if (g.pre) pretab[i] else 0 };
            list.len += 1;
        }
        if (g.block == 2) {
            const start: usize = if (g.mixed) 3 else 0;
            for (start..13) |i| for (0..3) |w| {
                list.items[list.len] = .{ .start = @as(usize, bands.short[i]) * 3 + w, .width = bands.short[i + 1] - bands.short[i], .stride = 3, .window = w, .pre = 0 };
                list.len += 1;
            };
        }
        return list;
    }
};
fn spectrum(b: *Bits, g: Info, scales: Scales, bands: *const BandList, out: *Spectrum) !void {
    const linbits = [_]usize{ 1, 2, 3, 4, 6, 8, 10, 13, 4, 5, 6, 7, 8, 9, 11, 13 };
    var values: [576]i16 = @splat(0);
    var pos: usize = 0;
    while (pos < g.pairs * 2) : (pos += 2) {
        const table = g.book[if (pos < g.region[0]) @as(usize, 0) else if (pos < g.region[1]) @as(usize, 1) else 2];
        const pair = try symbol(b, table);
        const extra = if (table >= 16) linbits[table - 16] else 0;
        values[pos] = try signed(b, pair >> 4, extra);
        values[pos + 1] = try signed(b, pair & 15, extra);
    }
    while (pos + 4 <= 576 and b.pos < b.end) : (pos += 4) {
        const quad = symbol(b, g.quad) catch break;
        var v: [4]i16 = undefined;
        for (&v, 0..) |*x, k| x.* = signed(b, (quad >> @intCast(3 - k)) & 1, 0) catch break else {
            values[pos..][0..4].* = v;
            continue;
        }
        break;
    }
    var source: usize = 0;
    for (bands.items[0..bands.len], 0..) |band, i| {
        const attenuation = (scales.value[i] + band.pre) * (if (g.scale) @as(usize, 4) else 2) + if (band.stride == 3) 8 * g.subgain[band.window] else 0;
        const power = (@as(f32, @floatFromInt(g.gain)) - 210 - @as(f32, @floatFromInt(attenuation))) * 0.25;
        const factor = @exp2(power);
        for (0..band.width) |k| {
            const value = values[source];
            source += 1;
            const mag: f32 = @floatFromInt(@abs(value));
            const sample = mag * std.math.cbrt(mag) * factor;
            out[band.start + k * band.stride] = if (value < 0) -sample else sample;
        }
    }
}
fn stereo(h: Header, g: Info, s: Scales, bands: *const BandList, spectra: *[2]Spectrum) void {
    var last = [3]isize{ -1, -1, -1 };
    if (h.intensity) for (bands.items[0..bands.len], 0..) |band, i| {
        for (0..band.width) |k| if (spectra[1][band.start + k * band.stride] != 0) {
            if (band.stride == 1) last = @splat(@intCast(i)) else last[band.window] = @intCast(i);
            break;
        };
    };
    // The long-block portion of a mixed granule precedes all three short windows.
    const last_long = @max(last[0], last[1], last[2]);
    for (bands.items[0..bands.len], 0..) |band, i| {
        const idx = if (i + band.stride >= bands.len and i >= band.stride) i - band.stride else i;
        const v = s.value[idx];
        const cutoff = if (band.stride == 1) last_long else last[band.window];
        const intensity = h.intensity and @as(isize, @intCast(i)) > cutoff and
            (if (h.mpeg1) v < 7 else !s.invalid_is[idx]);
        var left: f32 = 1;
        var right: f32 = 1;
        if (intensity) {
            if (h.mpeg1) {
                if (v == 6) right = 0 else {
                    const ratio = @tan(@as(f32, @floatFromInt(v)) * @as(f32, @floatCast(pi / 12.0)));
                    right = 1 / (1 + ratio);
                    left = 1 - right;
                }
            } else {
                const attenuation: f32 = if (g.compression & 1 != 0) 0.5 else 0.25;
                const ratio = @exp2(-attenuation * @as(f32, @floatFromInt((v + 1) / 2)));
                if (v % 2 == 1) left = ratio else right = ratio;
            }
        }
        for (0..band.width) |k| {
            const n = band.start + k * band.stride;
            const a = spectra[0][n];
            const b = spectra[1][n];
            if (intensity) {
                spectra[0][n] = a * left;
                spectra[1][n] = a * right;
            } else if (h.ms) {
                spectra[0][n] = (a + b) * std.math.sqrt1_2;
                spectra[1][n] = (a - b) * std.math.sqrt1_2;
            }
        }
    }
}

fn f(n: usize) f64 {
    return @floatFromInt(n);
}
fn imdctMatrix(comptime n: usize) [2 * n][n]f32 {
    @setEvalBranchQuota(2000000);
    var m: [2 * n][n]f32 = undefined;
    for (0..2 * n) |i| for (0..n) |k| {
        m[i][k] = @floatCast(@cos(pi / (4 * f(n)) * f(2 * i + 1 + n) * f(2 * k + 1)));
    };
    return m;
}
const imdct_long = imdctMatrix(18);
const imdct_short = imdctMatrix(6);
const windows = blk: {
    var w: [4][36]f32 = undefined;
    for (0..36) |i| {
        const long: f32 = @floatCast(@sin(pi / 36 * (f(i) + 0.5)));
        w[0][i] = long;
        w[1][i] = if (i < 18) long else if (i < 24) 1 else if (i < 30) @floatCast(@sin(pi / 12 * (f(i - 18) + 0.5))) else 0;
        w[2][i] = if (i < 12) @floatCast(@sin(pi / 12 * (f(i) + 0.5))) else 0;
        w[3][i] = if (i < 6) 0 else if (i < 12) @floatCast(@sin(pi / 12 * (f(i - 6) + 0.5))) else if (i < 18) 1 else long;
    }
    break :blk w;
};
const SynthesisLanes = @Vector(4, f32);
const filter = blk: {
    @setEvalBranchQuota(3000000);
    var m: [16][32]SynthesisLanes = undefined;
    for (0..64) |i| for (0..32) |k| {
        m[i / 4][k][i % 4] = @floatCast(@cos(pi / 64 * f(i + 16) * f(2 * k + 1)));
    };
    break :blk m;
};
const window = blk: {
    var w: [512]f32 = undefined;
    for (0..512) |i| {
        const value = tables.half_window[if (i <= 256) i else 512 - i];
        w[i] = @as(f32, @floatFromInt(if (i > 256 and i % 64 != 0) -value else value)) / 65536;
    }
    break :blk w;
};
const Hybrid = struct {
    overlap: [32][18]f32 = @splat(@splat(0)),
    history: [1024]f32 = @splat(0),
    head: usize = 0,

    fn run(self: *Hybrid, xr: *Spectrum, g: Info, h: Header, pcm: []i16, stride: usize) void {
        const long_bands: usize = if (g.block != 2) 32 else if (g.mixed) @as(usize, tables.bands[h.band_index].short[3]) * 3 / 18 else 0;
        const ci = [_]f32{ -0.6, -0.535, -0.33, -0.185, -0.095, -0.041, -0.0142, -0.0037 };
        for (1..@max(1, long_bands)) |sb| {
            for (ci, 0..) |c, k| {
                const cs = 1 / @sqrt(1 + c * c);
                const a = sb * 18 - 1 - k;
                const b = sb * 18 + k;
                const u = xr[a];
                const d = xr[b];
                xr[a] = cs * (u - c * d);
                xr[b] = cs * (d + c * u);
            }
        }
        var slots: [18][32]f32 = undefined;
        for (0..32) |sb| {
            const kind = if (g.block == 2 and sb < long_bands) 0 else g.block;
            const input = xr[sb * 18 ..][0..18];
            var temp: [36]f32 = @splat(0);
            if (kind == 2) {
                for (0..3) |w| for (imdct_short, 0..) |row, i| {
                    var sum: f32 = 0;
                    for (row, 0..) |coef, k| sum += coef * input[3 * k + w];
                    temp[6 + 6 * w + i] += sum * windows[2][i];
                };
            } else {
                for (imdct_long, 0..) |row, i| {
                    var sum: f32 = 0;
                    for (row, input) |coef, x| sum += coef * x;
                    temp[i] = sum * windows[kind][i];
                }
            }
            for (0..18) |t| {
                const v = self.overlap[sb][t] + temp[t];
                slots[t][sb] = if ((sb & t & 1) != 0) -v else v;
                self.overlap[sb][t] = temp[t + 18];
            }
        }
        for (&slots, 0..) |*slot, t| {
            self.head = (self.head + 1024 - 64) % 1024;
            // Each lane owns an output, preserving the scalar order of each sum.
            for (&filter, 0..) |*rows, group| {
                var sums: SynthesisLanes = @splat(0);
                for (rows, slot) |coefficients, sample| sums += coefficients * @as(SynthesisLanes, @splat(sample));
                self.history[self.head + 4 * group ..][0..4].* = sums;
            }
            for (0..32 / 4) |group| {
                const first = 4 * group;
                var sums: SynthesisLanes = @splat(0);
                for (0..8) |tap| {
                    const weight = 64 * tap + first;
                    const offset = self.head + 128 * tap + first;
                    const even_weights: SynthesisLanes = window[weight..][0..4].*;
                    const odd_weights: SynthesisLanes = window[weight + 32 ..][0..4].*;
                    // Both ring offsets are multiples of four, so each load stays contiguous.
                    const even_samples: SynthesisLanes = self.history[offset % self.history.len ..][0..4].*;
                    const odd_samples: SynthesisLanes = self.history[(offset + 96) % self.history.len ..][0..4].*;
                    sums += even_weights * even_samples + odd_weights * odd_samples;
                }
                inline for (0..4) |lane| {
                    pcm[(t * 32 + first + lane) * stride] = @intFromFloat(std.math.clamp(@round(sums[lane] * 32768), -32768, 32767));
                }
            }
        }
    }
};

pub const Decoder = struct {
    reservoir: [511]u8 = undefined,
    available: usize = 0,
    hybrid: [2]Hybrid = @splat(.{}),

    pub fn decode(d: *Decoder, h: Header, frame: []const u8, pcm: *[2304]i16) ![]const i16 {
        const start = h.dataStart();
        if (frame.len != h.size or start > frame.len) return error.InvalidFrame;
        const side_start: usize = if (h.crc) 6 else 4;
        var b: Bits = .{ .bytes = frame[side_start..start], .end = (start - side_start) * 8 };
        const back = try b.read(if (h.mpeg1) 9 else 8);
        _ = try b.read(if (h.mpeg1) (if (h.channels == 1) @as(usize, 5) else 3) else h.channels);
        var reuse = [2]usize{ 0, 0 };
        if (h.mpeg1) for (reuse[0..h.channels]) |*v| {
            v.* = try b.read(4);
        };
        const granules: usize = if (h.mpeg1) 2 else 1;
        var info: [2][2]Info = undefined;
        for (info[0..granules]) |*group| for (group[0..h.channels]) |*g| {
            g.* = try Info.parse(&b, h);
        };
        var storage: [2560]u8 = undefined;
        const main = frame[start..];
        if (main.len + d.available > storage.len) return error.InvalidFrame;
        @memcpy(storage[0..d.available], d.reservoir[0..d.available]);
        @memcpy(storage[d.available..][0..main.len], main);
        const total = d.available + main.len;
        const old = d.available;
        d.available = @min(511, total);
        @memcpy(d.reservoir[0..d.available], storage[total - d.available .. total]);
        const output = pcm[0 .. h.samples() * h.channels];
        if (back > old) {
            // A cut may start mid-reservoir. Keep this frame's bytes for the
            // next frame and preserve its duration while history builds up.
            @memset(output, 0);
            return output;
        }
        var bits: Bits = .{ .bytes = storage[old - back .. total], .end = (main.len + back) * 8 };
        var scales: [2]Scales = @splat(.{});
        for (0..granules) |gr| {
            var spectra: [2]Spectrum = undefined;
            var layouts: [2]BandList = undefined;
            for (0..h.channels) |ch| {
                const g = &info[gr][ch];
                bits.end = bits.pos + g.length;
                if (bits.end > bits.bytes.len * 8) return error.InvalidFrame;
                try scales[ch].read(&bits, g, h, if (gr == 0) 0 else reuse[ch], ch == 1 and h.intensity);
                layouts[ch] = BandList.init(h, g.*);
                try spectrum(&bits, g.*, scales[ch], &layouts[ch], &spectra[ch]);
                bits.pos = bits.end;
            }
            if (h.channels == 2 and (h.ms or h.intensity)) stereo(h, info[gr][1], scales[1], &layouts[1], &spectra);
            for (0..h.channels) |ch| d.hybrid[ch].run(&spectra[ch], info[gr][ch], h, pcm[gr * 576 * h.channels + ch ..], h.channels);
        }
        return output;
    }
};

test "clips retain reservoir bytes and recover the original PCM" {
    const bytes = @embedFile("fixtures/mono.mp3");
    var pos = tagSize(bytes);
    var full: Decoder = .{};
    var clip: Decoder = .{};
    var full_buf: [2304]i16 = undefined;
    var clip_buf: [2304]i16 = @splat(1234);
    var index: usize = 0;
    while (next(bytes, &pos)) |frame| {
        const expected = try full.decode(frame.h, frame.bytes, &full_buf);
        if (index >= 2) {
            const actual = try clip.decode(frame.h, frame.bytes, &clip_buf);
            if (index == 2) try std.testing.expect(std.mem.allEqual(i16, actual, 0));
            if (index >= 6) {
                try std.testing.expect(!std.mem.allEqual(i16, expected, 0));
                try std.testing.expectEqualSlices(i16, expected, actual);
            }
        }
        index += 1;
    }
    try std.testing.expect(index > 6);
}

pub fn tagSize(data: []const u8) usize {
    if (data.len < 10 or !std.mem.eql(u8, data[0..3], "ID3")) return 0;
    var size: usize = 0;
    for (data[6..10]) |v| {
        if (v >= 128) return 0;
        size = size * 128 + v;
    }
    return 10 + size + @as(usize, if (data[3] == 4 and data[5] & 16 != 0) 10 else 0);
}

pub const TagSource = union(enum) {
    bytes: []const u8,
    file: struct { handle: std.Io.File, io: std.Io },

    fn readAt(source: TagSource, offset: u64, out: []u8) bool {
        switch (source) {
            .bytes => |bytes| {
                if (offset > bytes.len or out.len > bytes.len - offset) return false;
                @memcpy(out, bytes[@intCast(offset)..][0..out.len]);
                return true;
            },
            .file => |file| return (file.handle.readPositionalAll(file.io, out, offset) catch 0) == out.len,
        }
    }
};

pub const TrailingTag = struct {
    kind: enum { id3v1, id3v2, ape },
    start: u64,

    // Both library scanning and playback use the same footer validation. Looking
    // up a tag reads only its boundaries, even when it contains large artwork.
    pub fn endingAt(source: TagSource, end: u64) ?TrailingTag {
        if (end < 20) return null;
        var buf: [128]u8 = undefined;
        const tail = buf[0..@as(usize, @intCast(@min(buf.len, end)))];
        if (!source.readAt(end - tail.len, tail)) return null;

        const id3 = tail[tail.len - 10 ..][0..10];
        if (std.mem.eql(u8, id3[0..4], "3DI\x04") and id3[5] & 0x10 != 0) {
            var expected = id3.*;
            @memcpy(expected[0..3], "ID3");
            const size = tagSize(&expected);
            var header: [10]u8 = undefined;
            if (size >= 20 and size <= end and source.readAt(end - size, &header) and std.mem.eql(u8, &header, &expected))
                return .{ .kind = .id3v2, .start = end - size };
        }
        if (tail.len >= 32) {
            const footer = tail[tail.len - 32 ..][0..32];
            if (std.mem.eql(u8, footer[0..8], "APETAGEX")) {
                const version = std.mem.readInt(u32, footer[8..12], .little);
                const size = std.mem.readInt(u32, footer[12..16], .little);
                const flags = std.mem.readInt(u32, footer[20..24], .little);
                if ((version == 1000 or version == 2000) and size >= 32 and size <= end and flags & (1 << 29) == 0) {
                    var start = end - size;
                    var header: [32]u8 = undefined;
                    if (flags & (1 << 31) != 0 and start >= 32 and source.readAt(start - 32, &header) and
                        std.mem.eql(u8, header[0..20], footer[0..20]) and
                        std.mem.readInt(u32, header[20..24], .little) == (flags | (1 << 29))) start -= 32;
                    return .{ .kind = .ape, .start = start };
                }
            }
        }
        // Check the three-byte ID3v1 signature only after ruling out a footer.
        if (tail.len == 128 and std.mem.eql(u8, tail[0..3], "TAG")) return .{ .kind = .id3v1, .start = end - 128 };
        return null;
    }
};

pub fn withoutTrailingTags(data: []const u8) []const u8 {
    var end: u64 = data.len;
    while (TrailingTag.endingAt(.{ .bytes = data }, end)) |tag| end = tag.start;
    return data[0..@intCast(end)];
}

pub const Frame = struct { h: Header, bytes: []const u8 };
pub fn next(data: []const u8, offset: *usize) ?Frame {
    while (offset.* < data.len) : (offset.* += 1) {
        const rest = data[offset.*..];
        const h = Header.parse(rest) orelse continue;
        if (h.size > rest.len or h.size < h.dataStart()) continue;
        offset.* += h.size;
        return .{ .h = h, .bytes = rest[0..h.size] };
    }
    return null;
}

test "reject reserved headers and truncated frames" {
    try std.testing.expect(Header.parse(&.{ 0xff, 0xeb, 0x90, 0 }) == null);
    try std.testing.expect(Header.parse(&.{ 0xff, 0xfb, 0xfc, 0 }) == null);
    var pos: usize = 0;
    try std.testing.expect(next(&.{ 0xff, 0xfb, 0x90, 0 }, &pos) == null);
}

test "zero-width MPEG-2 intensity positions reconstruct both channels" {
    const audio = @embedFile("fixtures/intensity.mp3");
    var decoder: Decoder = .{};
    var offset: usize = 0;
    var samples: usize = 0;
    while (next(audio, &offset)) |frame| {
        var buffer: [2304]i16 = undefined;
        const pcm = try decoder.decode(frame.h, frame.bytes, &buffer);
        for (0..pcm.len / 2) |i| {
            try std.testing.expectEqual(pcm[2 * i], pcm[2 * i + 1]);
            // FFmpeg's independently decoded sample, before discarding encoder delay.
            if (samples + i == 2000) try std.testing.expect(@abs(@as(i32, pcm[2 * i]) + 6014) <= 1);
        }
        samples += pcm.len / 2;
    }
    try std.testing.expectEqual(@as(usize, 12672), samples);
}

test "MPEG-1 intensity stereo pans right, center and left and falls back to mid-side" {
    const header = Header.parse("\xff\xfb\x90\x70").?;
    const info = std.mem.zeroes(Info);
    const bands = BandList.init(header, info);
    var scales: Scales = .{};
    scales.value[0..4].* = .{ 0, 3, 6, 7 };
    var channels: [2]Spectrum = .{ @splat(2), @splat(0) };
    stereo(header, info, scales, &bands, &channels);
    const expected = [_][2]f32{ .{ 0, 2 }, .{ 1, 1 }, .{ 2, 0 }, .{ @sqrt(2.0), @sqrt(2.0) } };
    for (bands.items[0..4], expected) |band, pair| {
        for (pair, 0..) |value, ch| {
            for (channels[ch][band.start..][0..band.width]) |sample| try std.testing.expectApproxEqAbs(value, sample, 0.00001);
        }
    }
}

test "mixed-block intensity stereo leaves lower bands independent for all three windows" {
    // Each frame has left-channel energy only in the long bands and right-channel
    // energy in one short window. Those occupied bands carry ordinary stereo.
    const data = @embedFile("fixtures/mixed-intensity.mp3");
    var intensity_decoder: Decoder = .{};
    var independent_decoder: Decoder = .{};
    var offset: usize = 0;
    var count: usize = 0;
    while (next(data, &offset)) |frame| {
        var reference_header = frame.h;
        reference_header.intensity = false;
        var actual: [2304]i16 = undefined;
        var expected: [2304]i16 = undefined;
        try std.testing.expectEqualSlices(i16, try independent_decoder.decode(reference_header, frame.bytes, &expected), try intensity_decoder.decode(frame.h, frame.bytes, &actual));
        count += 1;
    }
    try std.testing.expectEqual(@as(usize, 3), count);
}
