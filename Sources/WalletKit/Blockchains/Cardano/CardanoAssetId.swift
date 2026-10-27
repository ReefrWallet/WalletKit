import Foundation
import WalletKitRust

/// A Blockfrost asset unit: policy ID and asset name, both hex.
struct CardanoAssetId {
    let name: Data
    let policyId: Data

    init?(unit: String) {
        guard unit.count >= 56 else {
            return nil
        }

        let policyText = String(unit.prefix(56))
        let nameText = String(unit.dropFirst(56))

        guard let policyID = try? Data(hexString: policyText), let name = try? Data(hexString: nameText) else {
            return nil
        }

        self.name = name
        self.policyId = policyID
    }

    func ffi(quantity: String) -> CardanoAssetFfi {
        CardanoAssetFfi(name: name, policyId: policyId, quantity: quantity)
    }
}
