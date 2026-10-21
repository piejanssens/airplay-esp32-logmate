# airplay-esp32-logmate

Continuously captures websocket log streams from multiple ESP32-AirPlay
devices into per-device timestamped log files, with automatic reconnect.

This is a standalone logging capture solution for the
[airplay-esp32](https://github.com/rbouteiller/airplay-esp32) project: it
lives and runs entirely outside that firmware repository, requires no changes
to the devices themselves, and only consumes the websocket log endpoint they
already expose (`ws://<device>/ws/logs`).

## Files

Anything under `app/` is baked into the image at build time (change it and you
need `--build`); everything beside it is host state, bind-mounted at runtime
(change it and a restart is enough).

- `app/capture_logs.sh` — the capture script (bash + websocat)
- `app/entrypoint.sh` — installs the crontab, starts `crond`, execs the capture script
- `app/logrotate.conf` / `app/crontab` — log rotation config and its schedule
- `config-example.yaml` — template to copy to `config.yaml`
- `config.yaml` — your device list (git-ignored, see below)
- `logs/` — captured output, one `<name>.log` per device (git-ignored)
- `Dockerfile` / `compose.yaml` / `.dockerignore` — containerized version

## 1. Configure your devices

Copy the example and edit your copy:

```bash
cp config-example.yaml config.yaml
```

```yaml
devices:
  - name: esp32-221
    url: ws://192.168.1.221/ws/logs

  - name: esp32-225
    url: ws://192.168.1.225/ws/logs
    enabled: false          # optional, default true — park it without deleting
    logfile: kitchen.log    # optional, default <name>.log
```

> **Create `config.yaml` before the first `docker compose up`.** It's a
> bind mount, so if the file doesn't exist Docker silently creates a
> *directory* with that name and the container exits with
> `config file not found`. If that happens, `rmdir config.yaml`, create the
> real file, and start again.

`name` and `url` are required; a device missing either aborts startup with an
error rather than being silently skipped. `name` is just used for the log
filename and console prefix, so set it to whatever's meaningful (room name,
hostname, etc.). If `logfile` doesn't end in `.log` you get a warning, because
log rotation only matches `*.log`.

You can test a single URL manually first:

```bash
websocat -t ws://192.168.1.221/ws/logs
```

If you see log lines streaming in your terminal, the URL is right.

## 2. Run it — Docker (recommended)

```bash
docker compose up -d --build
```

Logs land in `./logs/<name>.log` on the host (bind-mounted). websocat's own
diagnostics (handshake errors, close reasons) are timestamped and merged into
the same file, tagged `[websocat]`, so failures appear in order next to the
device output that preceded them. Follow live output:

```bash
docker compose logs -f
tail -f logs/kitchen.log
```

Stop it:

```bash
docker compose down
```

If your devices are only reachable via the host's network (not routable
from the Docker bridge), switch `network_mode` to `host` in
`compose.yaml` — note `host` mode only works on Linux.

Timestamps follow the `TZ` env var set in `compose.yaml`
(`Europe/Brussels`); the image ships `tzdata` so that resolves correctly.
Without it timestamps fall back to UTC.

## 3. Run it — plain Unix (no Docker)

Install `websocat` (e.g. `brew install websocat`, or download a release
binary from https://github.com/vi/websocat/releases) and `yq`
(https://github.com/mikefarah/yq, used to read `config.yaml`), then:

```bash
chmod +x app/capture_logs.sh
./app/capture_logs.sh
```

Press Ctrl+C to stop all device listeners cleanly.

## Log rotation (100MB per file)

`app/logrotate.conf` caps each `logs/<name>.log` at 100MB, keeps 5 rotated
copies compressed, and uses `copytruncate` (safe since `capture_logs.sh`
holds the file open continuously — no signal/restart needed to pick up the
rotation).

- **Docker:** already wired in. `app/entrypoint.sh` installs the crontab (from
  `app/crontab`, checking every 5 minutes) and starts busybox `crond`
  alongside the capture script — nothing extra to do. logrotate is silent
  on success; any errors go to the container's stdout, so they show up in
  `docker compose logs` next to the capture messages.
- **Plain Unix (no Docker):** install `logrotate` and add a cron entry
  yourself, e.g.:
  ```bash
  # crontab -e
  */5 * * * * /usr/sbin/logrotate /path/to/logrotate.conf
  ```
  Just make sure the paths in `app/logrotate.conf` match wherever you're
  running the script from (it currently points at `/app/logs/*.log` for
  the Docker layout — change to your local `logs/` path if running
  natively).

Rotation is triggered purely by file size, so logrotate's state file plays
no part in the decision and isn't configured. If you add a time-based
directive (`daily`, `weekly`, `maxage`, ...), pass
`--state /path/to/logs/.logrotate.state` as well so the last-rotation
timestamps survive container restarts.

Adjust `size 100M` or `rotate 5` in `app/logrotate.conf` if you want a
different cap or retention count.

## Behavior notes

- Each device gets its own background loop; one device dropping/reconnecting
  doesn't affect the others.
- On disconnect, it retries every `RECONNECT_DELAY` seconds (default 5,
  override via env var).
- Log lines are prefixed with an ISO-8601 timestamp at the moment they're
  received, since device-side timestamps may not be present or synced.
- Rotation is handled by `logrotate` (see above), so log files stay capped.
- Connect/disconnect events are written both to the container stdout and into
  the device's own `.log` file, tagged `[capture]`. The file copy is the one
  that matters — `docker logs` is discarded whenever the container is
  recreated.
- Every `HEARTBEAT_INTERVAL` seconds (default 900, set `0` to disable) a
  `[heartbeat]` line on stdout reports how long each device has been silent.
  Nothing is sent to the devices; it's a passive read of each log file's
  mtime.

## Known failure mode: silent hang after a device crash

If a device crashes or is reset by its watchdog, its TCP stack never sends a
FIN or RST — the connection simply ceases to exist on its end. This client
has no way to notice:

- `-U` means websocat never transmits, so the kernel has nothing to
  retransmit and no timeout can fire,
- `SO_KEEPALIVE` is not set (websocat has no flag for it), and
- websocket pings are disabled by default.

The socket therefore stays `ESTABLISHED` indefinitely, `read()` blocks
forever, and the reconnect loop never runs. The container keeps reporting
healthy because PID 1 is alive. This has been observed to last six days.

Detecting it requires sending something — either `--ping-interval` with
`--ping-timeout`, or relaying through `socat` with TCP keepalive enabled.
Both are deliberately not used here, to avoid generating traffic toward
devices that may legitimately be offline. The `[heartbeat]` lines exist so
the condition is at least visible: a device silent far longer than usual is
either idle or hung, and `docker compose restart` resolves the latter.

Note that silence alone does not imply a hang. These devices only log during
playback, and idle periods of 50+ hours are normal.