# Security Policy

## Supported Versions

This project is currently pre-1.0. Security fixes target the default branch unless a release branch is explicitly maintained.

## Reporting a Vulnerability

Please do not open public issues for vulnerabilities that expose secrets, local credentials, private paths, or unsafe execution behavior.

Report security concerns by opening a private GitHub security advisory when available, or contact the repository maintainer through GitHub.

## Scope

Security-sensitive areas include:

- MCP server installation and client registration scripts.
- PowerShell scripts that download binaries or modify local configuration.
- MATLAB scripts that execute generated code, open models, or write artifacts.
- Documentation that could encourage unsafe credential handling.

## Expectations

- Do not commit API keys, license files, local logs, generated binaries, or machine-specific MCP config.
- Prefer official MathWorks downloads and documentation.
- Treat community snippets as untrusted until locally verified.
