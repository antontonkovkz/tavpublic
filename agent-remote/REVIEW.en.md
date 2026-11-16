# Review findings and fixes

[Русский](REVIEW.md)

The review was checked against the version after commit 6e3dfda. Changes do not
restart the stopped deployment or modify the work PC's protection settings.

| # | Finding and disposition |
| --- | --- |
| 1 | Confirmed. Each spool file is isolated: malformed JSON becomes .bad, permanent HTTP rejection becomes .rejected, transient errors retain results without blocking polling. Added flush/fsync before replace. |
| 2 | Confirmed. Protocol 2 uses a 60-second claim lease and separate /start. Stale leases cannot start execution. Lost /start acknowledgements remain uncertain and are never replayed. Old clients are rejected before issuance. |
| 3 | Confirmed. SYSTEM requires Python under Program Files with trusted owners, protected write ACLs and no reparse points throughout its tree and existing client files. Conservative checks can reject custom installations pending administrator repair. |
| 4 | Confirmed. AllowStartIfOnBatteries and DontStopIfGoingOnBatteries are set. Settings objects were checked without registering a new task. |
| 5 | Confirmed policy dependency. Installer and executor check unsigned file policy and FullLanguage. Restrictions fail clearly; no Bypass or GPO changes. AppLocker/WDAC are not reconfigured. |
| 6 | Confirmed. Results retain head/tail, exceeding 128 KiB no longer kills jobs. A separate 100 MiB combined disk-output cap remains. Tested 200 KB output with exit 7. |
| 7 | Confirmed. Rotating client.log and observed worker futures. Server errors log type/stack frames, authorization failures include request address. Secrets, scripts and output are not logged. |
| 8 | Confirmed. Iteration errors are retried; response shape is validated. Tests cover IncompleteRead and missing job. Configuration failures go to client.log beside client.json; if logging itself cannot start, use foreground stderr for diagnosis. |
| 9 | Confirmed. Windows Job Objects with KILL_ON_JOB_CLOSE: suspended launch, assignment before resume. Tests cover child cleanup after parent exit and client crash. Processes launched by external services outside the Job Object are not covered. |
| 10 | Missing features confirmed. Added waiting TTL, cancellation before execution, list, last poll time and submit --wait. Running cancellation is not implemented. |
| 11 | Partially addressed. Explicit proxy support added. PAC, NTLM/Kerberos and certificate pinning are not implemented; trusted TLS inspection remains within the trust boundary. |
| 12 | Missing indexes/WAL/cleanup confirmed. Added claim, lease, TTL and completion indexes, WAL and local purge of terminal history. Long polling is deferred. Reviewer's 50k/200k row timings were not independently reproduced. |
| 13 | Confirmed. OS file lock prevents duplicate instances using the same spool. Separate configurations with different spools remain an administrator concern. |

## Additional changes and boundaries

An optional read_token allows status/list only. Documentation covers token rotation,
untrusted PC output and operator confirmation before destructive actions. These
rules do not implement script signing or a server approval workflow.

Deployment-specific identifiers were removed from current public files; examples
use remote.example.com. Private notes remain in a locally ignored directory.
Published Git history has not been rewritten: that requires a separately agreed
force-push, and external copies or GitHub caches may retain old data.

See the [installation guide](HTTPS_TRANSPORT.en.md) for coordinated client/server
upgrade and SQLite migration. Back up database and spool first. The new version is
not compatible with the old issuance protocol. Endpoint security is not disabled;
work-PC access must follow organizational policy.

## Validation

Run `python -m unittest discover -s tests -v`. Tests cover the queue, leases, spool,
network failures, tokens, TTL, cancellation, concurrency, output truncation and
Windows Job Objects. Installer syntax and battery settings were checked separately.
Full privileged SYSTEM installation and a domain GPO matrix were not exercised on
this machine; they require a separate Windows test environment.

Microsoft references: [PowerShell policies](https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.core/about/about_execution_policies/),
[Windows Job Objects](https://learn.microsoft.com/en-us/windows/win32/procthread/job-objects).
