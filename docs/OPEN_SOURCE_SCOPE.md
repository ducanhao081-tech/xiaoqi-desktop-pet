# Open-source scope

This repository is the public XiaoQi desktop-pet codebase.

Included:

- macOS Swift/AppKit and Windows PowerShell/WPF shells
- XiaoQi's original character pack
- behavior packs and public configuration
- launchers, self-tests, asset utilities, and architecture notes

Excluded from the public source:

- competition, coursework, election, and unrelated delivery materials
- Hermos sessions, approval queues, private worklogs, and account backups
- local memory/state, logs, reports, build outputs, and module caches
- machine-specific integrations and private file bridges
- API keys, tokens, credentials, and shell-profile loading

The default brain provider is the offline template provider. Network providers
are opt-in and must receive credentials through environment variables.
