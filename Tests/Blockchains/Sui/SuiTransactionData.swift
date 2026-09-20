// `BCS`, `SuiObjectReference`, `UnsignedSuiTransaction`, and
// `UnsignedCoinObjectTransfer` have been promoted from this test-only file
// to WalletKit Sources:
//
//   Sources/Static/Blockchains/Sui/BCS.swift
//   Sources/Static/Blockchains/Sui/SuiObjectReference.swift
//   Sources/Static/Blockchains/Sui/SuiUnsignedTransactions.swift
//
// All are now `public` and imported via `import WalletKit` wherever they
// are used (SuiTransactionDataTests.swift, SuiLocalnetTests.swift,
// SuiTransactionBuilderTests.swift).
//
// `UnsignedSingleCoinSplitTransfer` and `UnsignedMultiCoinMergeSplitTransfer`
// are new shapes added alongside the promoted types in SuiUnsignedTransactions.swift,
// used by `SuiTransactionBuilder`.
