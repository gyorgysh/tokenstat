# Windows installer regression checks

These tests compile the production installer and host lifecycle code with small
UI/transport stubs and run without Windows or external test packages:

```sh
dotnet build scripts/tests/windows-install/WindowsInstallTests.csproj --artifacts-path /tmp/tokenstat-install-tests
dotnet /tmp/tokenstat-install-tests/bin/WindowsInstallTests/debug/WindowsInstallTests.dll
```

They cover fail-closed Authenticode result handling, nested archive layout,
the verified, complete staging requirement, transactional install rollback,
stale-file removal, and concurrent update checks. Windows integration testing is
still required for signature validation, task registration, install/uninstall,
and the executable replacement after exit.
