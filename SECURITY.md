# Security

Please report security issues privately to the repository owner instead of
opening a public issue.

Never commit API keys, tokens, account exports, chat logs, local state, or
machine-specific paths. Runtime providers read credentials only from
environment variables. The launchers do not source shell profiles.

If a secret is committed, revoke it first, then remove it from Git history.
