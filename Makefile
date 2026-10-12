# Requires on the host machine:
#   - Rust via rustup (this drives `rustup target add` for you)
#   - Xcode command line tools (xcodebuild, lipo)
#   - protoc, protoc-gen-swift, and protoc-gen-grpc-swift (v2, binary name
#     `protoc-gen-grpc-swift-2`) for `make sui-grpc` — e.g.
#     `brew install protobuf swift-protobuf protoc-gen-grpc-swift`

export MACOSX_DEPLOYMENT_TARGET := 15.0
export IPHONEOS_DEPLOYMENT_TARGET := 18.0

RUST_BIN_DIR := $(HOME)/.cargo/bin
export PATH := $(RUST_BIN_DIR):$(PATH)

CARGO ?= $(shell command -v cargo 2>/dev/null || echo $(RUST_BIN_DIR)/cargo)
RUSTUP ?= $(shell command -v rustup 2>/dev/null || echo $(RUST_BIN_DIR)/rustup)

SOURCES_DIR := Sources
RUST_DIR := $(SOURCES_DIR)/Rust
CRATE_DIR := $(RUST_DIR)/walletkit-ffi
TARGET_DIR := $(RUST_DIR)/target
LIB_NAME := libwalletkit_ffi.a

BUILD_DIR := .build
BINDINGS_DIR := $(BUILD_DIR)/bindings
HEADERS_DIR := $(BUILD_DIR)/headers

DOCS_DIR := docs
DOCS_SITE_DIR := Site
DOCS_BUILD_DIR := $(BUILD_DIR)/docs-site
DOCS_BASE_PATH ?= WalletKit
# $(call docs_redirect,<file>,<relative target>): write a static redirect page.
docs_redirect = printf '%s\n' '<!doctype html>' '<meta charset="utf-8">' \
	'<meta http-equiv="refresh" content="0; url=$(2)">' '<link rel="canonical" href="$(2)">' \
	'<title>Redirecting…</title>' '<a href="$(2)">Continue to the documentation</a>' > $(1)
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

ifneq ($(GITHUB_ACTIONS),)
# CI only runs tests: build the macOS arm64 slice alone.
MACOS_TARGETS := aarch64-apple-darwin
ALL_TARGETS := $(MACOS_TARGETS)
else
# Apple Silicon + Intel Mac, fused into one macOS slice.
MACOS_TARGETS := aarch64-apple-darwin x86_64-apple-darwin
# Apple Silicon + Intel simulator, fused into one iOS-simulator slice.
IOS_SIM_TARGETS := aarch64-apple-ios-sim x86_64-apple-ios
# Real devices are arm64-only; no lipo fusing needed for this slice.
IOS_DEVICE_TARGET := aarch64-apple-ios

ALL_TARGETS := $(MACOS_TARGETS) $(IOS_SIM_TARGETS) $(IOS_DEVICE_TARGET)
endif

MACOS_LIB := $(BUILD_DIR)/macos/$(LIB_NAME)
IOS_SIM_LIB := $(BUILD_DIR)/ios-simulator/$(LIB_NAME)
IOS_DEVICE_LIB := $(TARGET_DIR)/$(IOS_DEVICE_TARGET)/release/$(LIB_NAME)

XCFRAMEWORK_LIBS := -library $(MACOS_LIB) -headers $(HEADERS_DIR)
ifeq ($(GITHUB_ACTIONS),)
XCFRAMEWORK_LIBS += \
	-library $(IOS_DEVICE_LIB) -headers $(HEADERS_DIR) \
	-library $(IOS_SIM_LIB) -headers $(HEADERS_DIR)
endif

# UniFFI embeds its interface metadata in the compiled library itself, and
# that metadata is platform/arch-agnostic — so bindings only need to be
# generated once, from whichever build finished first.
BINDGEN_SOURCE_LIB := $(TARGET_DIR)/aarch64-apple-darwin/release/$(LIB_NAME)

.DEFAULT_GOAL := spm
.PHONY: all bitcoin-testing clean docs docs-index docs-preview rust-targets solana-testing sui-grpc test walletkit-ffi

all: $(XCFRAMEWORK) test docs docs-index

