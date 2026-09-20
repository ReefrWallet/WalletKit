/// One BIP32-style derivation path segment: an index plus whether it's
/// hardened. Mirrors `walletkit-ffi`'s `common::Segment` so vendor crates
/// don't need to depend on `walletkit-ffi`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct HardwarePathSegment {
    pub index: u32,
    pub hardened: bool,
}

impl HardwarePathSegment {
    /// The BIP32 "address_n" encoding hardware wallet wire protocols use:
    /// the hardened flag folded into the index's top bit.
    pub fn to_address_n(&self) -> u32 {
        if self.hardened {
            self.index | 0x8000_0000
        } else {
            self.index
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn to_address_n_folds_in_the_hardened_bit() {
        assert_eq!(HardwarePathSegment { index: 44, hardened: true }.to_address_n(), 44 | 0x8000_0000);
        assert_eq!(HardwarePathSegment { index: 0, hardened: false }.to_address_n(), 0);
    }
}
