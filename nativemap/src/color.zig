const std = @import("std");
const assert = std.debug.assert;
const endian = std.Target.current.cpu.arch.endian();
const pow = std.math.pow;

const BaseColors = [_]RGB{
    // we intentionally don't include the transparent
    // just add 4 to the final matching result
    .{ .r = 127, .g = 178, .b = 56 },
    .{ .r = 247, .g = 233, .b = 163 },
    .{ .r = 199, .g = 199, .b = 199 },
    .{ .r = 255, .g = 0, .b = 0 },
    .{ .r = 160, .g = 160, .b = 255 },
    .{ .r = 167, .g = 167, .b = 167 },
    .{ .r = 0, .g = 124, .b = 0 },
    .{ .r = 255, .g = 255, .b = 255 },
    .{ .r = 164, .g = 168, .b = 184 },
    .{ .r = 151, .g = 109, .b = 77 },
    .{ .r = 112, .g = 112, .b = 112 },
    .{ .r = 64, .g = 64, .b = 255 },
    .{ .r = 143, .g = 119, .b = 72 },
    .{ .r = 255, .g = 252, .b = 245 },
    .{ .r = 216, .g = 127, .b = 51 },
    .{ .r = 178, .g = 76, .b = 216 },
    .{ .r = 102, .g = 153, .b = 216 },
    .{ .r = 229, .g = 229, .b = 51 },
    .{ .r = 127, .g = 204, .b = 25 },
    .{ .r = 242, .g = 127, .b = 165 },
    .{ .r = 76, .g = 76, .b = 76 },
    .{ .r = 153, .g = 153, .b = 153 },
    .{ .r = 76, .g = 127, .b = 153 },
    .{ .r = 127, .g = 63, .b = 178 },
    .{ .r = 51, .g = 76, .b = 178 },
    .{ .r = 102, .g = 76, .b = 51 },
    .{ .r = 102, .g = 127, .b = 51 },
    .{ .r = 153, .g = 51, .b = 51 },
    .{ .r = 25, .g = 25, .b = 25 },
    .{ .r = 250, .g = 238, .b = 77 },
    .{ .r = 92, .g = 219, .b = 213 },
    .{ .r = 74, .g = 128, .b = 255 },
    .{ .r = 0, .g = 217, .b = 58 },
    .{ .r = 129, .g = 86, .b = 49 },
    .{ .r = 112, .g = 2, .b = 0 },
    .{ .r = 209, .g = 177, .b = 161 },
    .{ .r = 159, .g = 82, .b = 36 },
    .{ .r = 149, .g = 87, .b = 108 },
    .{ .r = 112, .g = 108, .b = 138 },
    .{ .r = 186, .g = 133, .b = 36 },
    .{ .r = 103, .g = 117, .b = 53 },
    .{ .r = 160, .g = 77, .b = 78 },
    .{ .r = 57, .g = 41, .b = 35 },
    .{ .r = 135, .g = 107, .b = 98 },
    .{ .r = 87, .g = 92, .b = 92 },
    .{ .r = 122, .g = 73, .b = 88 },
    .{ .r = 76, .g = 62, .b = 92 },
    .{ .r = 76, .g = 50, .b = 35 },
    .{ .r = 76, .g = 82, .b = 42 },
    .{ .r = 142, .g = 60, .b = 46 },
    .{ .r = 37, .g = 22, .b = 16 },
    .{ .r = 189, .g = 48, .b = 49 },
    .{ .r = 148, .g = 63, .b = 97 },
    .{ .r = 92, .g = 25, .b = 29 },
    .{ .r = 22, .g = 126, .b = 134 },
    .{ .r = 58, .g = 142, .b = 140 },
    .{ .r = 86, .g = 44, .b = 62 },
    .{ .r = 20, .g = 180, .b = 133 },
};
const ShadeMultis = [_]u32{ 180, 220, 255, 135 };
const AllColorCount: u8 = BaseColors.len * ShadeMultis.len;

const AllColors = comptime {
    var generated: [AllColorCount]RGB = undefined;
    for (BaseColors) |color, b_idx| {
        for (ShadeMultis) |multiplier, s_idx| {
            const r = @truncate(u8, @divFloor(@as(u32, color.r) * multiplier, 255));
            const g = @truncate(u8, @divFloor(@as(u32, color.g) * multiplier, 255));
            const b = @truncate(u8, @divFloor(@as(u32, color.b) * multiplier, 255));
            generated[b_idx * 4 + s_idx] = .{ .r = r, .g = g, .b = b };
        }
    }
    return generated;
};

const RGB = struct { r: u8, g: u8, b: u8 };
const XYZ = struct { X: f64, Y: f64, Z: f64 };
const Lab = struct { L: f64, a: f64, b: f64 };
const ARGB4444 = comptime switch (endian) {
    .Little => packed struct { b: u4, g: u4, r: u4, _unused: u4 = 0 },
    .Big => packed struct { _unused: u4 = 0, r: u4, g: u4, b: u4 },
};

