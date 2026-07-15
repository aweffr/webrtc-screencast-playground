SHELL := /bin/zsh

.PHONY: bootstrap generate test-go test-macos test-android test-scripts build-macos build-android verify media-baseline android-tv-baseline

bootstrap:
	./scripts/bootstrap-webrtc.sh

generate: bootstrap
	cd apps/macos && xcodegen generate

test-go:
	cd server && go test -race ./...

test-macos: generate
	xcodebuild test -project apps/macos/WebRTCScreencast.xcodeproj -scheme WebRTCScreencast -destination 'platform=macOS' -derivedDataPath DerivedData

test-android: bootstrap
	./apps/android-tv/gradlew -p apps/android-tv test lint

test-scripts:
	./scripts/test-verifiers.sh
	python3 -m unittest scripts/test_virtual_display_state.py
	python3 -m unittest scripts/test_media_baseline_analyzer.py
	python3 -m unittest scripts/test_media_baseline_aggregate.py
	python3 -m unittest scripts/test_android_tv_baseline_analyzer.py
	python3 -m unittest scripts/test_android_tv_baseline_aggregate.py

build-macos: generate
	xcodebuild build -project apps/macos/WebRTCScreencast.xcodeproj -scheme WebRTCScreencast -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath DerivedData

build-android: bootstrap
	./apps/android-tv/gradlew -p apps/android-tv assembleDirectBaselineDebug assembleProductionRelayDebug

verify: test-go test-macos test-android test-scripts build-macos build-android
	git diff --check

media-baseline:
	./scripts/run-media-baseline.sh --runtime-config "$${RUNTIME_CONFIG}"

android-tv-baseline:
	./scripts/run-android-tv-baseline.sh --runtime-config "$${RUNTIME_CONFIG}"
