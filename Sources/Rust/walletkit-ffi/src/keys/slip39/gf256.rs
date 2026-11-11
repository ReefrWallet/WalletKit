//! GF(256) arithmetic and Lagrange interpolation over the Rijndael field.

const fn tables() -> ([u8; 255], [u8; 256]) {
    let mut exp = [0u8; 255];
    let mut log = [0u8; 256];
    let mut poly: u16 = 1;
    let mut i = 0;
    while i < 255 {
        exp[i] = poly as u8;
        log[poly as usize] = i as u8;
        poly = (poly << 1) ^ poly;
        if poly & 0x100 != 0 {
            poly ^= 0x11B;
        }
        i += 1;
    }
    (exp, log)
}

const TABLES: ([u8; 255], [u8; 256]) = tables();

/// Interpolates the polynomial through `shares` (x, y-bytes) at `x`.
pub(super) fn interpolate(shares: &[(u8, Vec<u8>)], x: u8) -> Vec<u8> {
    let (exp, log) = (&TABLES.0, &TABLES.1);
    if let Some((_, value)) = shares.iter().find(|(sx, _)| *sx == x) {
        return value.clone();
    }

    let log_prod: i32 = shares.iter().map(|(sx, _)| i32::from(log[usize::from(sx ^ x)])).sum();
    let len = shares[0].1.len();
    let mut result = vec![0u8; len];

    for (sx, value) in shares {
        let others: i32 = shares.iter().map(|(ox, _)| i32::from(log[usize::from(sx ^ ox)])).sum();
        let log_basis = (log_prod - i32::from(log[usize::from(sx ^ x)]) - others).rem_euclid(255);
        for (acc, byte) in result.iter_mut().zip(value.iter()) {
            if *byte != 0 {
                *acc ^= exp[((i32::from(log[usize::from(*byte)]) + log_basis) % 255) as usize];
            }
        }
    }

    result
}
