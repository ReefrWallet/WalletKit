//! Batched key reads: several public keys from one device command.

use std::sync::atomic::{AtomicU64, Ordering};

use crate::{HardwareCurve, HardwareError, HardwarePathSegment};

/// One read in a `HardwareDevice::read_keys` batch.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum HardwareKeyRequest {
    /// The Cardano Icarus/CIP-1852 account extended public key at `path`.
    CardanoXpub { path: Vec<HardwarePathSegment> },
    /// The secp256k1 extended public key at `path`, `xpub`-serialized
    /// whatever the chain.
    ExtendedPublicKey { path: Vec<HardwarePathSegment> },
    /// The raw public key at `path`.
    PublicKey { path: Vec<HardwarePathSegment>, curve: HardwareCurve },
}

/// The answer to one `HardwareKeyRequest`, of the matching kind.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum HardwareKeyResponse {
    CardanoXpub(String),
    ExtendedPublicKey(String),
    PublicKey(Vec<u8>),
}

/// Cancels batches issued before `cancel`, between their reads.
///
/// A batch takes a `ticket` when it is issued; `cancel` moves the epoch on,
/// so every earlier ticket is stale. Batches issued afterwards run normally.
#[derive(Debug, Default)]
pub struct BatchCancellation {
    epoch: AtomicU64,
}

impl BatchCancellation {
    /// Cancels every batch issued so far.
    pub fn cancel(&self) {
        self.epoch.fetch_add(1, Ordering::SeqCst);
    }

    /// Whether the batch holding `ticket` was cancelled.
    pub fn is_cancelled(&self, ticket: u64) -> bool {
        self.epoch.load(Ordering::SeqCst) != ticket
    }

    /// The ticket for a batch issued now.
    pub fn ticket(&self) -> u64 {
        self.epoch.load(Ordering::SeqCst)
    }
}

/// Runs `read` for each request in order, checking `is_cancelled` before
/// each one. The first error, or a cancellation, ends the batch.
pub fn read_key_batch(
    requests: &[HardwareKeyRequest],
    is_cancelled: impl Fn() -> bool,
    mut read: impl FnMut(&HardwareKeyRequest) -> Result<HardwareKeyResponse, HardwareError>,
) -> Result<Vec<HardwareKeyResponse>, HardwareError> {
    let mut responses = Vec::with_capacity(requests.len());

    for request in requests {
        if is_cancelled() {
            return Err(HardwareError::UserCancelled);
        }

        responses.push(read(request)?);
    }

    Ok(responses)
}

#[cfg(test)]
mod tests {
    use std::cell::Cell;

    use super::*;

    fn request(index: u32) -> HardwareKeyRequest {
        HardwareKeyRequest::PublicKey {
            path: vec![HardwarePathSegment { index, hardened: true }],
            curve: HardwareCurve::Ed25519,
        }
    }

    fn index(request: &HardwareKeyRequest) -> u8 {
        match request {
            HardwareKeyRequest::PublicKey { path, .. } => path[0].index as u8,
            _ => unreachable!(),
        }
    }

    #[test]
    fn answers_in_request_order() {
        let requests: Vec<_> = (0..4).map(request).collect();
        let responses = read_key_batch(&requests, || false, |r| Ok(HardwareKeyResponse::PublicKey(vec![index(r)])));
        let expected: Vec<_> = (0..4).map(|i| HardwareKeyResponse::PublicKey(vec![i])).collect();
        assert_eq!(responses, Ok(expected));
    }

    #[test]
    fn stops_at_the_first_error() {
        let reads = Cell::new(0);
        let requests: Vec<_> = (0..4).map(request).collect();
        let result = read_key_batch(&requests, || false, |r| {
            reads.set(reads.get() + 1);
            if index(r) == 1 {
                Err(HardwareError::Disconnected)
            } else {
                Ok(HardwareKeyResponse::PublicKey(vec![]))
            }
        });
        assert_eq!(result, Err(HardwareError::Disconnected));
        assert_eq!(reads.get(), 2);
    }

    #[test]
    fn cancellation_takes_effect_between_reads() {
        let cancellation = BatchCancellation::default();
        let ticket = cancellation.ticket();
        let reads = Cell::new(0);
        let requests: Vec<_> = (0..4).map(request).collect();
        let result = read_key_batch(&requests, || cancellation.is_cancelled(ticket), |_| {
            reads.set(reads.get() + 1);
            cancellation.cancel();
            Ok(HardwareKeyResponse::PublicKey(vec![]))
        });
        assert_eq!(result, Err(HardwareError::UserCancelled));
        assert_eq!(reads.get(), 1);
    }

    #[test]
    fn a_batch_issued_after_cancel_runs() {
        let cancellation = BatchCancellation::default();
        cancellation.cancel();
        let ticket = cancellation.ticket();
        let requests: Vec<_> = (0..2).map(request).collect();
        let result = read_key_batch(&requests, || cancellation.is_cancelled(ticket), |_| {
            Ok(HardwareKeyResponse::PublicKey(vec![]))
        });
        assert_eq!(result.map(|r| r.len()), Ok(2));
    }
}
