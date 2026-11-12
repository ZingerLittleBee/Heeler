# Task runner for Heeler. Typical flows:
#   make install                 # build Debug and run it on the connected iPhone
#   make install-ipad            # same, on the connected iPad
#   make testflight VERSION=0.2.0 # first candidate of the intended version
#   make testflight               # another build, same marketing version
#   make plugin                  # publish plugin/ to the plugin branch

PROJECT := Heeler.xcodeproj
SCHEME  := Heeler
ARCHIVE := build/Heeler.xcarchive
DERIVED_DEVICE ?= build/DerivedData-device
DERIVED_SIMULATOR ?= build/DerivedData-simulator
DERIVED ?= $(DERIVED_DEVICE)
APP_ID  := dev.bybee.heeler
SIM     ?= iPhone 17
SIM_IPAD ?= iPad Pro 13-inch (M5)
SIM_DESTINATION ?= platform=iOS Simulator,name=$(SIM)
SIMULATOR_UDID ?=
CI_APP_SHARD ?= all
TEST_FLAGS ?=
TEST_SELECTOR ?=
export TEST_FLAGS TEST_SELECTOR
export VERSION BUILD TAG DRY_RUN YES
export ADHOC_DIR ADHOC_URL ADHOC_UDID ADHOC_IPA ADHOC_PUBLISH_URL
BUILD_FLAGS ?=
IOS_WATCH_DEBOUNCE ?= 1s

# First physical iPhone / iPad paired with devicectl; override with
# `make install DEVICE=<udid>` or `make install-ipad DEVICE_IPAD=<udid>`.
DEVICE ?= $(shell python3 scripts/find-ios-device.py iPhone)
DEVICE_IPAD ?= $(shell python3 scripts/find-ios-device.py iPad)

.PHONY: help generate resolve build test test-app test-ipad test-ci-app test-ci-package test-ci-evidence test-ci-background-build test-tools test-ci-guards test-ci-watchdog test-ci-recovery verify-core-linux-host check-agent-docs check-test-membership simulator-ui build-device install install-ipad watch-ios-device sim sim-ipad build-sim sim-id archive upload testflight testflight-retry release-status release-check bump publish plugin clean check-device check-device-ipad ssh-artifacts verify-ssh-artifacts testflight-notes testflight-beta

# Command-line DERIVED overrides remain supported for either platform.
test-app test-directory-browser-ui sim build-sim sim-id: DERIVED = $(DERIVED_SIMULATOR)

help: ## Show available targets
	@awk -F':.*## ' '/^[a-z-]+:.*## / { printf "  make %-20s %s\n", $$1, $$2 }' $(MAKEFILE_LIST)

ssh-artifacts: ## Rebuild the pinned HeelerSSH XCFrameworks
	Packages/HeelerSSH/Scripts/build-native.sh

verify-ssh-artifacts: ## Verify HeelerSSH artifact hashes, slices, and policy
	Packages/HeelerSSH/Scripts/verify-native.sh

generate: ## Regenerate the Xcode project from project.yml (XcodeGen)
	xcodegen generate

resolve: generate ## Resolve pinned Swift packages into .ci/source-packages
	xcodebuild -resolvePackageDependencies -project $(PROJECT) -scheme $(SCHEME) \
		-clonedSourcePackagesDirPath .ci/source-packages

build: generate ## Build Debug for a physical device without installing
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration Debug \
		-destination 'generic/platform=iOS' -derivedDataPath $(DERIVED) \
		-allowProvisioningUpdates build

.PHONY: build-ci-app
build-ci-app: ## Compile the committed app, extensions and test bundle without running tests or booting a Simulator
	xcodebuild build-for-testing -project $(PROJECT) -scheme $(SCHEME) -configuration Debug \
		-destination 'generic/platform=iOS Simulator' ARCHS="$$(uname -m)" \
		-derivedDataPath '$(CURDIR)/.ci/app-derived' \
		-clonedSourcePackagesDirPath '$(CURDIR)/.ci/source-packages' \
		COMPILATION_CACHE_ENABLE_CACHING=YES \
		'COMPILATION_CACHE_CAS_PATH=$(CURDIR)/.ci/app-compilation-cache' \
		COMPILATION_CACHE_ENABLE_DIAGNOSTIC_REMARKS=YES \
		GCC_GENERATE_DEBUGGING_SYMBOLS=NO COMPILER_INDEX_STORE_ENABLE=NO

