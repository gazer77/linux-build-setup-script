# Hosting a project on jacktheripper

This is a brief for whoever (a person or a coding agent) sets up a new project to deploy to **jacktheripper**, the
Linux server on the home LAN. It describes how the server is laid out and the pattern every project follows, so that
each push to `main` builds the project on the server and publishes it at `http(s)://<name>.local`.

The working example is the xs-and-os-game repo (a static web game): its `.github/workflows/deploy.yml` and its
`deploy/` folder (`README.md`, `build-web.sh`, `deploy.sh`, `setup-server.sh`). When in doubt, copy what it does.

## How the server is laid out

- **Caddy owns ports 80 and 443** and serves each project by name from `/etc/caddy/Caddyfile`. Never bind a project
  to port 80 or 443 itself.
- **Projects that run a process** (an API, a server-rendered app) run as a systemd service on their own local port,
  bound to `127.0.0.1`, and Caddy proxies to it. HomeCenter, for example, runs on 5261. Before picking a port, check
  it's free on the server with `ss -ltn`.
- **Static projects** (a built web app or game) have no service or port. Caddy serves their files from
  `/srv/<project>/current`.
- **`.local` names** are announced over mDNS by Avahi through the shared template unit
  `/etc/systemd/system/avahi-alias@.service`. `sudo systemctl enable --now avahi-alias@<name>` announces
  `<name>.local`. Names already taken: `cards`, `headlines`, `homecenter`, `xsandos`. Don't run `avahi-publish` in a
  unit with `DynamicUser=true`, because it fails with a D-Bus error.
- **Builds run on the server** under a GitHub Actions self-hosted runner, one runner per repo. They all run as the
  `github-runner` user, which has no password and **no sudo**. Each repo's runner is in
  `/home/github-runner/<label>-runner`, and its checkouts are under `_work/` there.

## What the project needs

### 1. A runner for the repo

On the server, from an admin account, using `setup-runner.sh` from this repo:

```bash
sudo bash setup-runner.sh --repo gazer77/<repo> --label <label>
```

The label is short and kebab-case, usually the project name. The script asks for a registration token from the
repo's *Settings → Actions → Runners → New self-hosted runner*. See this repo's README for the details.

**The repo must be private.** On a public repo, a pull request from a fork could run code on the server.

### 2. `.github/workflows/deploy.yml`

It runs on every push to `main`, plus a manual *Run workflow* button, one deploy at a time:

```yaml
name: Deploy to jacktheripper

on:
  push:
    branches: [main]
  workflow_dispatch:

concurrency:
  group: deploy-<project>
  cancel-in-progress: false

jobs:
  deploy:
    runs-on: [self-hosted, linux, <label>]
    timeout-minutes: 30
    steps:
      - uses: actions/checkout@v4
      - name: Check the server
        run: bash deploy/deploy.sh --check
      - name: Test and build
        run: bash deploy/build.sh
      - name: Publish and switch over
        run: bash deploy/deploy.sh
```

The usual branch flow is that day-to-day work happens on `development`, and merging it into `main` is what deploys.

### 3. `deploy/build.sh`

This runs as `github-runner`, without root. It:

- runs the tests, so a failing test stops the deploy;
- builds into a folder in the repo, such as `build/`;
- downloads any toolchain it needs into `~/.cache` or `~/.local/share` on first use, pinned to an exact version, and
  reuses it after that;
- for anything it can't download (system packages), fails with a `::error::` line that says to run
  `setup-server.sh`.

Start it with `set -euo pipefail` and `cd "$(dirname "${BASH_SOURCE[0]}")/.."`.

### 4. `deploy/deploy.sh`

This also runs as `github-runner`. It publishes the build as a release and switches over:

```
/srv/<project>/releases/<yyyymmdd-hhmmss>-<short sha>/   one folder per deploy; keep the newest 5
/srv/<project>/current  ->  the live release (a symlink)
```

- With `--check`, it only verifies that `/srv/<project>/releases` exists and is writable. If it isn't, it prints the
  exact `sudo bash .../deploy/setup-server.sh` command and exits 1. The first run of the workflow uses this to tell
  you what to run.
- It copies the build into a new release folder and swaps `current` atomically:
  `ln -sfn "$release" current.new && mv -T current.new current`.
- **Static project:** Caddy serves `current` directly, so nothing restarts.
- **Service project:** restart the service. `github-runner` has no sudo, so `setup-server.sh` installs a sudoers rule
  that allows exactly that one command (see below). Run it as `sudo -n systemctl restart <project>`.
