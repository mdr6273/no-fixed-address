# Contributing

Issues and pull requests are welcome. For anything bigger than a small fix,
please open an issue first so the approach can be agreed before you spend
time on it.

## Ground rules

- **Stay dependency-light.** At runtime this is POSIX sh, curl and jq on Alpine. Avoid bash-only features: the script has to work under busybox ash, dash and bash.
- **Run ShellCheck.** CI uses version 0.11.0 and the settings in `.shellcheckrc`:

  ```sh
  shellcheck src/nofixedaddress.sh tests/*.sh
  ```

- **Run the tests, and add tests for behaviour you change.** The unit tests need a shell and jq; the end-to-end tests also need curl and python3 and run against a local mock of the Cloudflare API, which also stands in for notification webhooks.

  ```sh
  sh tests/run.sh
  sh tests/e2e.sh
  ```

- **Never log the API token or the notification URL**, or anything derived from them. The notification URL's host is the one exception.
- **Comments explain why**, not what the next line does.
- **Commit messages** follow [Conventional Commits](https://www.conventionalcommits.org/) (`feat:`, `fix:`, `docs:` and so on).
- **User-visible changes** get a line in the Unreleased section of [CHANGELOG.md](CHANGELOG.md).

## Releasing

1. On a branch, move the Unreleased entries in `CHANGELOG.md` into a new version section and update the links at the bottom. Pick the number by [Versions](README.md#versions) in the README.
2. Open a pull request. `main` only accepts changes through pull requests whose checks pass.
3. Once it's merged, tag the merge commit and push the tag: `git fetch origin && git tag -a v1.2.3 -m "No Fixed Address 1.2.3" origin/main && git push origin v1.2.3`. Release tags can't be moved or deleted afterwards, so check the commit first.

The release workflow first runs CI, which tests the image for amd64, arm64,
arm/v7 and arm/v6 (the last three under emulation). It then builds the image
for all four, pushes it to GitHub Container Registry with version tags and
`latest`, and creates the GitHub release from the matching changelog section.
