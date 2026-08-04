SHELL := /bin/sh
XCODE_DEVELOPER_DIR ?= /Applications/Xcode.app/Contents/Developer

.PHONY: deps bootstrap build test ui-test swift-test launch-at-login-test store-foundation-test milestone13-test milestone2-test helper-test extension-test homebrew-test release-notes-test release-workflow-test run icon sounds themes remote-artifacts package package-with-remote install install-with-remote signing-identity doctor candidate-write candidate-verify verify-release-version verify-release-readiness release-assets clean

deps:
	swift package resolve --disable-sandbox
	cargo fetch --locked --manifest-path helper/Cargo.toml
	@if [ -f extension/package-lock.json ]; then npm --prefix extension ci && npm --prefix extension audit --audit-level=info; fi

bootstrap:
	./scripts/bootstrap.sh

build:
	swift build
	cargo build --locked --manifest-path helper/Cargo.toml
	@if [ -f extension/package.json ]; then npm --prefix extension run build; fi

swift-test:
	swift run CoveCoreSmokeTests

launch-at-login-test:
	./Tests/run-launch-at-login-foundation-tests.sh

store-foundation-test:
	./Tests/run-cove-store-foundation-tests.sh

milestone13-test:
	./Tests/run-milestone13-foundation-tests.sh

milestone2-test:
	./Tests/run-milestone2-foundation-tests.sh

helper-test:
	cargo test --locked --manifest-path helper/Cargo.toml

extension-test:
	@if [ -f extension/package.json ]; then npm --prefix extension test; fi

homebrew-test:
	./Tests/test-homebrew-cask.sh

release-notes-test:
	./Tests/test-release-notes.sh

release-workflow-test:
	./Tests/test-release-workflow.sh

test: swift-test launch-at-login-test store-foundation-test milestone13-test milestone2-test helper-test extension-test homebrew-test release-notes-test release-workflow-test

ui-test:
	@locked=$$(ioreg -n Root -d1 -a 2>/dev/null | plutil -extract IOConsoleLocked raw -o - - 2>/dev/null) || { \
			echo "Unable to verify that the macOS console is unlocked; UI tests were not started." >&2; \
			exit 2; \
		}; \
		if [ "$$locked" = "true" ]; then \
			echo "UI tests require an unlocked macOS console; unlock the Mac and retry." >&2; \
			exit 2; \
		fi
	DEVELOPER_DIR="$(XCODE_DEVELOPER_DIR)" caffeinate -dimsu xcodebuild -project CodexCoveUITests.xcodeproj \
		-scheme CodexCoveUITests \
		-destination 'platform=macOS' \
		-derivedDataPath DerivedData \
		test

run:
	swift run CodexCove

icon:
	./scripts/build-icon.sh

sounds:
	node ./scripts/generate-sounds.mjs

themes:
	node ./scripts/generate-themes.mjs

remote-artifacts:
	./scripts/build-remote-artifacts.sh

signing-identity:
	./scripts/create-signing-identity.sh

package: sounds themes
	./scripts/package-app.sh

package-with-remote: sounds themes remote-artifacts
	CODEX_COVE_INCLUDE_REMOTE=1 ./scripts/package-app.sh

install: sounds themes
	./scripts/install.sh

install-with-remote: sounds themes remote-artifacts
	CODEX_COVE_INCLUDE_REMOTE=1 ./scripts/install.sh

doctor:
	@if [ -x "$(HOME)/bin/codex-cove" ]; then "$(HOME)/bin/codex-cove" doctor; else cargo run --manifest-path helper/Cargo.toml -- doctor; fi

candidate-write:
	./scripts/source-candidate.sh write

candidate-verify:
	./scripts/source-candidate.sh verify

verify-release-version:
	@./scripts/verify-release-version.sh "$${VERSION:?Set VERSION to a release version or v-tag}"

verify-release-readiness:
	@./scripts/verify-release-readiness.sh "$${VERSION:?Set VERSION to a release version or v-tag}"

release-assets:
	@./scripts/prepare-release-assets.sh "$${VERSION:?Set VERSION to a release version or v-tag}"

clean:
	swift package clean
	cargo clean --manifest-path helper/Cargo.toml
	@if [ -f extension/package.json ]; then npm --prefix extension run clean; fi
	rm -rf "build/Codex Cove.app"
