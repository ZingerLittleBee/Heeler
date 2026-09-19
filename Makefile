# Task runner for Heeler. Typical flows:
#   make install                 # build Debug and run it on the connected iPhone
#   make install-ipad            # same, on the connected iPad
#   make bump && make testflight # interim TestFlight build, no version cut
#   make publish                 # cut a release: see docs/guides/releasing.md

PROJECT := Heeler.xcodeproj
SCHEME  := Heeler
ARCHIVE := build/Heeler.xcarchive
DERIVED := build/DerivedData
APP_ID  := dev.bybee.heeler
SIM     ?= iPhone 17
SIM_IPAD ?= iPad Pro 13-inch (M5)
SIM_DESTINATION ?= platform=iOS Simulator,name=$(SIM)
SIMULATOR_UDID ?=
TEST_FLAGS ?=
BUILD_FLAGS ?=
IOS_WATCH_DEBOUNCE ?= 1s

# First physical iPhone / iPad paired with devicectl; override with
# `make install DEVICE=<uuid>` or `make install-ipad DEVICE_IPAD=<uuid>`.
DEVICE ?= $(shell xcrun devicectl list devices 2>/dev/null | awk '/iPhone.*physical[a-z]* *$$/ { for (i = 1; i <= NF; i++) if ($$i ~ /^[0-9A-Fa-f-]{36}$$/) { print $$i; exit } }')
DEVICE_IPAD ?= $(shell xcrun devicectl list devices 2>/dev/null | awk '/iPad.*physical[a-z]* *$$/ { for (i = 1; i <= NF; i++) if ($$i ~ /^[0-9A-Fa-f-]{36}$$/) { print $$i; exit } }')

.PHONY: help generate resolve build test test-app test-ipad test-ci-app build-device install install-ipad watch-ios-device sim sim-ipad build-sim sim-id archive upload testflight bump publish clean check-device check-device-ipad ssh-artifacts verify-ssh-artifacts

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

test-app: generate ## Run the app test suite (SIM_DESTINATION, TEST_FLAGS)
	python3 scripts/run-app-simulator-tests.py -project $(PROJECT) -scheme $(SCHEME) \
		-destination '$(SIM_DESTINATION)' -derivedDataPath $(DERIVED) \
		$(TEST_FLAGS) test

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

test-ci-app: ## Run the committed-project CI app lane (no generate)
	HEELER_CI_LANE=app HEELER_CI_SIMULATOR_UDID='$(or $(SIMULATOR_UDID),$(HEELER_CI_SIMULATOR_UDID))' \
		scripts/run-ci-ios-tests.sh

check-device:
	@test -n "$(DEVICE)" || { echo "No physical device found; pass DEVICE=<devicectl uuid>"; exit 1; }

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
	@test -n "$(DEVICE_IPAD)" || { echo "No physical iPad found; pass DEVICE_IPAD=<devicectl uuid>"; exit 1; }

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

archive: generate ## Archive a Release build for distribution
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration Release \
		-destination 'generic/platform=iOS' -archivePath $(ARCHIVE) \
		-allowProvisioningUpdates archive

upload: ## Upload the existing archive to App Store Connect (TestFlight)
	xcodebuild -exportArchive -archivePath $(ARCHIVE) \
		-exportOptionsPlist scripts/ExportOptions.plist \
		-exportPath build/export -allowProvisioningUpdates

testflight: archive upload ## Archive and upload in one go

bump: ## Increment CURRENT_PROJECT_VERSION in project.yml (app + extension stay in lockstep)
	@CUR=$$(awk -F'"' '/CURRENT_PROJECT_VERSION/ { print $$2; exit }' project.yml); \
	NEW=$$((CUR + 1)); \
	sed -i '' -E "s/CURRENT_PROJECT_VERSION: \"[0-9]+\"/CURRENT_PROJECT_VERSION: \"$$NEW\"/g" project.yml; \
	echo "CURRENT_PROJECT_VERSION: $$CUR -> $$NEW"
	@# Regenerate immediately so the tracked pbxproj changes with project.yml
	@# and one commit carries both (otherwise the next make target regenerates
	@# it after the bump commit and leaves it dirty).
	@$(MAKE) generate

# Options are make variables, not flags: make eats `--dry-run` as its own -n and
# rejects unknown long options, so a flag would never reach the recipe.
publish: ## Cut a release from CHANGELOG [Unreleased] (VERSION=x.y.z DRY_RUN=1 YES=1)
	@VERSION='$(VERSION)' DRY_RUN='$(DRY_RUN)' YES='$(YES)' scripts/publish.sh

clean: ## Remove local build products
	rm -rf build
