
# greengrass_lite_intuitivo

Elixir supervision of the nine AWS IoT Greengrass Nucleus Lite daemons on Nerves.

## OS process lifecycle

Each daemon runs through the existing MuonTrap dependency (minimum 1.7). Closing
an Erlang port alone does not stop a daemon that ignores stdin EOF. MuonTrap
terminates its direct child on port closure or owner death, escalating from
SIGTERM to SIGKILL after 500 ms. It does not use cgroups or kill Greengrass component
process trees.

During orderly shutdown on Linux/Nerves, the owner waits up to two seconds for
the monitor to finish cleanup. The check includes `/proc` start time to distinguish
PID reuse. A cleanup timeout is logged as `GREENGRASS_LITE_DAEMON_CLEANUP_TIMEOUT`;
the explicit `stop/1` call also returns an error. An untrappable owner crash cannot
run this wait, so old and replacement daemons may briefly overlap while MuonTrap
performs cleanup. This change prevents the reproduced persistent accumulation;
it is not an atomic singleton lock.

The private state field `monitor_os_pid` and the startup log's `monitor_pid`
identify the MuonTrap process, **not** `iotcored` or another native daemon. Count
daemons by exact executable name and associate their sockets through `/proc`.
One healthy instance contains nine daemons plus nine lightweight monitors.

Repeated `:start_daemon` messages are ignored while a port is already owned.
Output is acknowledged while running and while waiting for `ggconfigd` to create
its socket, so its output window cannot stall startup. The socket remains
`/run/greengrass/gg_config`; tests override `:gg_config_socket` with a temporary path.

## Tests

Run `mix test` on Linux with a C compiler. The lifecycle tests launch actual C
processes that ignore stdin and SIGTERM; they verify graceful stop, abrupt owner
death, continuous output, startup output larger than the MuonTrap window, exit
status propagation, duplicate start messages, and 20 `rest_for_one` restart
cycles. They are explicitly skipped on hosts without Linux `/proc`.

For a Linux test run from macOS using Docker:

```sh
docker run --rm --mount "type=bind,source=$PWD,target=/work" --workdir /work \
  elixir:1.16.2-otp-26 sh -c \
  'mix local.hex --force && mix local.rebar --force && mix deps.get && mix test'
```

## M0204 canary acceptance plan (not deployed)

1. Pin an approved commit of this dependency in a new firmware build. Record the
   dependency SHA, firmware UUID, target and rollback image. Use a normal firmware
   release/reboot, not IEx hot-loading into existing daemon structs. Existing
   orphan processes are not retroactively adopted by this patch.
2. Verify the active WAN/default route. The previous M0204 Ethernet baseline is
   not comparable to its later Wi-Fi configuration. Collect a fresh 10-minute
   baseline with real timestamps, interface RX/TX counters, exact daemon counts,
   IoT socket ownership, operations, queues and completed uploads.
3. After the canary boots and settles, collect the same readings locally each
   minute for 30 minutes, then retrieve the complete record. Account for the
   reboot's counter reset and confirm the same WAN interface and comparable
   upload workload. Count all bytes on that interface; this is not per-process
   attribution or carrier billing.
4. Require nine daemons, one `iotcored`, a working IoT connection, continued Core
   telemetry/operation and no new upload backlog. Missing samples, disconnection,
   cleanup timeouts or persistent duplicates invalidate a savings claim and stop
   the experiment for review. A quieter disconnected device is not a success.
5. Compare full-coverage RX+TX bytes divided by actual elapsed time, in decimal
   MB/h. Keep P0445 as a read-only reference if still comparable. A later bounded
   soak of at least three hours is needed for stability: M0204 previously
   accumulated duplicates again in approximately 2.5 hours.

Only the dependency fix and local regression tests have been prepared here.
Hardware validation, firmware publication and deployment are separate steps.