.PHONY: build-ci-package
build-ci-package: ## Compile HeelerSSH and its tests without running tests or booting a Simulator
	cd Packages/HeelerSSH && xcodebuild build-for-testing -scheme HeelerSSH \
		-destination 'generic/platform=iOS Simulator' ARCHS="$$(uname -m)" \
		-derivedDataPath '$(CURDIR)/.ci/package-derived' \
		COMPILATION_CACHE_ENABLE_CACHING=NO \
		GCC_GENERATE_DEBUGGING_SYMBOLS=NO COMPILER_INDEX_STORE_ENABLE=NO

test-app: generate ## Run app tests and verify execution (SIM_DESTINATION, TEST_SELECTOR, TEST_FLAGS)
	python3 scripts/run-app-simulator-tests.py -project $(PROJECT) -scheme $(SCHEME) \
		-destination '$(SIM_DESTINATION)' -derivedDataPath $(DERIVED) \
		test

test: test-app ## Run the app and HeelerSSH unit test suites on a simulator
	scripts/run-heelerssh-package-tests.sh '$(SIM_DESTINATION)'

# Requires a fresh New Agent form on the installed candidate.
.PHONY: test-directory-browser-ui
test-directory-browser-ui: ## Check first Browse presentation (SIMULATOR_UDID, requires idb)
	@test -n "$(SIMULATOR_UDID)" || { echo "SIMULATOR_UDID is required"; exit 1; }
	python3 scripts/test-remote-directory-browser.py --udid '$(SIMULATOR_UDID)' \
		--output-dir '$(DERIVED)/DirectoryBrowserUI'

test-ipad: ## Run the app and HeelerSSH unit test suites on the iPad simulator
	$(MAKE) test SIM='$(SIM_IPAD)'

test-ci-app: ## Run the committed-project CI app lane (CI_APP_SHARD, no generate)
	HEELER_CI_LANE=app HEELER_CI_APP_SHARD='$(CI_APP_SHARD)' \
		HEELER_CI_SIMULATOR_UDID='$(or $(SIMULATOR_UDID),$(HEELER_CI_SIMULATOR_UDID))' \
		scripts/run-ci-ios-tests.sh

test-ci-package: ## Run the committed-project CI SSH package lane (SIMULATOR_UDID)
	HEELER_CI_LANE=package HEELER_CI_SIMULATOR_UDID='$(or $(SIMULATOR_UDID),$(HEELER_CI_SIMULATOR_UDID))' \
		scripts/run-ci-ios-tests.sh

.PHONY: test-ci-diagnostics test-ci-diagnostic-controls test-weak-network-proxy
test-ci-diagnostics: ## Diagnose one scenario (HEELER_CI_DIAGNOSTIC_TARGET, optional iterations)
	@test -n "$$HEELER_CI_DIAGNOSTIC_TARGET" || { echo "HEELER_CI_DIAGNOSTIC_TARGET is required" >&2; exit 2; }
	HEELER_CI_LANE=app scripts/run-ci-ios-tests.sh

test-weak-network-proxy: ## Test real TCP impairment, buffering, and proxy cleanup
	python3 scripts/test-weak-network-proxy.py

test-ci-diagnostic-controls: ## Verify diagnostic isolation and execution guards without Xcode
	bash scripts/test-ci-ios-diagnostics.sh

check-agent-docs: ## Check navigation links and unique ADR numbers
	python3 scripts/check-agent-docs.py

check-test-membership: ## Check that the committed project compiles every app test source
	python3 scripts/check-test-target-membership.py

test-tools: check-agent-docs check-test-membership ## Test agent tooling without Xcode or a simulator
	$(MAKE) test-adhoc
	python3 scripts/test-format-release-notes.py
	python3 scripts/test-testflight.py
	python3 scripts/test-native-test-lifecycle.py
	python3 scripts/test-check-agent-docs.py
	python3 scripts/test-check-test-target-membership.py
	python3 scripts/check-localizations.py
	python3 scripts/test-check-localizations.py
	python3 scripts/test-run-app-simulator-tests.py
	python3 scripts/test-simulator-ui.py
	python3 scripts/test-isolated-herdr-backend.py
	python3 scripts/test-herdr-core-capture.py
	python3 scripts/test-herdr-core-locator.py
	python3 scripts/test-herdr-core-shell-launch.py
	python3 scripts/test-herdr-app-control.py
	python3 scripts/test-herdr-core-start.py
	python3 scripts/test-server-kind-detection.py
	python3 scripts/test-herdr-core-lab-check.py
	python3 scripts/test-store-shots.py
	python3 scripts/test-node-toolchain-probe.py
	python3 scripts/test-host-process-reader.py
	python3 scripts/test-herdr-core-environment-check.py
	python3 scripts/test-host-helper-manifest.py
	python3 scripts/test-host-helper-scripts.py
	sh scripts/test-source-revision.sh
	bash scripts/test-publish-plugin.sh
	$(MAKE) test-ci-evidence
	$(MAKE) test-weak-network-proxy
	$(MAKE) test-ci-diagnostic-controls

