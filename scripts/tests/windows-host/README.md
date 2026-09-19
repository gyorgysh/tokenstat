# Windows host and vault regression checks

Run `dotnet run --project scripts/tests/windows-host/WindowsHostTests.csproj`.

The tests use an isolated named pipe and fake SSH records. They cover concurrent
requests, timeouts, recovery before sending, no replay after an interrupted
mutation, vault dependency ordering, timestamps, tombstones, unknown records,
private-key separation, credential preservation on failed updates, folder-deletion
reparenting, locked-vault protection, and signed-out editing.

On Windows the same command also checks that the production app-owner lock
survives garbage collection and releases on quit. That check is skipped on Mac
and Linux. Native WinUI rendering, Task Scheduler behavior, and cross-device
screen/workspace permissions still require Windows integration testing.
