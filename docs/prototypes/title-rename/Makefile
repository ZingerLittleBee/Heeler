# Run from the repository root. This target only launches isolated demo data.
DERIVED ?= build/DerivedData-title-prototype

.PHONY: preview
preview:
	@test -n "$(SIMULATOR_UDID)" || { echo "SIMULATOR_UDID is required"; exit 1; }
	$(MAKE) -o generate build-sim \
		SIM_DESTINATION='platform=iOS Simulator,id=$(SIMULATOR_UDID)' DERIVED='$(DERIVED)'
	xcrun simctl boot '$(SIMULATOR_UDID)' 2>/dev/null || true
	xcrun simctl bootstatus '$(SIMULATOR_UDID)' -b
	xcrun simctl install '$(SIMULATOR_UDID)' '$(DERIVED)/Build/Products/Debug-iphonesimulator/Heeler.app'
	xcrun simctl launch --terminate-running-process '$(SIMULATOR_UDID)' dev.bybee.heeler \
		--demo-screenshots --demo-chat --demo-title-prototype --demo-title-list
