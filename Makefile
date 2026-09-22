# Requires on the host machine:
#   - Rust via rustup (this drives `rustup target add` for you)
#   - Xcode command line tools (xcodebuild, lipo)
#   - protoc, protoc-gen-swift, and protoc-gen-grpc-swift (v2, binary name
#     `protoc-gen-grpc-swift-2`) for `make sui-grpc` — e.g.
#     `brew install protobuf swift-protobuf protoc-gen-grpc-swift`
#   - `git`, `curl`, `tar`, and `cargo` (already required above) for
#     `make bitcoin-testing`
#   - `git submodule update --init --recursive` once after cloning, to
#     fetch Sources/gRPC/sui-rpc-api-v2's .proto files

RUST_BIN_DIR := $(HOME)/.cargo/bin
export PATH := $(RUST_BIN_DIR):$(PATH)

CARGO ?= $(shell command -v cargo 2>/dev/null || echo $(RUST_BIN_DIR)/cargo)
RUSTUP ?= $(shell command -v rustup 2>/dev/null || echo $(RUST_BIN_DIR)/rustup)

SOURCES_DIR := Sources
RUST_DIR := $(SOURCES_DIR)/Rust
CRATE_DIR := $(RUST_DIR)/walletkit-ffi
TARGET_DIR := $(RUST_DIR)/target
LIB_NAME := libwalletkit_ffi.a

# Hidden scratch dir for intermediate build artifacts (per-target/platform
# libs, headers staging, raw bindgen output). Nothing in here is meant to
# be committed or consumed directly — see Frameworks/ and Sources/ below
# for the actual deliverables.
BUILD_DIR := .build
BINDINGS_DIR := $(BUILD_DIR)/bindings
HEADERS_DIR := $(BUILD_DIR)/headers

# Deliverables: what the rest of the project (Xcode/SPM) actually consumes.
FRAMEWORKS_DIR := Frameworks
GENERATED_SOURCES_DIR := $(SOURCES_DIR)/Generated/Bindings
XCFRAMEWORK := $(FRAMEWORKS_DIR)/WalletKit.xcframework

# Sui gRPC API
SUI_PROTO_SUBMODULE := $(SOURCES_DIR)/gRPC/sui-rpc-api-v2
SUI_PROTO_DIR := $(SUI_PROTO_SUBMODULE)/proto
GENERATED_GRPC_SOURCES_DIR := $(SOURCES_DIR)/Generated/gRPC

# bitcoin-testing: bitcoind + electrs, for BitcoinNode
BITCOIN_CORE_VERSION := 29.0
UNAME_ARCH := $(shell uname -m)
ifeq ($(UNAME_ARCH),arm64)
BITCOIN_CORE_PLATFORM := arm64-apple-darwin
else
BITCOIN_CORE_PLATFORM := x86_64-apple-darwin
endif

BITCOIN_TESTING_DIR := $(BUILD_DIR)/bitcoin-testing
BITCOIN_TESTING_BIN_DIR := $(BITCOIN_TESTING_DIR)/bin
BITCOIN_CORE_STAMP := $(BITCOIN_TESTING_DIR)/.bitcoin-core-stamp
ELECTRS_STAMP := $(BITCOIN_TESTING_DIR)/.electrs-stamp
ELECTRS_REPO := https://github.com/Blockstream/electrs.git

# Agave (the maintained Solana validator fork) release used for
# `solana-test-validator`/`solana`/`solana-keygen`/`spl-token` — no `mise`
# registry entry exists for any of these (checked: `mise registry` has no
# `solana` backend), so, like `bitcoin-testing` above, this downloads a
# prebuilt release tarball rather than provisioning lazily.
AGAVE_VERSION := v4.3.0
ifeq ($(UNAME_ARCH),arm64)
SOLANA_PLATFORM := aarch64-apple-darwin
else
SOLANA_PLATFORM := x86_64-apple-darwin
endif

SOLANA_TESTING_DIR := $(BUILD_DIR)/solana-testing
SOLANA_TESTING_BIN_DIR := $(SOLANA_TESTING_DIR)/bin
SOLANA_RELEASE_STAMP := $(SOLANA_TESTING_DIR)/.solana-release-stamp

# Apple Silicon + Intel Mac, fused into one macOS slice.
MACOS_TARGETS := aarch64-apple-darwin x86_64-apple-darwin
# Apple Silicon + Intel simulator, fused into one iOS-simulator slice.
IOS_SIM_TARGETS := aarch64-apple-ios-sim x86_64-apple-ios
# Real devices are arm64-only; no lipo fusing needed for this slice.
IOS_DEVICE_TARGET := aarch64-apple-ios

ALL_TARGETS := $(MACOS_TARGETS) $(IOS_SIM_TARGETS) $(IOS_DEVICE_TARGET)

