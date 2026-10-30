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

- **Run the tests, and add tests for behaviour you change.** The unit tests need nothing but a shell; the end-to-end tests also need curl, jq and python3 and run against a local mock of the Cloudflare API.

  ```sh
  sh tests/run.sh
  sh tests/e2e.sh
  ```

- **Never log the API token** or anything derived from it.
- **Comments explain why**, not what the next line does.
- **Commit messages** follow [Conventional Commits](https://www.conventionalcommits.org/) (`feat:`, `fix:`, `docs:` and so on).
- **User-visible changes** get a line in the Unreleased section of [CHANGELOG.md](CHANGELOG.md).

## Releasing

1. Move the Unreleased entries in `CHANGELOG.md` into a new version section and update the links at the bottom.
2. Commit, then tag and push: `git tag v1.2.3 && git push origin v1.2.3`.

The release workflow builds the image for amd64 and arm64, pushes it to
GitHub Container Registry with version tags and `latest`, and creates the
GitHub release from the matching changelog section.
