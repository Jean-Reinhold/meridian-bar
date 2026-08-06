# Security policy

MeridianBar talks only to a loopback Meridian instance and makes no other
network connections (Sparkle update checks to GitHub excepted, once
shipped). If you believe you've found a vulnerability — anything that
leaks account data, executes untrusted input, or widens the network
surface — please report it privately.

## Reporting

Use [GitHub private vulnerability reporting](https://github.com/Jean-Reinhold/meridian-bar/security/advisories/new).
Please do not open a public issue for suspected vulnerabilities.

You can expect an acknowledgement within a week. Fixes ship as a patch
release with credit in the release notes unless you prefer otherwise.

## Scope notes

- The app trusts its configured base URL (default `http://127.0.0.1:3456`).
  Reports about what a *malicious local Meridian* could display are
  interesting but low severity — that process already runs as the user.
- Update integrity (Sparkle EdDSA + notarization) is in scope from the
  first release that ships it.