MACOS_LIB := $(BUILD_DIR)/macos/$(LIB_NAME)
IOS_SIM_LIB := $(BUILD_DIR)/ios-simulator/$(LIB_NAME)
IOS_DEVICE_LIB := $(TARGET_DIR)/$(IOS_DEVICE_TARGET)/release/$(LIB_NAME)

# UniFFI embeds its interface metadata in the compiled library itself, and
# that metadata is platform/arch-agnostic — so bindings only need to be
# generated once, from whichever build finished first.
BINDGEN_SOURCE_LIB := $(TARGET_DIR)/aarch64-apple-darwin/release/$(LIB_NAME)

.DEFAULT_GOAL := spm
.PHONY: all walletkit-ffi sui-grpc bitcoin-testing solana-testing test clean rust-targets

all: $(XCFRAMEWORK) test

spm: walletkit-ffi sui-grpc
	@swift build

$(XCFRAMEWORK): spm

# Internal helper, not one of the four requested targets: makes sure the
# Apple cross-compilation targets are installed before building. Cheap and
# idempotent, so it's safe to run on every `make walletkit-ffi`.
rust-targets:
	@for target in $(ALL_TARGETS); do \
		$(RUSTUP) target add $$target >/dev/null 2>&1 || true; \
	done

test: rust-tests swift-tests

