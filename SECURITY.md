# Security policy

## Supported versions

Fixes are made on the latest release only.

| Version        | Supported |
| -------------- | --------- |
| Latest release | Yes       |
| Older releases | No        |

## Reporting a vulnerability

Please do not open a public issue for a security problem. Report it privately
through GitHub instead: on the repository's **Security** tab, choose
**Report a vulnerability**, or go straight to
<https://github.com/mdr6273/no-fixed-address/security/advisories/new>.

Helpful details to include:

- the image version you tested,
- what an attacker could do and under what conditions,
- steps to reproduce it, and
- a suggested fix, if you have one.

Never include a real API token. A made-up one shows the problem just as well.

You can expect an acknowledgement within a week. How quickly a fix follows
depends on severity; you'll be kept informed, and credited in the release
notes unless you'd rather not be.

## Scope

Especially worth reporting:

- any way the API token could leak: logs, process listings, the environment of
  child processes, image layers or error messages;
- any way to make the container write an address that did not come from a
  validated lookup, or change records it was not configured to manage.

Vulnerabilities in Cloudflare's own services should go to Cloudflare. Issues
in Alpine packages are fixed by rebuilding the image, but please do report it
if a published image lags behind an important update.
