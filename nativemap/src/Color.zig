/// Provides color matching and conversion
/// CIE DE2000 implemented directly from Wikipedia's page on it
/// Colorspace conversion implemented from mostly https://kaizoudou.com/from-rgb-to-lab-color-space/

const std = @import("std");
const assert = std.debug.assert;
const atan2 = std.math.atan2;
const pow = std.math.pow;

const D2R = std.math.degreesToRadians;

const pi = std.math.pi;
const two_pi = pi * 2;

const Float = f64;

pub fn matchColor(src: RGB24, palette: []const RGB24) u8 {
    var bestIndex: ?u8 = null;
    var bestDiff: Float = std.math.floatMax(Float);

    const left = src.toLab();
    // first 4 elements are always transparent
    for (4..palette.len) |i| {
        const right = palette[i].toLab();
        const diff = cie_de2000(left, right);
        if (diff < bestDiff) {
            bestDiff = diff;
            bestIndex = @intCast(i);
        }
    }

    return bestIndex.?;
}

pub fn calculateAllShades() [TOTAL_COLORS]RGB24 {
    @setEvalBranchQuota(2000);
    var colors: [TOTAL_COLORS]RGB24 = undefined;
    for (0..BASE_COLORS.len) |base_i| {
        const base = BASE_COLORS[base_i];

        for (0..SHADE_MULTIPLIERS.len) |shade_i| {
            const multiplier = SHADE_MULTIPLIERS[shade_i];
            const r = applyMultiplier(base.r, multiplier);
            const g = applyMultiplier(base.g, multiplier);
            const b = applyMultiplier(base.b, multiplier);

            colors[(base_i * 4) + shade_i] = .{ .r = r, .g = g, .b = b };
        }
    }
    return colors;
}

pub const RGB24 = struct {
    r: u8,
    g: u8,
    b: u8,

    fn toLinear(self: RGB24) LinearRGB {
        const normalized = [3]Float {
            @as(Float, @floatFromInt(self.r)) / 255.0,
            @as(Float, @floatFromInt(self.g)) / 255.0,
            @as(Float, @floatFromInt(self.b)) / 255.0,
        };

        var linearRgb: [3]Float = undefined;
        for (&linearRgb, normalized) |*l, n| {
            l.* = if (n > 0.04045) pow(Float, ((n + 0.055) / 1.055), 2.4)
                  else             n / 12.92;
        }

        return .{ .r = linearRgb[0], .g = linearRgb[1], .b = linearRgb[2] };
    }

    pub fn toXYZ(self: RGB24) XYZ {
        return self.toLinear().toXYZ();
    }

    pub fn toLab(self: RGB24) Lab {
        return self.toXYZ().toLab();
    }
};

pub const LinearRGB = struct {
    r: Float,
    g: Float,
    b: Float,

    fn toXYZ(self: LinearRGB) XYZ {
        const linear = [3]Float{ self.r, self.g, self.b };
        const transformMatrix = [3][3]Float {
            .{ 0.4124564, 0.3575761, 0.1804375 },
            .{ 0.2126729, 0.7151522, 0.0721750 },
            .{ 0.0193339, 0.1191920, 0.9503041 }
        };
        var out: [3]Float = undefined;
        for (transformMatrix, 0..transformMatrix.len) |row, i| {
            var sum: Float = 0;
            for (0..row.len) |j| {
                sum += row[j] * linear[j];
            }
            out[i] = sum;
        }
        return .{ .x = out[0], .y = out[1], .z = out[2] };
    }
};

pub const XYZ = struct {
    x: Float,
    y: Float,
    z: Float,

    fn toLab(self: XYZ) Lab {
        const D65: XYZ = .{ .x = 0.95047, .y = 1.00000, .z = 1.08883 };

        const fX = _f(self.x / D65.x);
        const fY = _f(self.y / D65.y);
        const fZ = _f(self.z / D65.z);

        return .{
            .L = 116.0 * fY - 16.0,
            .a = 500.0 * (fX - fY),
            .b = 200.0 * (fY - fZ),
        };
    }

    fn _f(t: Float) Float {
        const d = 216.0 / 24389.0;
        const k = 24389.0 / 27.0;
        return if (t > d) std.math.cbrt(t)
               else       ((k * t + 16.0) / 116.0);
    }
};

pub const Lab = struct { L: Float, a: Float, b: Float };

fn _h_prime(aPrime: Float, b: Float, Cprime: Float) Float {
    // The inverse tangent is indeterminate if both a′ and b are zero (which also means that the corresponding C′ is
    // zero); in that case, set the hue angle to zero.
    if (aPrime == 0 and b == 0) {
        assert(Cprime == 0);
        return 0;
    }

    var ret = atan2(b, aPrime);
    if (ret < 0) {
        ret += two_pi;
    }
    return ret;
}

fn _dh_prime(h1prime: Float, h2prime: Float, C1prime: Float, C2prime: Float) Float {
    // When either C′1 or C′2 is zero, then Δh′ is irrelevant and may be set to zero
    if (C1prime == 0 or C2prime == 0) {
        return 0;
    }

    const delta = h2prime - h1prime;
    if (delta > pi) {
        return delta - two_pi;
    } else if (delta < -pi) {
        return delta + two_pi;
    } else {
        return delta;
    }
}

