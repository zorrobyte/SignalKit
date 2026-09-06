# Security

## Report privately

Do not put health records, location history, credentials, or exploit-ready details in public issues. Use GitHub's private vulnerability reporting for this repository when enabled. If private reporting is unavailable, open a content-free request for a private contact channel; do not attach the sensitive report publicly.

Include the affected version, OS/SDK version, a minimal synthetic reproduction, and the expected versus observed behavior. A storage/replay issue can be security-relevant if it crosses account boundaries or exposes private records.

## Security boundaries

- The host owns consent, entitlement configuration, account separation, server authentication/authorization, retention, and transport security.
- The package writes local protected files, but file protection is not an app-managed encryption scheme and does not replace device security or backend controls.
- Use separate storage directories/defaults suites per account. Never switch the upload identity while an old account's queue is active.
- Upload closures are trusted host code. The package cannot validate who receives data or undo an acknowledged server write.
- Logs default to no-op. An injected sink may contain sensitive context; the host must control redaction, retention, and transmission.
- Only the current public release is actively maintained. Security fixes may require upgrading; there is no supported legacy branch policy yet.

Do not use these libraries as a substitute for a safety-critical monitoring or emergency system. iOS can suspend or terminate collection and can withhold data.
