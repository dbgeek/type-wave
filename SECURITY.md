# Security Policy

type-wave is an experimental research project. It handles sensitive material on
your Mac: your OpenAI API key (stored in the macOS login keychain) and live
microphone audio. Security reports are taken seriously even though the project
is provided as-is with no support guarantee.

## Reporting a vulnerability

**Please report vulnerabilities privately — do not open a public issue.**

Use GitHub's private reporting: open the **Security** tab and click **Report a
vulnerability** to file a private security advisory. This keeps the details out
of the public tracker until a fix is available.

If you cannot use GitHub's private reporting, email **me@ba78.me** instead.

Please include, where possible:

- The type-wave version or commit you are running.
- A description of the issue and its impact (for example: API-key or audio
  exposure, or insertion into an unintended target).
- Steps to reproduce.

## What to expect

This is a single-maintainer project with no SLA. Reports are handled on a
best-effort basis, so you may not receive an immediate response. There is no bug
bounty. Fixes land on `main`; there are no separately maintained release
branches.

## Scope

In scope: the type-wave daemon and helper in this repository — API-key handling,
keychain access, audio capture, network transport to the transcription backend,
and text insertion.

Out of scope: vulnerabilities in third-party dependencies (please report those
upstream), and issues that require an already-compromised machine or physical
access to the Mac running type-wave.