fn _hBar_prime(C1prime: Float, C2prime: Float, h1prime: Float, h2prime: Float) Float {
    // When either C′1 or C′2 is zero, then h′ is h′1+h′2
    const hprimeSum = h1prime + h2prime;
    if (C1prime == 0 or C2prime == 0) {
        return hprimeSum;
    }

    const delta = h1prime - h2prime;
    var numerator: Float = 0;
    if (@abs(delta) <= pi) {
        numerator = hprimeSum;
    } else {
        // @abs(delta) > pi
        if (hprimeSum < two_pi) {
            numerator = hprimeSum + two_pi;
        } else {
            // hprimeSum >= two_pi
            numerator = hprimeSum - two_pi;
        }
    }
    return numerator / 2.0;
}

fn cie_de2000(a: Lab, b: Lab) Float {
    const dLp = b.L - a.L;
    const LB = (a.L + b.L) / 2.0;

    const C1 = @sqrt(_square(a.a) + _square(a.b));
    const C2 = @sqrt(_square(b.a) + _square(b.b));
    const CB = (C1 + C2) / 2.0;

    const G = 0.5 * (1 - @sqrt(_pow7(CB) / (_pow7(CB) + _pow7(25.0))));
    const a1p = (1 + G) * a.a;
    const a2p = (1 + G) * b.a;

    const C1p = @sqrt(_square(a1p) + _square(a.b));
    const C2p = @sqrt(_square(a2p) + _square(b.b));
    const CBp = (C1p + C2p) / 2.0;
    const dCp = C2p - C1p;

    const h1p = _h_prime(a1p, a.b, C1p);
    const h2p = _h_prime(a2p, b.b, C2p);

    const dhp = _dh_prime(h1p, h2p, C1p, C2p);

    const dHp = 2.0 * @sqrt(C1p * C2p) * @sin(dhp / 2.0);
    const hBp = _hBar_prime(C1p, C2p, h1p, h2p);

    const T = 1.0 - 0.17 * @cos(hBp - D2R(30.0)) +
        0.24 * @cos(2.0 * hBp) +
        0.32 * @cos(3.0 * hBp + D2R(6.0)) -
        0.20 * @cos(4.0 * hBp - D2R(63.0));

    const dTheta = D2R(30) * @exp(-_square((hBp - D2R(275.0)) / D2R(25)));
    const RC = 2 * @sqrt(_pow7(CBp) / (_pow7(CBp) + _pow7(25.0)));

    const SL = 1.0 + (0.015 * _square(LB - 50.0)) / @sqrt(20.0 + _square(LB - 50.0));
    const SC = 1.0 + (0.045 * CBp);
    const SH = 1.0 + (0.015 * CBp * T);
    const RT = -@sin(2 * dTheta) * RC;

    return _cie_de2000_final(dLp, 1.0, SL, dCp, 1.0, SC, dHp, 1.0, SH, RT);
}

fn _cie_de2000_final(dLp: Float, kL: Float, SL: Float, dCp: Float, kC: Float, SC: Float, dHp: Float, kH: Float, SH: Float, RT: Float) Float {
    const p1 = dLp / (kL * SL);
    const p2 = dCp / (kC * SC);
    const p3 = dHp / (kH * SH);
    const p4 = RT * p2 * p3;
    return @sqrt(_square(p1) + _square(p2) + _square(p3) + p4);
}

fn _square(val: Float) Float {
    return val * val;
}

fn _pow7(val: Float) Float {
    return std.math.pow(Float, val, 7);
}

inline fn applyMultiplier(val: u32, multiplier: u32) u8 {
    return @intFromFloat(@round(@as(Float, @floatFromInt(val * multiplier)) / 255.0));
}

// First 4 values (transparent) are pure black; we don't match against them
const TOTAL_COLORS = (BASE_COLORS.len * 4);
const SHADE_MULTIPLIERS = [_]u32{ 180, 220, 255, 135 };
const BASE_COLORS = [_]RGB24 {
    .{ .r = 0, .g = 0, .b = 0 },
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
    .{ .r = 100, .g = 100, .b = 100 },
    .{ .r = 216, .g = 175, .b = 147 },
    .{ .r = 127, .g = 167, .b = 150 },
};

const expectApproxEqAbs = std.testing.expectApproxEqAbs;
test "RGB to LAB" {
    // truth values derived from scikit's skimage python module
    // and https://physicallybased.info/tools/color-space-converter/
    // hopefully they're correct...
    const rgb: RGB24 = .{ .r = 104, .g = 76, .b = 107 };

    const linear = rgb.toLinear();
    try expectApproxEqAbs(0.138432, linear.r, 0.001);
    try expectApproxEqAbs(0.072272, linear.g, 0.001);
    try expectApproxEqAbs(0.147027, linear.b, 0.001);

    const xyz = linear.toXYZ();
    try expectApproxEqAbs(0.109467, xyz.x, 0.001);
    try expectApproxEqAbs(0.091737, xyz.y, 0.001);
    try expectApproxEqAbs(0.151045, xyz.z, 0.001);

    const lab = xyz.toLab();
    try expectApproxEqAbs(36.316554, lab.L, 0.001);
    try expectApproxEqAbs(17.766642, lab.a, 0.001);
    try expectApproxEqAbs(-13.324718, lab.b, 0.001);
}