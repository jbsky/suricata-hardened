# Security Audit Status

The weekly `security-audit.yml` workflow (Trivy + Grype, `--fail-on high --only-fixed`)
scans the published image every Tuesday. This file tracks known, investigated
exceptions so the CI state doesn't need to be re-diagnosed from scratch each time it
comes up.

| CVE | Package | Status | Why | Resolves when |
|---|---|---|---|---|
| CVE-2026-15308 | python 3.14.6 | Suppressed (`.grype.yaml`) | DoS in `html.parser.HTMLParser` (CPU exhaustion via malformed markup). `suricata-update` -- the only thing running on this Python -- fetches/parses YAML index and plain-text rule files over HTTPS; it never imports `html`/`html.parser` (verified: zero references in the installed package source). Vulnerable code is present in the stdlib but unreachable. | Python 3.15.0 ships stable (currently only a `3.15.0b3` beta exists, and it doesn't cover this CVE either). Re-check `python:3.15-alpine` once released and bump the `pybuilder` stage in the `Dockerfile`. |

Previously resolved (kept for context, no longer relevant once superseded by a rebuild):

| CVE(s) | Package | Fixed by |
|---|---|---|
| GO-2026-4970, GO-2026-5856 | Go stdlib | Bumped `golang:1.26-alpine` digest (2026-07-15) |
| GHSA-5rjg-fvgr-3xxf, GHSA-4xh5-x5gv-qwph, GHSA-wf93-45jw-7689, and 5 more CPython CVEs | python, setuptools, pip (3.12.13) | Moved `suricata-update`'s Python runtime to the official `python:3.14-alpine` image (3.14.6), see `Dockerfile` `pybuilder` stage |

## Old vulnerable image tags left publicly pullable (found 2026-07-21, fixed)

Same root cause as `nginx-hardened`: `build-push.yml` pushes a new immutable version
tag (e.g. `8.0.5`) on every run, in addition to `:latest`, on both Docker Hub and
GHCR, and never retired the previous one. Confirmed via a direct `grype` scan against
the old published tag `8.0.5`: real, currently-unfixed CVEs in the bundled
`suricata-update` Python runtime (`CVE-2026-8328`, `CVE-2026-4786`, and others,
predating the `python:3.14-alpine` move documented above) plus Go stdlib
`GO-2026-4970`/`5856`.

Fixed by `registry-cleanup.yml` (`scripts/prune-registry-tags.sh` for Docker Hub,
`scripts/prune-ghcr-tags.sh` for GHCR), called as a job from `build-push.yml` after
every push, and directly `workflow_dispatch`-able. Keeps the last 3 semver tags +
`:latest`. Only ever deletes a package version by its own named tag -- untagged
manifest-list children, attestations, and cosign signatures are left alone.

**Important caveat** (hit on `nginx-hardened`'s first run, applies here too): "keep the
last 3 semver tags" is generic hygiene, not CVE-aware. After any prune run,
cross-check the surviving semver tags with a direct `grype <image>:<tag> --fail-on
high --only-fixed --config .grype.yaml` scan -- if one inside the keep-window is
still flagged, delete it explicitly.