docs: $(XCFRAMEWORK)
	@echo "==> Building DocC documentation into $(DOCS_DIR)/"
	@rm -rf $(DOCS_BUILD_DIR)
	@mkdir -p $(DOCS_BUILD_DIR)
	@swift package --allow-writing-to-directory $(DOCS_BUILD_DIR) \
		generate-documentation --target WalletKit --target WalletKitTesting \
		--enable-experimental-combined-documentation --output-path $(DOCS_BUILD_DIR) \
		--disable-indexing --transform-for-static-hosting --hosting-base-path $(DOCS_BASE_PATH)
	@test -d $(DOCS_BUILD_DIR)/documentation/walletkit -a -d $(DOCS_BUILD_DIR)/documentation/walletkittesting || { \
		echo "DocC didn't produce a combined site in $(DOCS_BUILD_DIR)"; exit 1; }
	@mkdir -p $(DOCS_DIR)
	@rsync -a --delete --exclude .DS_Store $(DOCS_BUILD_DIR)/ $(DOCS_DIR)/
	@$(MAKE) --no-print-directory docs-index
	@touch $(DOCS_DIR)/.nojekyll

# Serve $(DOCS_DIR)/ at http://localhost:$(DOCS_PREVIEW_PORT)/$(DOCS_BASE_PATH)/, matching
# GitHub Pages. DocC pages load their content with JavaScript from absolute
# /$(DOCS_BASE_PATH)/ paths, so they render empty when opened as file:// URLs.
DOCS_PREVIEW_PORT ?= 8000
docs-preview:
	@test -f $(DOCS_DIR)/index.html || { echo "No site in $(DOCS_DIR)/ — run 'make docs' first"; exit 1; }
	@preview_root="$$(mktemp -d "$${TMPDIR:-/tmp}/walletkit-docs.XXXXXX")"; \
		ln -s "$(CURDIR)/$(DOCS_DIR)" "$$preview_root/$(DOCS_BASE_PATH)"; \
		echo "==> Serving http://localhost:$(DOCS_PREVIEW_PORT)/$(DOCS_BASE_PATH)/ (Ctrl-C to stop)"; \
		python3 -m http.server $(DOCS_PREVIEW_PORT) --bind 127.0.0.1 --directory "$$preview_root"

# Landing page at the docs site root, linking WalletKit and WalletKitTesting.
# Rebuild it alone (without regenerating DocC) after editing $(DOCS_SITE_DIR)/index.md.
docs-index:
	@echo "==> Building docs landing page from $(DOCS_SITE_DIR)/index.md"
	@mkdir -p $(DOCS_DIR)
	@pandoc $(DOCS_SITE_DIR)/index.md --standalone \
		--template $(DOCS_SITE_DIR)/template.html --output $(DOCS_DIR)/index.html

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
	@echo "==> Building walletkit-ffi (release): $(ALL_TARGETS)"
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
ifeq ($(GITHUB_ACTIONS),)
	@lipo -create $(foreach t,$(IOS_SIM_TARGETS),$(TARGET_DIR)/$(t)/release/$(LIB_NAME)) -output $(IOS_SIM_LIB)
endif

	@echo "==> Assembling headers + module map"
	@rm -rf $(HEADERS_DIR)
	@mkdir -p $(HEADERS_DIR)
	@cp $(BINDINGS_DIR)/*.h $(HEADERS_DIR)/
	@cp $(BINDINGS_DIR)/*.modulemap $(HEADERS_DIR)/module.modulemap

	@echo "==> Creating XCFramework"
	@mkdir -p $(FRAMEWORKS_DIR)
	@rm -rf $(XCFRAMEWORK)
	@xcodebuild -create-xcframework \
		$(XCFRAMEWORK_LIBS) \
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
	@# electrs is a host-only tool: keep the exported deployment targets out of
	@# it. With MACOSX_DEPLOYMENT_TARGET set, Xcode 27's linker emits proc-macro
	@# dylibs that macOS 27's dyld rejects, surfacing as E0463 "can't find crate".
	@cd $(BITCOIN_TESTING_DIR)/electrs-src && env -u MACOSX_DEPLOYMENT_TARGET -u IPHONEOS_DEPLOYMENT_TARGET \
		$(CARGO) build --release --bin electrs
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
# Local-node tests (`.localNode`, Tests/Support/LocalNodeTrait.swift) are
# skipped in CI, so don't provision their bitcoind/electrs/Agave binaries there.
ifeq ($(GITHUB_ACTIONS),)
SWIFT_TEST_NODE_DEPS := bitcoin-testing solana-testing
endif

swift-tests: $(XCFRAMEWORK) $(SWIFT_TEST_NODE_DEPS)
	@echo "==> Running Swift tests"
	@swift test
	@cd

clean:
	@rm -rf $(BUILD_DIR) $(DOCS_DIR) $(FRAMEWORKS_DIR) $(GENERATED_SOURCES_DIR) $(GENERATED_GRPC_SOURCES_DIR)
	@cd $(CRATE_DIR) && $(CARGO) clean
	@rm -rf Derived *.xcodeproj *.xcworkspace
