# linux-build-setup-script

Sets up a GitHub Actions self-hosted runner on a Linux machine (here, jacktheripper on the home LAN) for one
repository. Workflows then build there instead of using GitHub-hosted minutes.

GitHub ties a runner on a personal account to one repository, so every repo that builds on the machine gets its own
runner. They all run as the `github-runner` user, each in its own folder under `/home/github-runner`, each as its own
systemd service.

## Usage

Copy `setup-runner.sh` to the machine and run it from your own admin account:

```bash
sudo bash setup-runner.sh --repo gazer77/media.frame --label media-frame
```

| Option | |
|---|---|
| `--repo owner/name` | Required. The repository the runner serves. |
| `--label <label>` | Required. The label the workflow's `runs-on` asks for. |
| `--token <token>` | See below. Asked for (without echo) when left out, which keeps it out of shell history. |
| `--dir <folder>` | Runner folder under `/home/github-runner`. Default `<label>-runner`. |
| `--replace` | Register an existing runner folder again. |

The token can be either:

* the **registration token** from the repo's *Settings → Actions → Runners → New self-hosted runner* page, which is
  valid for an hour, or
* a fine-grained **personal access token** with *Administration: Read and write* on the repo. The script trades it for
  a registration token.

## What it does

1. Installs any of curl, python3, git and tar that are missing.
2. Creates the `github-runner` user if needed. It has no password or sudo rights.
3. Downloads the latest runner for the machine's architecture and installs the libraries it needs.
4. Registers it as `<hostname>-<label>` with that label.
5. Installs and starts it as a systemd service, and prints the commands to check on it.

A workflow then targets it with `runs-on: [self-hosted, linux, <label>]`.

Anything a repo needs beyond the runner, such as a sudo rule to restart its service, is up to that repo.

> Keep each repository that uses a runner **private**. On a public repo, a pull request from a fork could run code on
> the machine.
