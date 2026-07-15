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
