# Security

## Reporting a vulnerability

Please report security problems privately, not in a public issue:

- **GitHub:** open the repository's **Security** tab and choose **Report a vulnerability**.
- **Email:** hello@goosehouse.org

Include what you found, how to reproduce it, and what an attacker could do with it. You'll get
a reply within a few days, and credit in the release notes if you'd like it.

## Scope

- The Redde app for iPhone, iPad and CarPlay (the latest App Store release and `main`).
- The companion code in this repository: the push relay Worker, the website and the calendar MCP
  server.

Problems in Hermes itself belong with the [Hermes Agent project](https://github.com/NousResearch/hermes-agent).
Redde never stores or sends your credentials anywhere but your own server and the iOS Keychain; a
way around that is exactly the kind of report we want.
