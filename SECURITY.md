# Security Policy

## Reporting a vulnerability

Please use the repository's private GitHub security-advisory flow instead of opening a public issue.
Include affected versions, reproduction steps, impact, and any suggested mitigation. Do not attach
live TURN credentials, pairing codes, SDP, ICE candidates, or screen captures containing private
content.

## Reference-implementation boundary

The sample uses fixed machine-local TURN credentials for controlled devices and does not implement
user identity, authorization, credential rotation, or time-limited TURN REST credentials. Deployers
must add those controls before exposing a derived product to untrusted users. Direct UDP is a local
comparison profile, not a production fallback.