walletkit-ffi: rust-targets
	@echo "==> Building walletkit-ffi (release) for macOS + iOS device + iOS simulator"
	@cd $(RUST_DIR) && for target in $(ALL_TARGETS); do \
		echo "  -- $$target"; \
		$(CARGO) build --release --target $$target || exit 1; \
	done

	@echo "==> Generating Swift bindings"
	@rm -rf $(BINDINGS_DIR)
	@mkdir -p $(BINDINGS_DIR)
	@cd $(CRATE_DIR) && $(CARGO) run --quiet --features cli --bin uniffi-bindgen -- \
		generate --library $(abspath $(BINDGEN_SOURCE_LIB)) --language swift --out-dir $(abspath $(BINDINGS_DIR))

	@echo "==> Copying generated Swift bindings to $(GENERATED_SOURCES_DIR)"
	@mkdir -p $(GENERATED_SOURCES_DIR)
	@cp $(BINDINGS_DIR)/*.swift $(GENERATED_SOURCES_DIR)/

	@echo "==> Fusing per-platform slices with lipo"
	@mkdir -p $(BUILD_DIR)/macos $(BUILD_DIR)/ios-simulator
	@lipo -create $(foreach t,$(MACOS_TARGETS),$(TARGET_DIR)/$(t)/release/$(LIB_NAME)) -output $(MACOS_LIB)
	@lipo -create $(foreach t,$(IOS_SIM_TARGETS),$(TARGET_DIR)/$(t)/release/$(LIB_NAME)) -output $(IOS_SIM_LIB)

	@echo "==> Assembling headers + module map"
	@rm -rf $(HEADERS_DIR)
	@mkdir -p $(HEADERS_DIR)
	@cp $(BINDINGS_DIR)/*.h $(HEADERS_DIR)/
	@cp $(BINDINGS_DIR)/*.modulemap $(HEADERS_DIR)/module.modulemap

	@echo "==> Creating XCFramework"
	@mkdir -p $(FRAMEWORKS_DIR)
	@rm -rf $(XCFRAMEWORK)
	@xcodebuild -create-xcframework \
		-library $(MACOS_LIB) -headers $(HEADERS_DIR) \
		-library $(IOS_DEVICE_LIB) -headers $(HEADERS_DIR) \
		-library $(IOS_SIM_LIB) -headers $(HEADERS_DIR) \
		-output $(XCFRAMEWORK)

sui-grpc:
	@test -d $(SUI_PROTO_DIR)/sui/rpc/v2 || { \
		echo "$(SUI_PROTO_SUBMODULE) is empty — run: git submodule update --init --recursive"; \
		exit 1; \
	}

	@echo "==> Generating Swift bindings for Sui's gRPC API"
	@rm -rf $(GENERATED_GRPC_SOURCES_DIR)
	@mkdir -p $(GENERATED_GRPC_SOURCES_DIR)
	@protoc -I $(SUI_PROTO_DIR) \
		--swift_opt=Visibility=Public \
		--swift_out=$(GENERATED_GRPC_SOURCES_DIR) \
		--grpc-swift-2_opt=Visibility=Public,Server=false,Client=true \
		--grpc-swift-2_out=$(GENERATED_GRPC_SOURCES_DIR) \
		$(SUI_PROTO_DIR)/sui/rpc/v2/*.proto \
		$(SUI_PROTO_DIR)/google/rpc/*.proto
	@echo "    Swift bindings: $(GENERATED_GRPC_SOURCES_DIR)/sui/rpc/v2/*.swift"

bitcoin-testing: $(BITCOIN_CORE_STAMP) $(ELECTRS_STAMP)

# Downloads the official prebuilt bitcoind/bitcoin-cli binaries. A single
# stamp file (rather than making $(BITCOIN_TESTING_BIN_DIR)/bitcoind and
# .../bitcoin-cli both targets of one recipe) avoids Make's classic
# multiple-targets-one-recipe pitfall, where invoking the two names
# separately can run the recipe twice.
$(BITCOIN_CORE_STAMP):
	@echo "==> Downloading bitcoind/bitcoin-cli $(BITCOIN_CORE_VERSION) ($(BITCOIN_CORE_PLATFORM))"
	@mkdir -p $(BITCOIN_TESTING_BIN_DIR)
	@curl -sL -o $(BITCOIN_TESTING_DIR)/bitcoin-core.tar.gz \
		https://bitcoincore.org/bin/bitcoin-core-$(BITCOIN_CORE_VERSION)/bitcoin-$(BITCOIN_CORE_VERSION)-$(BITCOIN_CORE_PLATFORM).tar.gz
	@tar -xzf $(BITCOIN_TESTING_DIR)/bitcoin-core.tar.gz -C $(BITCOIN_TESTING_DIR)
	@cp $(BITCOIN_TESTING_DIR)/bitcoin-$(BITCOIN_CORE_VERSION)/bin/bitcoind $(BITCOIN_TESTING_BIN_DIR)/bitcoind
	@cp $(BITCOIN_TESTING_DIR)/bitcoin-$(BITCOIN_CORE_VERSION)/bin/bitcoin-cli $(BITCOIN_TESTING_BIN_DIR)/bitcoin-cli
	@rm -rf $(BITCOIN_TESTING_DIR)/bitcoin-$(BITCOIN_CORE_VERSION) $(BITCOIN_TESTING_DIR)/bitcoin-core.tar.gz
	@touch $(BITCOIN_CORE_STAMP)

# Clones and builds Blockstream's electrs fork (`new-index` branch) — the
# one with `--http-addr` Esplora REST support, unlike upstream
# `romanz/electrs`, which is Electrum-only. No prebuilt binary exists for
# it, so this is a from-source `cargo build --release`, taking a few
# minutes the first time (rocksdb + jemalloc; no cmake required).
$(ELECTRS_STAMP):
	@echo "==> Cloning + building electrs (Blockstream fork, new-index branch)"
	@rm -rf $(BITCOIN_TESTING_DIR)/electrs-src
	@git clone --branch new-index --depth 1 $(ELECTRS_REPO) $(BITCOIN_TESTING_DIR)/electrs-src
	@cd $(BITCOIN_TESTING_DIR)/electrs-src && $(CARGO) build --release --bin electrs
	@mkdir -p $(BITCOIN_TESTING_BIN_DIR)
	@cp $(BITCOIN_TESTING_DIR)/electrs-src/target/release/electrs $(BITCOIN_TESTING_BIN_DIR)/electrs
	@touch $(ELECTRS_STAMP)

solana-testing: $(SOLANA_RELEASE_STAMP)

# Downloads the official prebuilt Agave release tarball, which already
# bundles `solana-test-validator`, `solana`, `solana-keygen`, and
# `spl-token` in one archive — unlike Bitcoin's split bitcoind/electrs
# provisioning above, there's nothing here that needs building from
# source.
$(SOLANA_RELEASE_STAMP):
	@echo "==> Downloading Agave $(AGAVE_VERSION) ($(SOLANA_PLATFORM))"
	@mkdir -p $(SOLANA_TESTING_BIN_DIR)
	@curl -sL -o $(SOLANA_TESTING_DIR)/solana-release.tar.bz2 \
		https://github.com/anza-xyz/agave/releases/download/$(AGAVE_VERSION)/solana-release-$(SOLANA_PLATFORM).tar.bz2
	@tar -xjf $(SOLANA_TESTING_DIR)/solana-release.tar.bz2 -C $(SOLANA_TESTING_DIR)
	@for binary in solana-test-validator solana solana-keygen spl-token; do \
		cp $(SOLANA_TESTING_DIR)/solana-release/bin/$$binary $(SOLANA_TESTING_BIN_DIR)/$$binary; \
	done
	@rm -rf $(SOLANA_TESTING_DIR)/solana-release $(SOLANA_TESTING_DIR)/solana-release.tar.bz2
	@touch $(SOLANA_RELEASE_STAMP)

# Rust test suite (from Cargo)
rust-tests:
	@echo "==> Running Rust tests"
	@cd $(CRATE_DIR) && $(CARGO) test
	@cd

# Swift test suite (from Package.swift)
swift-tests: $(XCFRAMEWORK) bitcoin-testing solana-testing
	@echo "==> Running Swift tests"
	@swift test
	@cd

clean:
	@rm -rf $(BUILD_DIR) $(FRAMEWORKS_DIR) $(GENERATED_SOURCES_DIR) $(GENERATED_GRPC_SOURCES_DIR)
	@cd $(CRATE_DIR) && $(CARGO) clean
	@rm -rf Derived *.xcodeproj *.xcworkspace
