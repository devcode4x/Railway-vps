# Railway Ubuntu 22.04 Dev Box

A Railway-ready Ubuntu development container with SSH access for Termius, a browser terminal, Python 3.12, Node.js 24, Git/GitHub CLI, Claude Code, tmux, and persistent home storage.

**Ngrok is not included.** Root SSH login is disabled; connect as `dev` and use `sudo` when administrative access is needed.

## Files

- `Dockerfile` — installs Ubuntu 22.04 and development tools.
- `entrypoint.sh` — configures the runtime password, persistent SSH host keys, browser terminal, and service processes.
- `sshd_config` — SSH settings and login throttling.

## Deploy on Railway

1. Put these files in the root of a GitHub repository.
2. In Railway, create a new project/service from that GitHub repository. Railway should detect the Dockerfile.
3. Add a Railway Volume mounted at `/home/dev`.
4. Add these Variables:
   - `SSH_PASSWORD` = a strong, unique password (do not reuse an account password).
   - `TZ` = `Asia/Kolkata` (already the Docker default; this is optional).
   - `ROOT_PASSWORD` = optional local root password; direct root SSH remains disabled.
   - `ANTHROPIC_API_KEY` = optional, only if you use Claude Code with an API key.
   - `GITHUB_TOKEN` = optional, for authenticated GitHub CLI / Git over HTTPS.
   - `AUTHORIZED_KEYS` = optional SSH public key(s), one per line.
5. Under Settings → Networking, create a TCP Proxy targeting **container port 22**.
6. Generate/enable a Railway public domain for the browser terminal. Railway supplies `PORT`; nginx listens on it.

## Connect from Termius

- Address: the TCP Proxy hostname Railway gives you.
- Port: the TCP Proxy's public port (not necessarily 22).
- Username: `dev`
- Password: the value of `SSH_PASSWORD`

Use `sudo -i` after login for a root shell. Direct root SSH is intentionally disabled.

## Browser terminal

Open the Railway public HTTPS domain. The browser asks for HTTP Basic Auth:

- Username: `dev`
- Password: the same `SSH_PASSWORD`

The shell runs inside a persistent tmux session named `main`.

## Python virtual environment

Use Python 3.12 like this:

```bash
python3 --version
python3 -m venv .venv
source .venv/bin/activate
python -m pip install --upgrade pip
```

## Included tools

Ubuntu 22.04; Python 3.12 (`python3` and `python` commands); Python venv support; Node.js 24 + npm; Git + Git LFS; GitHub CLI (`gh`); Claude Code CLI; OpenSSH; sudo; nano/vim; tmux; build-essential; curl/wget; jq; htop; ripgrep; tree; rsync; zip/unzip; DNS and network diagnostic tools; ttyd + nginx browser terminal.

## Notes and limits

- `/home/dev` persists only when a Railway Volume is mounted there.
- Files under the container filesystem outside `/home/dev`, and packages installed manually with `apt` after deployment, can be lost on a rebuild/redeploy. Put project files and user-installed tools under `/home/dev` where practical.
- Railway containers are not dedicated VMs. They have Railway resource, lifecycle, networking, and usage limits.
- Railway TCP Proxy forwards traffic to the selected internal port; the assigned public port can be different from 22.
- The SSH server has root login disabled and OpenSSH per-source connection throttling enabled. This image relies on OpenSSH rate-limiting; it does not configure firewall-based fail2ban bans.
