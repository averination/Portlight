# Contributing

Use Swift 6.0+ on macOS. Build with `./scripts/build-app.sh`; run `./scripts/check.sh`, and `./scripts/check.sh --live` when changing discovery, launch or stop behavior.

Keep process safety checks in PortlightCore/ProcessBridge. Do not add force kill, process-group termination, global runtime shutdown, implicit pushes or automatic deployment retries. Project grouping must never turn an unverified process source into a verified one.

Use disposable project folders and servers for testing. Do not commit local archives, logs, credentials, generated build directories or screenshots containing personal data. Do not paste raw diagnostic output in public issues.

Small bug reports and focused pull requests are welcome. Explain observable behavior, relevant validation and remaining limitations. Physical notch behavior should be tested on a real notched MacBook; geometry tests alone cannot verify pointer handling or animation quality.
