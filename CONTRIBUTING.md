# Contributing

Contributions are welcome: new boundary tests, `sbx` syntax fixes, results on other versions or systems.

## Rules

1. **Everything synthetic.** Canaries generated on the spot; no real key, IP, host name or path in the code, in the examples or in the results.
2. **Parametrize through environment variables** (`LAB_DIR`, `LAN_TARGETS` etc.); nothing hardcoded from your machine.
3. **Each test measures and compares with what is expected** (`OK`, `LEAKED`, `DIVERGES`). Count canaries only in the sandbox output, not in the host log.
4. **Every script cleans up what it created** (`trap`): sandbox, secret, network rule.
5. **Keys only through the stdin** of `sbx secret set`; never in a file, an argument or an echo.
6. Before opening the PR: `bash -n` on the `.sh` files, `python -m py_compile` on the `.py` file and `bash tools/gate-test.sh` (it must print `GATE-TEST: PASS`).
7. When reporting a result, state the `sbx` version, the system and the date. Do not paste raw logs: they carry data from the environment.
8. No em dash in the text: use a hyphen.

License of contributions: MIT.
