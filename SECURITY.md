# Security

## About this repository

The scripts are lab scripts: they reset network policies, create and remove sandboxes and may spend model credit. Run them only on a machine that is yours and disposable. `mcp/file_reader.py` reads any file on purpose.

## How to report

- **A problem in this repository** (a script that leaks data, deletes something outside `LAB_DIR`, writes a key to a file): open an issue with the `security` label, without pasting keys, IPs or raw logs. If the report needs confidentiality, ask for a private channel in the issue itself, without technical details, and we will arrange it.
- **A flaw in Docker Sandboxes (`sbx`) itself**: do not publish it here. Follow Docker Inc.'s responsible disclosure policy, described on its official website, and only then mention the case.
- **A flaw in an AI model or agent**: report it to the respective vendor.

## If you found a secret in the history

Revoke the credential first, then notify through the issue. Run `bash tools/secrets-gate.sh` before any publication.
