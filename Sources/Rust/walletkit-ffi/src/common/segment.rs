//! `Segment`: a single index in a `DerivationPath`, hardened or not.

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Record)]
pub struct Segment {
    pub index: u32,
    pub hardened: bool,
}
