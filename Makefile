# WalletKit — top-level Makefile
#
# Targets:
#   make walletkit-ffi   Build the walletkit-ffi Rust crate for macOS,
#                        iOS device, and iOS simulator, and package the
#                        result as an XCFramework (Frameworks/) + Swift
#                        bindings (Sources/Generated/), consumed by the
#                        WalletKitRust target.
#
#   make sui-grpc        Generate Swift bindings (Sources/Generated/gRPC/)
#                        for Sui's gRPC API from the Sources/gRPC/
#                        sui-rpc-api-v2 submodule's .proto files, consumed
#                        by the WalletKitGRPC target. Independent of
#                        walletkit-ffi — a second, protoc-based codegen
#                        pipeline alongside the Rust/UniFFI one.
#
#   make test            Run the Rust test suite (cargo test), host target
#                        only — independent of walletkit-ffi.
#
#   make all             walletkit-ffi, sui-grpc, then test. (default target)
#
#   make clean           Remove all build output (.build/, Frameworks/,
#                        generated Sources/Generated/*.swift and
#                        Sources/Generated/gRPC/*.swift, and
#                        Rust/target/) plus Tuist-generated Xcode artifacts
#                        (Derived/, *.xcodeproj, *.xcworkspace) — preserves
#                        the hand-written sources under Sources/Static/.
#
# Requires on the host machine:
#   - Rust via rustup (this drives `rustup target add` for you)
#   - Xcode command line tools (xcodebuild, lipo)
#   - protoc, protoc-gen-swift, and protoc-gen-grpc-swift (v2, binary name
#     `protoc-gen-grpc-swift-2`) for `make sui-grpc` — e.g.
#     `brew install protobuf swift-protobuf protoc-gen-grpc-swift`
#   - `git submodule update --init --recursive` once after cloning, to
#     fetch Sources/gRPC/sui-rpc-api-v2's .proto files
#
# See Rust/README.md for the crate this wraps and Docs/Overview.md for the
# overall architecture.

RUST_BIN_DIR := $(HOME)/.cargo/bin
export PATH := $(RUST_BIN_DIR):$(PATH)

CARGO ?= $(shell command -v cargo 2>/dev/null || echo $(RUST_BIN_DIR)/cargo)
RUSTUP ?= $(shell command -v rustup 2>/dev/null || echo $(RUST_BIN_DIR)/rustup)
RUST_DIR := Rust
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
SOURCES_DIR := Sources

# Deliverables: what the rest of the project (Xcode/SPM) actually consumes.
FRAMEWORKS_DIR := Frameworks
GENERATED_SOURCES_DIR := $(SOURCES_DIR)/Generated/Bindings
XCFRAMEWORK := $(FRAMEWORKS_DIR)/WalletKit.xcframework

# --- sui-grpc: Sui gRPC API .proto -> Swift ---------------------------------

SUI_PROTO_SUBMODULE := $(SOURCES_DIR)/gRPC/sui-rpc-api-v2
SUI_PROTO_DIR := $(SUI_PROTO_SUBMODULE)/proto
GENERATED_GRPC_SOURCES_DIR := $(SOURCES_DIR)/Generated/gRPC

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

.DEFAULT_GOAL := all
.PHONY: all walletkit-ffi sui-grpc test clean rust-targets

all: walletkit-ffi sui-grpc test

# Internal helper, not one of the four requested targets: makes sure the
# Apple cross-compilation targets are installed before building. Cheap and
# idempotent, so it's safe to run on every `make walletkit-ffi`.
rust-targets:
	@for target in $(ALL_TARGETS); do \
		$(RUSTUP) target add $$target >/dev/null 2>&1 || true; \
	done

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

# --- test: Rust test suite, host target only --------------------------------

test:
	@echo "==> Running Rust tests (walletkit-ffi)"
	@cd $(CRATE_DIR) && $(CARGO) test

# --- clean -------------------------------------------------------------------

clean:
	@rm -rf $(BUILD_DIR) $(FRAMEWORKS_DIR) $(GENERATED_SOURCES_DIR) $(GENERATED_GRPC_SOURCES_DIR)
	@cd $(CRATE_DIR) && $(CARGO) clean
	@rm -rf Derived *.xcodeproj *.xcworkspace
