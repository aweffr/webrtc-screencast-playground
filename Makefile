SHELL := /bin/zsh

.PHONY: bootstrap generate test-go test-macos build-macos verify

bootstrap:
	./scripts/bootstrap-webrtc.sh

generate: bootstrap
	cd apps/macos && xcodegen generate

test-go:
	cd server && go test -race ./...

test-macos: generate
	xcodebuild test -project apps/macos/WebRTCScreencast.xcodeproj -scheme WebRTCScreencast -destination 'platform=macOS' -derivedDataPath DerivedData

build-macos: generate
	xcodebuild build -project apps/macos/WebRTCScreencast.xcodeproj -scheme WebRTCScreencast -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath DerivedData

verify: test-go test-macos build-macos
	git diff --check
