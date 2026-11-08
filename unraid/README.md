# Legacy copies of the Unraid template and icon

The files in this folder are copies. The template that No Fixed Address is
installed from lives in Richardson Resources' Community Applications
repository, [unraid-apps](https://github.com/mdr6273/unraid-apps):

| Copy in this folder | Canonical file in unraid-apps |
| --- | --- |
| `nofixedaddress.xml` | [templates/nofixedaddress.xml](https://github.com/mdr6273/unraid-apps/blob/main/templates/nofixedaddress.xml) |
| `nofixedaddress.png` | [icons/nofixedaddress.png](https://github.com/mdr6273/unraid-apps/blob/main/icons/nofixedaddress.png) |
| `nofixedaddress.svg` | [icons/nofixedaddress.svg](https://github.com/mdr6273/unraid-apps/blob/main/icons/nofixedaddress.svg) |

They stay because their URLs are in use. The template was published from here
before unraid-apps existed, so older instructions and links point at
`unraid/nofixedaddress.xml`, and a container installed from it keeps the icon
URL in its saved template. The copies make sure none of that breaks. The
template copy is the canonical file, byte for byte, so installing from either
URL gives the same container; its `TemplateURL` and `Icon` name the
unraid-apps locations.

## Keeping the copy current

Edit the template in unraid-apps, never here. Then, from this repository's
root, copy the canonical file over this one:

```sh
curl -fsSL https://raw.githubusercontent.com/mdr6273/unraid-apps/main/templates/nofixedaddress.xml \
  -o unraid/nofixedaddress.xml
```

`git diff` afterwards shows exactly what changed in the canonical template,
and a clean `git status` means the copy was already current. Do this in the
same pull request as the application change the template needs, as
[CONTRIBUTING.md](../CONTRIBUTING.md) says. There is no automation on purpose:
a copy that lags behind still installs a working container, it only lacks the
newest fields.

The icons change rarely. If one does change in unraid-apps, copy it the same
way so the old icon URL shows the current icon.
