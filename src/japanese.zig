const std = @import("std");

// Sorted records: a little-endian Unicode scalar followed by 16 bitmap rows,
// two bytes per row with the leftmost pixel in the most significant bit.
const data = @embedFile("fonts/japanese.bin");
pub const Bitmap = [32]u8;
const record_size = 3 + @sizeOf(Bitmap);

pub fn lookup(code: u21) ?*const Bitmap {
    if (code < 0x3000) return null;
    var low: usize = 0;
    var high: usize = data.len / record_size;
    while (low < high) {
        const mid = low + (high - low) / 2;
        const record = data[mid * record_size ..][0..record_size];
        const key = std.mem.readInt(u24, record[0..3], .little);
        if (code == key) return record[3..];
        if (code < key) high = mid else low = mid + 1;
    }
    return null;
}

pub fn composeKana(base: u21, mark: u21) ?u21 {
    const h_row = switch (base) {
        'は', 'ひ', 'ふ', 'へ', 'ほ', 'ハ', 'ヒ', 'フ', 'ヘ', 'ホ' => true,
        else => false,
    };
    if (mark == 0x309a and h_row) return base + 2;
    if (mark != 0x3099) return null;
    if (h_row) return base + 1;
    return switch (base) {
        'う', 'ウ' => base + 78,
        'ワ'...'ヲ' => base + 8,
        'か',
        'き',
        'く',
        'け',
        'こ',
        'さ',
        'し',
        'す',
        'せ',
        'そ',
        'た',
        'ち',
        'つ',
        'て',
        'と',
        'ゝ',
        'カ',
        'キ',
        'ク',
        'ケ',
        'コ',
        'サ',
        'シ',
        'ス',
        'セ',
        'ソ',
        'タ',
        'チ',
        'ツ',
        'テ',
        'ト',
        'ヽ',
        => base + 1,
        else => null,
    };
}
