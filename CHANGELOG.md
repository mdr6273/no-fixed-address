# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project uses
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [1.0.0] - 2026-10-29

### Added

- Keeps Cloudflare A and AAAA records in one zone pointed at the host's public IPv4 and IPv6 addresses, checking at startup and then every `INTERVAL` seconds (daily by default).
- Address detection through Cloudflare's trace endpoint, with ipify and ifconfig.me as fallbacks. Answers are strictly validated, and private and reserved addresses are refused.
- Updates only the records whose address differs, and leaves proxy status and TTL alone unless `PROXIED` or `TTL` is set.
- `CREATE_IF_MISSING` to create records that don't exist yet, and `DRY_RUN` to log changes without making them.
- Token verification at startup for both user and account-owned API tokens, and `CF_API_TOKEN_FILE` for Docker secrets.
- Retries with exponential backoff, from 60 seconds up to an hour, after network or API failures, and prompt shutdown on SIGTERM and SIGINT.
- A Docker health check that fails when the last successful check is older than `INTERVAL` plus two hours.
- Multi-architecture image (linux/amd64, linux/arm64) on GitHub Container Registry, running as a non-root user.
- Unraid template and icon.

[Unreleased]: https://github.com/mdr6273/no-fixed-address/compare/v1.0.0...HEAD
[1.0.0]: https://github.com/mdr6273/no-fixed-address/releases/tag/v1.0.0
