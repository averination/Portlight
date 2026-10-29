# Validation

## Reproduce

```sh
./scripts/build-app.sh
./scripts/check.sh
./scripts/check.sh --live
```

Use macOS with Swift 6.0+ and Command Line Tools or Xcode. The live suite creates disposable loopback servers and private temporary Git repositories. It only sends SIGTERM to selected fixture identities. It needs Python 3; provide Node.js on PATH for launcher/Node cases. `PORTLIGHT_EXPECT_CODEX=1` additionally asserts a signed Codex ancestor and should only be set when running from the official Codex app/CLI. Do not set it on CI.

## 1.5.0 local result

Built for arm64 on macOS 15.7.4 with Swift 6.1. Full checks: **35 passed, 0 skipped, 0 failures; 555 assertions**.

Covered:

- Exact runtime whitelist, TCP LISTEN requirement, address families, duplicate ports, protected/foreign/background process exclusion.
- Signed Codex ancestry, stale parent chains, project grouping persistence, manual override precedence, legacy archives and separation of group from source verification.
- Selective and batch SIGTERM, start-time/PID reuse checks, changed group rejection after review, parent/child separation, ignored SIGTERM without force kill.
- Project launch, duplicate prevention across app restarts, bookmarks, archive integrity, successful stop vs real launch/runtime failures.
- Real Git commits and local bare-repository pushes: literal paths, selected whole files, unrelated staging, stale reviews, divergence, branch/tag scope and configuration persistence.
- Parsing exact production-deployment status for the pushed SHA. No live production deployment is performed by these tests.
- Notch geometry, hit regions, concave shoulders and anchored outline interpolation.

Native installed-app checks include normal panel/empty state, archive project grouping and removal of recording controls. Physical animation and pointer behavior still need feedback across Mac models, macOS versions, external displays and fullscreen Spaces. macOS 13/14 are deployment targets, not locally tested hardware configurations.

## CI

The included GitHub workflow builds and runs disposable live checks on a macOS 15 runner with a standalone Python 3.13. Xcode-embedded Python is intentionally excluded by discovery; fixtures use `PORTLIGHT_TEST_PYTHON` or the Python selected from PATH by the check script. A local passing run is not a claim that the remote workflow has already passed. Runner details: [GitHub-hosted runners](https://docs.github.com/en/actions/reference/runners/github-hosted-runners).
