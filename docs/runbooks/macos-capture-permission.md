# macOS Screen Recording permission smoke

The app uses ScreenCaptureKit and therefore requires the macOS Screen & System
Audio Recording permission. The project does not request Input Monitoring or
Accessibility permission.

Build and run the metadata permission probe:

```bash
xcrun swiftc \
  -parse-as-library \
  -framework Foundation \
  -framework ScreenCaptureKit \
  apps/macos/CapturePermissionSmoke/main.swift \
  -o /tmp/webrtc-capture-permission-smoke
/tmp/webrtc-capture-permission-smoke
```

On first use, macOS may show the Screen Recording prompt. If access is denied,
open **System Settings → Privacy & Security → Screen & System Audio Recording**,
enable the launched binary's host, and restart it. A successful probe prints a
non-zero display count. This probe establishes permission/shareable-content
discovery only; the end-to-end runbook must observe a real `SCStream` frame
callback before capture is considered verified.
