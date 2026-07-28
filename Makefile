# Task runner for HerdrMobile. Typical flows:
#   make install                 # build Debug and run it on the connected iPhone
#   make bump && make testflight # next TestFlight build (build number must be unique per upload)

PROJECT := HerdrMobile.xcodeproj
SCHEME  := HerdrMobile
ARCHIVE := build/HerdrMobile.xcarchive
DERIVED := build/DerivedData
APP_ID  := dev.herdr.mobile.HerdrMobile

# First physical device paired with devicectl; override with `make install DEVICE=<uuid>`.
DEVICE ?= $(shell xcrun devicectl list devices 2>/dev/null | awk '/physical[a-z]* *$$/ { for (i = 1; i <= NF; i++) if ($$i ~ /^[0-9A-Fa-f-]{36}$$/) { print $$i; exit } }')

.PHONY: help generate build test install archive upload testflight bump clean check-device

help: ## Show available targets
	@awk -F':.*## ' '/^[a-z]+:.*## / { printf "  make %-12s %s\n", $$1, $$2 }' $(MAKEFILE_LIST)

generate: ## Regenerate the Xcode project from project.yml (XcodeGen)
	xcodegen generate

build: generate ## Build Debug for a physical device without installing
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration Debug \
		-destination 'generic/platform=iOS' -derivedDataPath $(DERIVED) \
		-allowProvisioningUpdates build

test: generate ## Run the unit test suite on a simulator
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) \
		-destination 'platform=iOS Simulator,name=iPhone 17' test

check-device:
	@test -n "$(DEVICE)" || { echo "No physical device found; pass DEVICE=<devicectl uuid>"; exit 1; }

install: check-device build ## Build Debug, install on the iPhone, and relaunch it
	xcrun devicectl device install app --device $(DEVICE) \
		$(DERIVED)/Build/Products/Debug-iphoneos/HerdrMobile.app
	xcrun devicectl device process launch --terminate-existing --device $(DEVICE) $(APP_ID)

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
	sed -i '' "s/CURRENT_PROJECT_VERSION: \"$$CUR\"/CURRENT_PROJECT_VERSION: \"$$NEW\"/g" project.yml; \
	echo "CURRENT_PROJECT_VERSION: $$CUR -> $$NEW"
	@# Regenerate immediately so the tracked pbxproj changes with project.yml
	@# and one commit carries both (otherwise the next make target regenerates
	@# it after the bump commit and leaves it dirty).
	@$(MAKE) generate

clean: ## Remove local build products
	rm -rf build
