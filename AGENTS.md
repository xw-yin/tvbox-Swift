# Project delivery conventions

- Every delivered IPA must use a marketing version plus a monotonically increasing build number, e.g. `1.0.3 (Build 2)`.
- Before a new delivery, increment `CURRENT_PROJECT_VERSION` in both `project.yml` and `tvbox.xcodeproj/project.pbxproj`. Keep both files consistent. Retries of the same delivery use the same build.
- Use `scripts/package-unsigned.sh`. Output naming: `TVBox-<version>-build.<build>-unsigned.ipa`.
- Show the actual version and build from Bundle metadata in the app; do not hardcode version labels.