pub fn slowMatchColor(pixel: u16) u8 {
    const small: ARGB4444 = @bitCast(ARGB4444, pixel);

    // we can't exactly bring RGB444 up to RGB888, since we lose the lower 4 bits in RGB888 to RGB444
    // but we can at least just approximate it by multiplying by 17
    // TODO: upgrade from RGB444 to RGB565 so we don't have useless bits and for a bit more accuracy
    const src: RGB = .{
        .r = @as(u8, small.r) * 17,
        .g = @as(u8, small.g) * 17,
        .b = @as(u8, small.b) * 17,
    };
    var bestIdx: u8 = 0;
    var bestMatch: f64 = std.math.f64_max;

    // the reason why this is the "slow" method and thus
    // just a fallback if our lookup table doesn't have an entry
    var i: u8 = 0;
    while (i < AllColorCount) : (i += 1) {
        const diff = colorDistExpensive(src, AllColors[i]);
        if (diff < bestMatch) {
            bestIdx = i;
            bestMatch = diff;
        }
    }

    // double check to make sure we actually found soemthing
    assert(bestMatch < std.math.f64_max);

    // we add 4 because we lose the 4 transparency colors
    return bestIdx + 4;
}

pub fn toU16RGB(index: u8) u16 {
    const rgb = AllColors[index - 4];
    const hack: ARGB4444 = .{
        .r = @truncate(u4, rgb.r >> 4),
        .g = @truncate(u4, rgb.g >> 4),
        .b = @truncate(u4, rgb.b >> 4),
        ._unused = 0,
    };
    return @bitCast(u16, hack);
}

// since we offload the work of calculating distance from the server, we can actually perform much more
// computationally expensive color comparisons
// so instead of our weighted distance formula, why not just go for the whole nine yards and do CIE Lab!
// ironically, we may actually lose color accuracy due to converting from RGB to XYZ and then XYZ to Lab
fn colorDistExpensive(c1: RGB, c2: RGB) f64 {
    return deltaE2000(rgbToCIELab(c1), rgbToCIELab(c2));
}

fn rgbToCIELab(val: RGB) Lab {
    return xyzToCIELab(rgbToXyz(val));
}

// rgbToXyz and xyzToLab formulas taken from http://www.easyrgb.com/en/math.php
fn rgbToXyz(val: RGB) XYZ {
    const sR = @intToFloat(f64, val.r);
    const sG = @intToFloat(f64, val.g);
    const sB = @intToFloat(f64, val.b);

    const R = rgbBound(sR / 255.0) * 100.0;
    const G = rgbBound(sG / 255.0) * 100.0;
    const B = rgbBound(sB / 255.0) * 100.0;

    return .{
        .X = R * 0.4124 + G * 0.3576 + B * 0.1805,
        .Y = R * 0.2126 + G * 0.7152 + B * 0.0722,
        .Z = R * 0.0193 + G * 0.1192 + B * 0.9505,
    };
}

fn xyzToCIELab(xyz: XYZ) Lab {
    const X = xyzBound(xyz.X / 100.0);
    const Y = xyzBound(xyz.Y / 100.0);
    const Z = xyzBound(xyz.Z / 100.0);

    return .{
        .L = (116.0 * Y) - 16.0,
        .a = 500.0 * (X - Y),
        .b = 200.0 * (Y - Z),
    };
}

fn rgbBound(value: f64) f64 {
    var ret = value;
    if (ret > 0.04045) {
        ret = std.math.pow(f64, (ret + 0.055) / 1.055, 2.4);
    } else {
        ret = ret / 12.92;
    }
    return ret;
}

const oneThirds: f64 = 1.0 / 3.0;
const sixteenOverHundredSixteen: f64 = 16.0 / 116.0;
fn xyzBound(value: f64) f64 {
    var ret = value;
    if (ret > 0.008856) {
        ret = std.math.pow(f64, ret, oneThirds);
    } else {
        ret = (7.787 * ret) + sixteenOverHundredSixteen;
    }
    return ret;
}