test-ci-evidence: ## Test shard evidence, parameter cases, and skip provenance
	python3 scripts/test-verify-ci-ios-evidence.py

test-ci-guards: ## Test CI gate assertions without building the app (macOS)
	scripts/test-run-ci-ios-tests-guards.sh

test-ci-background-build: ## Test owned background build failure and cancellation
	python3 scripts/test-run-ci-background-build.py

test-ci-watchdog: test-ci-background-build ## Test the CI watchdog and simulator recovery (macOS)
	scripts/test-run-with-timeout.sh

test-ci-recovery: ## Test simulator recovery with fake Xcode processes (macOS)
	scripts/test-ci-simulator-recovery.sh

# An owner's check on a real box: see docs/guides/herdr-core-testing.md.
verify-core-linux-host: ## Run the herdr-core end-to-end methods on hc-lab (SIMULATOR_UDID=<udid> [LAB=hc-lab] [LAB_PORT=47430])
	@test -n "$(SIMULATOR_UDID)" || { echo "SIMULATOR_UDID is required"; exit 1; }
	python3 scripts/lab/herdr-core-lab-check.py --box '$(or $(LAB),hc-lab)' --port '$(or $(LAB_PORT),47430)' --udid '$(SIMULATOR_UDID)'

simulator-ui: ## Inspect simulator GUI capabilities (optional SIMULATOR_UDID)
	python3 scripts/simulator-ui.py $(if $(SIMULATOR_UDID),--udid '$(SIMULATOR_UDID)')

.PHONY: test-device-discovery
test-device-discovery: ## Test physical-device selection and explicit overrides
	python3 scripts/test-find-ios-device.py

check-device:
	@test -n "$(DEVICE)" || { echo "No physical iPhone found; pass DEVICE=<device identifier>"; exit 1; }

# Builds against the concrete device so automatic signing can register it
# in the development profile; the generic `build` target cannot.
build-device: check-device generate
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration Debug \
		-destination 'platform=iOS,id=$(DEVICE)' -derivedDataPath $(DERIVED) \
		-allowProvisioningUpdates -allowProvisioningDeviceRegistration build

install: build-device ## Build Debug, install on the iPhone, and relaunch it
	xcrun devicectl device install app --device $(DEVICE) \
		$(DERIVED)/Build/Products/Debug-iphoneos/Heeler.app
	xcrun devicectl device process launch --terminate-existing --device $(DEVICE) $(APP_ID) \
		|| echo "Installed, but the launch was refused (device locked?). Unlock it and open Heeler."

check-device-ipad:
	@test -n "$(DEVICE_IPAD)" || { echo "No physical iPad found; pass DEVICE_IPAD=<device identifier>"; exit 1; }

install-ipad: check-device-ipad ## Build Debug, install on the iPad, and relaunch it
	$(MAKE) install DEVICE="$(DEVICE_IPAD)"

watch-ios-device: ## Watch iOS code and install to a connected iPhone/iPad
	@command -v watchexec >/dev/null || { echo "watchexec not found. Install with: brew install watchexec"; exit 1; }
	watchexec \
		--watch Sources \
		--watch Packages/HeelerSSH/Sources \
		--watch Packages/HeelerSSH/NativeSupport \
		--watch Packages/HeelerSSH/Package.swift \
		--watch project.yml \
		--exts swift,h,modulemap,yml,plist,xcprivacy,entitlements,resolved,json,png,ttf \
		--debounce "$(IOS_WATCH_DEBOUNCE)" \
		--on-busy-update queue \
		-- make install DEVICE="$(DEVICE)"

sim: generate ## Build Debug and run it on the simulator (override with SIM=<name>)
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration Debug \
		-destination 'platform=iOS Simulator,name=$(SIM)' -derivedDataPath $(DERIVED) build
	xcrun simctl boot '$(SIM)' 2>/dev/null || true
	open -a Simulator
	xcrun simctl install booted $(DERIVED)/Build/Products/Debug-iphonesimulator/Heeler.app
	xcrun simctl launch --terminate-running-process booted $(APP_ID)

