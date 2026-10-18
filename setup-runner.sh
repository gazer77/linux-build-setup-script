#!/usr/bin/env bash
# Sets up a GitHub Actions self-hosted runner on this machine (jacktheripper) for one repository.
# GitHub ties a runner on a personal account to one repo, so every repo
# that builds here gets its own runner. They all run as the github-runner user, each in its own
# folder under /home/github-runner, each as its own systemd service.
#
# Usage:
#   sudo bash setup-runner.sh --repo owner/name --label <label> [--token <token>] [--dir <folder>] [--replace]
#
#   --repo     GitHub repository, e.g. gazer77/media.frame
#   --label    Label the workflow's runs-on asks for, e.g. media-frame
#   --token    Either the registration token from the repo's Settings -> Actions -> Runners ->
#              New self-hosted runner (valid for an hour), or a personal access token that can
#              administer the repo (fine-grained: "Administration: Read and write" on that repo),
#              which is used to fetch a registration token. Asked for when left out, which keeps
#              it out of shell history.
#   --dir      Runner folder under /home/github-runner, default <label>-runner
#   --replace  Register again over an existing runner in that folder
#
# Run it from your own admin account; github-runner itself has no password or sudo rights by design.
set -euo pipefail

RUNNER_USER=github-runner
RUNNER_HOME=/home/$RUNNER_USER

repo= label= token= dir= replace=
while [ $# -gt 0 ]; do
    case "$1" in
        --repo)    repo="$2"; shift 2 ;;
        --label)   label="$2"; shift 2 ;;
        --token)   token="$2"; shift 2 ;;
        --dir)     dir="$2"; shift 2 ;;
        --replace) replace=1; shift ;;
        -h|--help) sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "Unknown argument: $1 (see --help)" >&2; exit 1 ;;
    esac
done

if [ -z "$repo" ] || [ -z "$label" ]; then echo "--repo and --label are required (see --help)" >&2; exit 1; fi
if [[ ! "$repo" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]]; then echo "--repo must look like owner/name" >&2; exit 1; fi
if [ "$(id -u)" -ne 0 ]; then echo "Run with sudo" >&2; exit 1; fi

dir="$RUNNER_HOME/${dir:-$label-runner}"
name="$(hostname)-$label"

if [ -z "$token" ]; then
    read -rsp "Registration token or personal access token for $repo: " token
    echo
fi
if [ -z "$token" ]; then echo "No token given" >&2; exit 1; fi

# Prints a Python expression evaluated against the JSON on stdin (as `j`).
json() { python3 -c "import json, sys; j = json.load(sys.stdin); print($1)"; }

# ── Packages the runner and the workflows need ───────────────────────────────
missing=()
for cmd in curl python3 git tar; do command -v "$cmd" >/dev/null || missing+=("$cmd"); done
if [ ${#missing[@]} -gt 0 ]; then
    echo "Installing ${missing[*]}"
    apt-get update -qq
    apt-get install -y "${missing[@]}"
fi

# ── Registration token ───────────────────────────────────────────────────────
# A personal access token is traded for a registration token; anything else is taken to be one already.
if [[ "$token" =~ ^(ghp_|github_pat_) ]]; then
    echo "Fetching a registration token for $repo"
    token=$(curl -fsSL -X POST -H "Authorization: Bearer $token" -H "Accept: application/vnd.github+json" \
        "https://api.github.com/repos/$repo/actions/runners/registration-token" | json 'j["token"]') || {
        echo "GitHub refused the personal access token: it needs Administration read/write on $repo" >&2
        exit 1
    }
fi

# ── Runner user ──────────────────────────────────────────────────────────────
if ! id "$RUNNER_USER" >/dev/null 2>&1; then
    echo "Creating user $RUNNER_USER"
    useradd --create-home --shell /bin/bash "$RUNNER_USER"
fi

as_runner() { sudo -u "$RUNNER_USER" -H "$@"; }

# ── Download the runner ──────────────────────────────────────────────────────
if [ ! -x "$dir/config.sh" ]; then
    case "$(uname -m)" in
        x86_64)  arch=x64 ;;
        aarch64) arch=arm64 ;;
        armv7l)  arch=arm ;;
        *) echo "Unsupported architecture: $(uname -m)" >&2; exit 1 ;;
    esac
    version=$(curl -fsSL https://api.github.com/repos/actions/runner/releases/latest | json 'j["tag_name"].lstrip("v")')
    echo "Downloading runner $version ($arch) into $dir"
    as_runner mkdir -p "$dir"
    curl -fsSL "https://github.com/actions/runner/releases/download/v$version/actions-runner-linux-$arch-$version.tar.gz" \
        | as_runner tar -xz -C "$dir"
fi

# The runner's own script: installs the .NET native libraries it needs (libicu and friends).
(cd "$dir" && ./bin/installdependencies.sh >/dev/null)

# ── Register with GitHub ─────────────────────────────────────────────────────
cd "$dir"
if [ -f .runner ]; then
    if [ -z "$replace" ]; then
        echo "$dir already holds a registered runner. Pass --replace to register it again." >&2
        exit 1
    fi
    echo "Removing the existing registration"
    if [ -f .service ]; then ./svc.sh stop || true; ./svc.sh uninstall; fi
    as_runner ./config.sh remove --token "$token"
fi

echo "Registering $name with label $label"
as_runner ./config.sh --unattended --replace \
    --url "https://github.com/$repo" --token "$token" \
    --name "$name" --labels "$label" --work _work

# ── Run it as a service ──────────────────────────────────────────────────────
./svc.sh install "$RUNNER_USER"
./svc.sh start

echo
echo "Runner $name is up for $repo (labels: self-hosted, Linux, $label)."
echo "  Status:  sudo systemctl status $(cat .service)"
echo "  Logs:    sudo journalctl -u $(cat .service) -f"
echo "  GitHub:  https://github.com/$repo/settings/actions/runners"
