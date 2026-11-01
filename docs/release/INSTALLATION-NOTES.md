# Compiled release artifacts

Each published artifact must identify its version/build, signing method and checksum. The iPhone package includes the matching Apple Watch app and Watch widget; the Watch component can also be packaged separately for developers who need it.

An App Store distribution IPA is intended for Apple's distribution process. It is **not directly installable on an arbitrary iPhone or Watch** by downloading it from GitHub. A development or ad hoc package works only with the appropriate signing and device registration. Do not publish development profiles or their registered-device lists without an explicit review of that exposure.

For ordinary installation, use the App Store version when available. For a self-built development installation, configure your own signing team, generate the project from project.yml, and use scripts/device-install.sh with the physical iPhone identifier. Keep app, Watch and widget versions aligned. Follow AGENTS.md for all simulator work.

GitHub publication does not establish App Store approval or availability. The release's publication record should state the actual GitHub and App Store Connect states separately.
