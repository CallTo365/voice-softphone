SIM ?= iPhone 15
PROJECT = Softphone.xcodeproj
SCHEME = Softphone
DEST = platform=iOS Simulator,name=$(SIM)

.PHONY: bootstrap build test clean device

bootstrap:            ## generate the Xcode project from project.yml (resolves SPM on first build)
	xcodegen generate

build: bootstrap      ## compile the app for the simulator (no signing needed)
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -destination 'generic/platform=iOS Simulator' \
	  -configuration Debug CODE_SIGNING_ALLOWED=NO build | tail -n 40

test: bootstrap       ## unit tests (SoftphoneTests) on a simulator
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -destination '$(DEST)' \
	  -configuration Debug test | tail -n 60

device: bootstrap     ## build for a connected iPhone (needs configs/Signing.local.xcconfig with your Team ID)
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -destination 'generic/platform=iOS' \
	  -configuration Debug -allowProvisioningUpdates build | tail -n 40

clean:
	rm -rf $(PROJECT) DerivedData build