const PI = 3.14159265358979323846;
// translated from https://github.com/gfiumara/CIEDE2000/blob/master/CIEDE2000.cpp
fn deltaE2000(lab1: Lab, lab2: Lab) f64 {
    const L = 0;
    const A = 1;
    const B = 2;

    const C1 = @sqrt((lab1.a * lab1.a) + (lab1.b * lab1.b));
    const C2 = @sqrt((lab2.a * lab2.a) + (lab2.b * lab2.b));

    const barC = (C1 + C2) / 2.0;

    const G = 0.5 * (1.0 - @sqrt(pow(f64, barC, 7) / (pow(f64, barC, 7) + 6103515625.0)));

    const a1Prime = (1.0 + G) * lab1.a;
    const a2Prime = (1.0 + G) * lab2.a;

    const CPrime1 = @sqrt((a1Prime * a1Prime) + (lab1.b * lab1.b));
    const CPrime2 = @sqrt((a2Prime * a2Prime) + (lab2.b * lab2.b));

    var hPrime1: f64 = undefined;
    if (lab1.b == 0 and a1Prime == 0) {
        hPrime1 = 0.0;
    } else {
        hPrime1 = std.math.atan2(f64, lab1.b, a1Prime);
        if (hPrime1 < 0) {
            hPrime1 += (PI * 2.0);
        }
    }

    var hPrime2: f64 = undefined;
    if (lab2.b == 0 and a2Prime == 0) {
        hPrime2 = 0.0;
    } else {
        hPrime2 = std.math.atan2(f64, lab2.b, a2Prime);
        if (hPrime2 < 0) {
            hPrime2 += (PI * 2.0);
        }
    }

    const deltaLPrime = lab2.L - lab1.L;
    const deltaCPrime = CPrime2 - CPrime1;

    var deltahPrime: f64 = undefined;
    const CPrimeProduct = CPrime1 * CPrime2;
    if (CPrimeProduct == 0.0) {
        deltahPrime = 0.0;
    } else {
        deltahPrime = hPrime2 - hPrime1;
        if (deltahPrime < -PI) {
            deltahPrime += (PI * 2.0);
        } else if (deltahPrime > PI) {
            deltahPrime -= (PI * 2.0);
        }
    }

    const deltaHPrime = 2.0 * @sqrt(CPrimeProduct) * @sin(deltahPrime / 2.0);

    const barLPrime = (lab1.L + lab2.L) / 2.0;
    const barCPrime = (CPrime1 + CPrime2) / 2.0;
    const hPrimeSum = hPrime1 + hPrime2;
    var barhPrime: f64 = undefined;

    if (CPrime1 * CPrime2 == 0) {
        barhPrime = hPrimeSum;
    } else {
        if (@fabs(hPrime1 - hPrime2) <= PI) {
            barhPrime = hPrimeSum / 2.0;
        } else {
            if (hPrimeSum < (PI * 2.0)) {
                barhPrime = (hPrimeSum + (PI * 2.0)) / 2.0;
            } else {
                barhPrime = (hPrimeSum - (PI * 2.0)) / 2.0;
            }
        }
    }

    // zig fmt: off
    const T = 1.0 - (0.17 * @cos(barhPrime - 0.523599)) +
             (0.24 * @cos(2.0 * barhPrime)) +
             (0.32 * @cos((3.0 * barhPrime) + 0.10472)) -
             (0.20 * @cos((4.0 * barhPrime) - 1.09956));
    // zig fmt: on

    const deltaTheta = 0.523599 * @exp(-pow(f64, (barhPrime - 4.79966) / 0.436332, 2.0));

    const R_C = 2.0 * @sqrt(pow(f64, barCPrime, 7.0) / (pow(f64, barCPrime, 7.0) + 6103515625.0));
    const S_L = 1.0 + ((0.015 * pow(f64, barLPrime - 50.0, 2.0)) / @sqrt(20.0 + pow(f64, barLPrime - 50.0, 2.0)));
    const S_C = 1.0 + (0.045 * barCPrime);
    const S_H = 1.0 + (0.015 * barCPrime * T);
    const R_T = (-@sin(2.0 * deltaTheta)) * R_C;

    const k_L = 1.0;
    const k_C = 1.0;
    const k_H = 1.0;

    // zig fmt: off
    return @sqrt(
        pow(f64, deltaLPrime / (k_L * S_L), 2.0) +
        pow(f64, deltaCPrime / (k_C * S_C), 2.0) +
        pow(f64, deltaHPrime / (k_H * S_H), 2.0) +
        (R_T * (deltaCPrime / (k_C * S_C)) * (deltaHPrime / (k_H * S_H))));
    // zig fmt: on
}

// deprecated
// adapted from the original Bukkit MapPalette.getDistance()
// it works pretty well here!
fn _deprecated_colorDist(c1: RGB, c2: RGB) f32 {
    const rmean = (@intToFloat(f32, c1.r) + @intToFloat(f32, c2.r)) / 2.0;
    const dr = @intToFloat(f32, c1.r) - @intToFloat(f32, c2.r);
    const dg = @intToFloat(f32, c1.g) - @intToFloat(f32, c2.g);
    const db = @intToFloat(f32, c1.b) - @intToFloat(f32, c2.b);
    const wr = 2.0 + rmean / 256.0;
    const wg = 4.0;
    const wb = 2.0 + (255.0 - rmean) / 256.0;
    return @sqrt(wr * dr * dr + wg * dg * dg + wb * db * db);
}