sim-ipad: ## Build Debug and run it on the iPad simulator (override with SIM_IPAD=<name>)
	$(MAKE) sim SIM='$(SIM_IPAD)'

build-sim: generate ## Build Debug for SIM_DESTINATION using .ci/source-packages
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration Debug \
		-destination '$(SIM_DESTINATION)' -derivedDataPath $(DERIVED) \
		-clonedSourcePackagesDirPath .ci/source-packages $(BUILD_FLAGS) build

sim-id: build-sim ## Install and launch the app on SIMULATOR_UDID only
	@test -n "$(SIMULATOR_UDID)" || { echo "SIMULATOR_UDID is required; pass SIMULATOR_UDID=<uuid>"; exit 1; }
	@case '$(SIM_DESTINATION)' in \
	  *booted*) echo "sim-id refuses a generic booted destination"; exit 1 ;; \
	  *id=$(SIMULATOR_UDID)*) ;; \
	  *) echo "SIM_DESTINATION must include id=$(SIMULATOR_UDID) (got '$(SIM_DESTINATION)')"; exit 1 ;; \
	esac
	xcrun simctl boot '$(SIMULATOR_UDID)' 2>/dev/null || true
	xcrun simctl bootstatus '$(SIMULATOR_UDID)' -b
	xcrun simctl install '$(SIMULATOR_UDID)' $(DERIVED)/Build/Products/Debug-iphonesimulator/Heeler.app
	xcrun simctl launch --terminate-running-process '$(SIMULATOR_UDID)' $(APP_ID)

archive: generate ## Archive locally for inspection (no distribution upload)
	@# HEELER_SOURCE_REVISION names the commit in About › Acknowledgements;
	@# empty unless HEAD is pushed and only the build number is uncommitted.
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration Release \
		-destination 'generic/platform=iOS' -archivePath $(ARCHIVE) \
		-allowProvisioningUpdates HEELER_SOURCE_REVISION=$$(scripts/source-revision.sh) archive

# Options are make variables, not flags: make eats `--dry-run` as its own -n and
# rejects unknown long options, so a flag would never reach the recipe.
.PHONY: adhoc adhoc-page adhoc-publish test-adhoc
adhoc: ## Export a local Ad Hoc IPA and page (ADHOC_URL, ADHOC_UDID)
	@python3 scripts/adhoc.py build

adhoc-page: ## Prepare an existing IPA's installation page (ADHOC_DIR, ADHOC_URL)
	@python3 scripts/adhoc.py page

adhoc-publish: ## Verify and publish an IPA to Cloudflare (ADHOC_IPA, ADHOC_PUBLISH_URL)
	@python3 -u scripts/adhoc-publish.py

test-adhoc: ## Verify Ad Hoc packaging, publishing and download service
	python3 scripts/test-adhoc.py
	python3 scripts/test-adhoc-publish.py
	node --test adhoc-host/test/*.test.mjs

testflight: ## Cut and push a build tag; CI uploads (VERSION=X.Y.Z DRY_RUN=1 YES=1)
	@python3 scripts/testflight.py cut

testflight-retry: ## Resume the original candidate run safely (TAG=builds/X.Y.Z/N)
	@python3 scripts/testflight.py retry

release-status: ## Read recorded candidate state, not live store status (TAG=builds/X.Y.Z/N)
	@python3 scripts/testflight.py status

release-check: ## Dispatch signing/validation rehearsal, no upload (VERSION=X.Y.Z)
	@python3 scripts/testflight.py check

testflight-notes: ## List changelog entries external testers have not had (TAG=builds/X.Y.Z/N [SINCE=commit])
	@python3 scripts/testflight.py notes

testflight-beta: ## Set What to Test, add to external testing, submit for review (TAG=... NOTES=notes.txt)
	@python3 scripts/testflight.py beta

publish upload bump:
	@echo "$@ is retired. Use make testflight VERSION=X.Y.Z (then make testflight for another build)." >&2
	@echo "App Store publication selects an existing TestFlight build in App Store Connect. See docs/guides/releasing.md." >&2
	@exit 1

# Phony as well: plugin/ is a directory, so make would call the target up to date.
plugin: ## Publish plugin/ from origin/main to the plugin branch (SOURCE=<rev> DRY_RUN=1 YES=1)
	@SOURCE='$(SOURCE)' DRY_RUN='$(DRY_RUN)' YES='$(YES)' scripts/publish-plugin.sh

clean: ## Remove local build products
	rm -rf build