- **Health check, with rollback.** Request the site through Caddy, for example
  `curl -fsS --resolve <name>.local:443:127.0.0.1 https://<name>.local/...` (add `-k` for `tls internal`), or use
  port 80 for an HTTP site. For a static build, compare a file's hash with the build's. For a service, check a
  health endpoint. If the check fails, switch `current` back to the previous release (and restart again for a
  service), delete the new release, and exit 1.
- Prune releases older than the newest five, but never the one `current` points to.

### 5. `deploy/setup-server.sh`

This is the one-time server setup, run with sudo by hand. It must be **safe to run again**: running it again is how
changes to it reach the server. It doesn't depend on the rest of the repo. It:

- checks that it's running as root and that the runner user (default `github-runner`, or the first argument) exists;
- installs any missing packages with `apt-get`, including `caddy`, `avahi-daemon` and `avahi-utils`, plus whatever
  the build needs;
- creates `/srv/<project>/releases` owned by the runner user: `install -d -o github-runner -g github-runner ...`;
- **service project:** writes `/etc/systemd/system/<project>.service`. It runs as a non-root user (a dedicated
  system user, or `DynamicUser=true` if the service needs no persistent files of its own), starts from
  `/srv/<project>/current`, listens on `127.0.0.1:<port>`, and uses `Restart=on-failure`. Keep data that must
  survive deploys outside `releases/`, for example in `/srv/<project>/data` or `StateDirectory=`. Run
  `systemctl daemon-reload` and `systemctl enable <project>`. Then add the sudoers rule with `visudo -cf` so a bad
  file is never installed:
  ```
  # /etc/sudoers.d/<project>-deploy
  github-runner ALL=(root) NOPASSWD: /usr/bin/systemctl restart <project>
  ```
- writes the project's Caddy site into `/etc/caddy/Caddyfile` between marker lines that it replaces on every run:
  ```
  # >>> <project>: managed by deploy/setup-server.sh in the <repo> repo; edits are replaced.
  ...site...
  # <<< <project>
  ```
  Back up the file first, validate it with `caddy validate --adapter caddyfile --config /etc/caddy/Caddyfile`, and
  then `systemctl reload caddy`. If validation fails, put the backup back and exit 1. Never touch other projects'
  sites.
- announces the name: if the `avahi-alias@.service` template is missing, write it (copy it from xs-and-os
  `setup-server.sh`); then run `systemctl enable --now avahi-alias@<name>`.
- ends by printing what to do next.

### Caddy sites

Use **plain HTTP by default**. A service project looks like this:

```
http://<name>.local {
    reverse_proxy 127.0.0.1:<port>
}
```

A static project looks like this:

```
http://<name>.local {
    encode zstd gzip
    header Cache-Control "no-cache"
    root * /srv/<project>/current
    file_server
}
```

Use **HTTPS** only when the browser requires a secure page. That includes WebAssembly games such as Godot, service
workers and PWAs, camera and microphone access, the clipboard, and crypto.subtle. In that case, use `tls internal`
(Caddy's own certificate authority) the way xs-and-os does: an HTTPS site, plus an `http://` site that redirects to
it and serves `/caddy-root.crt`. Devices already trust that root if they trusted it for `xsandos.local`, because
every `tls internal` site on the server uses the same one. Copy the certificate-trust instructions from xs-and-os's
`deploy/README.md`.

### 6. `deploy/README.md`

Describe what deploys and where it goes live, what each file does, the one-time setup steps (runner, then the
server script, then the first deploy), and how to build and deploy by hand on the server. xs-and-os's is the model.

## Order of operations

1. Add the workflow and `deploy/` scripts to the repo, and get them onto `main`.
2. On the server: `sudo bash setup-runner.sh --repo gazer77/<repo> --label <label>`.
3. On GitHub: *Actions → Deploy to jacktheripper → Run workflow*. It stops at *Check the server* with the
   `setup-server.sh` command.
4. On the server, run that command: `sudo bash /home/github-runner/<label>-runner/_work/<repo>/<repo>/deploy/setup-server.sh`.
5. Run the workflow again. The project is live at `http(s)://<name>.local`.

## Rules of thumb

- Shell scripts use LF line endings. Add `*.sh text eol=lf` to `.gitattributes`, or the scripts break on the server
  when committed from Windows.
- Nothing listens on anything but `127.0.0.1` except Caddy. Nothing is opened on the router. The runner only makes
  outgoing connections to GitHub.
- Secrets the app needs at runtime go in a root-owned environment file referenced by `EnvironmentFile=` in the unit,
  created by hand on the server. Never put them in the repo or the workflow.
- Prefer failing with a clear `::error::` message and the exact fix over guessing.
