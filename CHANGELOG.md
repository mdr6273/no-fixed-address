# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project uses
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Changed

- The Unraid template and the Community Applications profile are now published from Richardson Resources' shared repository, [unraid-apps](https://github.com/mdr6273/unraid-apps). The copy under `unraid/` in this repository stays as a mirror for older links and for containers installed from them, and installs the same container.

## [1.1.0] - 2026-11-08

Several zones, notifications, and images for 32-bit ARM. Every setting from 1.0.0 works as before, so updating needs no changes.

### Added

- Notifications. Set `NOTIFY_URL` (or `NOTIFY_URL_FILE`) to a webhook, and `NOTIFY_FORMAT` to `discord`, `slack`, `ntfy`, `gotify`, `apprise`, `json` or `text` (`auto` recognises Discord and Slack), and the container sends a message when records change, when something needs attention, and when it works again. Trouble that may pass is only reported once it has lasted as long as the health check allows, two hours, and a failed notification never holds up an update. The URL is treated as a secret, like the token. Off unless set.
- Images for linux/arm/v7 and linux/arm/v6, for 32-bit Raspberry Pi OS and the Raspberry Pi Zero and 1. CI now runs every test against the image for each architecture, under emulation for the ARM ones, before anything is released.
- Records in several zones. `ZONE` is now optional: without it, the container asks Cloudflare which zones the token can see and works out the zone of each name in `RECORDS` itself, so one container can keep names in several domains up to date. When two zones match, as with an Enterprise subdomain zone such as `sub.example.com`, the longer one wins. Setups with `ZONE` set work exactly as before, and the log mentions that it is now optional. `@` in `RECORDS` still needs `ZONE`, since without it there is no zone for it to stand for. A name in no zone the token can see stops the container at startup with `no zone was found for ...`, as an unknown `ZONE` always has.

### Changed

- The Unraid template, the `docker run` and Compose examples now check every 5 minutes (`INTERVAL=300`) instead of once a day, like other dynamic DNS updaters. The image's own default is unchanged, so an existing container keeps its interval; to switch, set `INTERVAL` to `300`.
- The Unraid template, the README's examples and `docker-compose.example.yml` no longer set `ZONE`, and the template has the notification settings under **Show more settings**. A container installed from an older template keeps its **Zone** field: leaving it or clearing it both work.
- The `zone example.com: keeping A records for ...` line is now logged after the token is verified, once per zone.

## [1.0.0] - 2026-11-07

The first stable release, after running on real hardware through restarts, updates and a change of public IP address. The container works exactly as in 0.0.3.

### Added

- A [Versions](https://github.com/mdr6273/no-fixed-address#versions) section in the README that says which changes count as breaking and which image tag to use. From this release on, settings, their defaults and the image name only change in a new major version, and the `1` tag never brings a breaking change.

## [0.0.3] - 2026-11-07

### Changed

- **Breaking:** `CF_ZONE` is now `ZONE` and `CF_RECORDS` is now `RECORDS`, so the names no longer tie the container to one DNS provider. The values stay the same. A container that still uses the old names stops at startup with a message naming the new ones. On Unraid, edit the container, select **Edit** next to **Zone** and **Records**, change each **Key** to `ZONE` and `RECORDS`, and apply.

## [0.0.2] - 2026-10-30

### Changed

- The Unraid template is now named No-Fixed-Address, to match the repository and the image. Containers installed from the old template keep their name.

## [0.0.1] - 2026-10-30

### Added

- Keeps Cloudflare A and AAAA records in one zone pointed at the host's public IPv4 and IPv6 addresses, checking at startup and then every `INTERVAL` seconds (daily by default).
- Address detection through Cloudflare's trace endpoint, with ipify and ifconfig.me as fallbacks. Answers are strictly validated, and private and reserved addresses are refused.
- Updates only the records whose address differs, and leaves proxy status and TTL alone unless `PROXIED` or `TTL` is set.
- `CREATE_IF_MISSING` to create records that don't exist yet, and `DRY_RUN` to log changes without making them.
- Token verification at startup for both user and account-owned API tokens, and `CF_API_TOKEN_FILE` for Docker secrets.
- Retries with exponential backoff, from 60 seconds up to an hour, after network or API failures, and prompt shutdown on SIGTERM and SIGINT.
- A Docker health check that fails when the last successful check is older than `INTERVAL` plus two hours.
- Multi-architecture image (linux/amd64, linux/arm64) on GitHub Container Registry, running as a non-root user.
- Unraid template and icon. The template runs the container with no capabilities and a read-only filesystem.

[Unreleased]: https://github.com/mdr6273/no-fixed-address/compare/v1.1.0...HEAD
[1.1.0]: https://github.com/mdr6273/no-fixed-address/compare/v1.0.0...v1.1.0
[1.0.0]: https://github.com/mdr6273/no-fixed-address/compare/v0.0.3...v1.0.0
[0.0.3]: https://github.com/mdr6273/no-fixed-address/compare/v0.0.2...v0.0.3
[0.0.2]: https://github.com/mdr6273/no-fixed-address/compare/v0.0.1...v0.0.2
[0.0.1]: https://github.com/mdr6273/no-fixed-address/releases/tag/v0.0.1
