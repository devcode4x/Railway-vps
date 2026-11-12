#!/usr/bin/env bash
set -Eeuo pipefail

HOME_DIR=/home/dev
STATE_DIR="$HOME_DIR/.devbox"
PORT="${PORT:-8080}"
TTYD_PORT=7681
SSH_PASSWORD="${SSH_PASSWORD:-${PASSWORD:-}}"
ROOT_PASSWORD="${ROOT_PASSWORD:-}"

fail() {
  echo "devbox: $*" >&2
  sleep 2
  exit 1
}

[[ -n "$SSH_PASSWORD" ]] || fail "Set SSH_PASSWORD in Railway Variables (or PASSWORD for compatibility)."
[[ "$PORT" =~ ^[0-9]+$ ]] || fail "PORT must be a numeric port."

# Apply timezone at runtime (Railway variables can override the Docker default).
if [[ -n "${TZ:-}" && -f "/usr/share/zoneinfo/${TZ}" ]]; then
  ln -snf "/usr/share/zoneinfo/${TZ}" /etc/localtime
  echo "$TZ" > /etc/timezone
fi

# /home/dev should be mounted as a Railway Volume. Seed it only on first boot.
mkdir -p "$HOME_DIR"
if [[ ! -e "$HOME_DIR/.bashrc" ]]; then
  cp -a /etc/skel/. "$HOME_DIR"/
  find "$HOME_DIR" -mindepth 1 -maxdepth 1 -not -name lost+found -exec chown -R dev:dev {} +
fi
chown dev:dev "$HOME_DIR"
chmod 0750 "$HOME_DIR"
install -d -o dev -g dev -m 0700 "$HOME_DIR/.ssh"
install -d -o root -g root -m 0700 "$STATE_DIR"

# Never expose root SSH. The dev account has password-protected SSH + sudo.
printf 'dev:%s\n' "$SSH_PASSWORD" | chpasswd
if [[ -n "$ROOT_PASSWORD" ]]; then
  printf 'root:%s\n' "$ROOT_PASSWORD" | chpasswd
fi

# Optional public SSH keys: one key per line in Railway variable AUTHORIZED_KEYS.
if [[ -n "${AUTHORIZED_KEYS:-}" ]]; then
  printf '%s\n' "$AUTHORIZED_KEYS" | sed 's/\r$//' > /etc/ssh/authorized_keys.d/dev
  chown root:root /etc/ssh/authorized_keys.d/dev
  chmod 0644 /etc/ssh/authorized_keys.d/dev
else
  rm -f /etc/ssh/authorized_keys.d/dev
fi

# Optional key-only SSH mode. Browser terminal still uses SSH_PASSWORD.
case "${SSH_PASSWORD_AUTH:-yes}" in
  no|false|0|off)
    if [[ -s /etc/ssh/authorized_keys.d/dev || -s "$HOME_DIR/.ssh/authorized_keys" ]]; then
      echo 'PasswordAuthentication no' > /etc/ssh/sshd_config.d/05-password-auth.conf
    else
      echo 'devbox: SSH_PASSWORD_AUTH=no ignored because no public key was supplied.' >&2
      rm -f /etc/ssh/sshd_config.d/05-password-auth.conf
    fi
    ;;
  *) rm -f /etc/ssh/sshd_config.d/05-password-auth.conf ;;
esac

# Persist SSH host keys on the Railway volume to avoid host-key changes on redeploy.
for kind in ed25519 rsa; do
  key="$STATE_DIR/ssh_host_${kind}_key"
  if [[ ! -f "$key" ]]; then
    if [[ "$kind" == rsa ]]; then
      ssh-keygen -q -t rsa -b 3072 -N '' -f "$key"
    else
      ssh-keygen -q -t ed25519 -N '' -f "$key"
    fi
  fi
  chown root:root "$key" "$key.pub"
  chmod 0600 "$key"
  chmod 0644 "$key.pub"
done
mkdir -p /run/sshd
chmod 0755 /run/sshd

# Make Railway variables available in interactive login shells, except secrets
# used only to authenticate into the box.
PROFILE_FILE=/etc/profile.d/10-railway-env.sh
: > "$PROFILE_FILE"
while IFS= read -r -d '' entry; do
  name="${entry%%=*}"
  value="${entry#*=}"
  [[ "$name" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || continue
  case "$name" in
    SSH_PASSWORD|PASSWORD|ROOT_PASSWORD|AUTHORIZED_KEYS|HOME|PATH|PWD|OLDPWD|SHLVL|_|USER|LOGNAME|SHELL|TERM|HOSTNAME|DEBIAN_FRONTEND) continue ;;
  esac
  printf 'export %s=%q\n' "$name" "$value" >> "$PROFILE_FILE"
done < <(env -0)
chown root:dev "$PROFILE_FILE"
chmod 0640 "$PROFILE_FILE"

# Prefer tools installed into the persistent home directory (npm -g, pipx, etc.).
cat > /etc/profile.d/20-devbox.sh <<'PROFILE'
export NPM_CONFIG_PREFIX="$HOME/.npm-global"
export PATH="$HOME/.local/bin:$HOME/.npm-global/bin:/usr/local/bin:$PATH"
case "$-" in *i*) PS1='dev@Rahul:\w\$ ';; esac
PROFILE
chmod 0644 /etc/profile.d/20-devbox.sh

# Set the requested terminal label; Railway itself controls the real container hostname.
echo 'Rahul' > /etc/hostname
if ! grep -q 'dev@Rahul' "$HOME_DIR/.bashrc"; then
  printf '\ncase "$-" in *i*) PS1="dev@Rahul:\\w\\$ ";; esac\n' >> "$HOME_DIR/.bashrc"
fi
if ! grep -q 'root@Rahul' /root/.bashrc; then
  printf '\ncase "$-" in *i*) PS1="root@Rahul:\\w# ";; esac\n' >> /root/.bashrc
fi
chown dev:dev "$HOME_DIR/.bashrc"

# Optional GitHub HTTPS authentication from the GITHUB_TOKEN variable.
if [[ -n "${GITHUB_TOKEN:-}" ]]; then
  git config --system credential.https://github.com.helper \
    '!f() { printf "username=x-access-token\npassword=%s\n" "$GITHUB_TOKEN"; }; f'
fi

# Browser terminal password file (nginx sits in front of ttyd).
HASH="$(printf '%s' "$SSH_PASSWORD" | openssl passwd -6 -stdin)"
printf 'dev:%s\n' "$HASH" > /run/devbox.htpasswd
chown root:www-data /run/devbox.htpasswd
chmod 0640 /run/devbox.htpasswd

cat > /run/devbox-nginx.conf <<NGINX
user www-data;
worker_processes 1;
pid /run/devbox-nginx.pid;
error_log /dev/stderr warn;
events { worker_connections 256; }
http {
  access_log off;
  server_tokens off;
  map \$http_upgrade \$connection_upgrade { default upgrade; '' close; }
  server {
    listen 0.0.0.0:${PORT} default_server;
    server_name _;
    location = /healthz {
      proxy_pass http://127.0.0.1:${TTYD_PORT}/;
      proxy_http_version 1.1;
      proxy_set_header Host \$host;
      proxy_read_timeout 5s;
    }
    location / {
      auth_basic "Ubuntu Dev Box";
      auth_basic_user_file /run/devbox.htpasswd;
      proxy_pass http://127.0.0.1:${TTYD_PORT};
      proxy_http_version 1.1;
      proxy_set_header Upgrade \$http_upgrade;
      proxy_set_header Connection \$connection_upgrade;
      proxy_set_header Host \$host;
      proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
      proxy_read_timeout 1d;
      proxy_send_timeout 1d;
      proxy_buffering off;
    }
  }
}
NGINX
nginx -t -q -c /run/devbox-nginx.conf

# Small process supervisor: a stopped daemon is restarted without exiting the container.
supervise() {
  local name="$1"; shift
  (
    local child=''
    trap '[ -n "$child" ] && kill "$child" 2>/dev/null || true; exit 0' TERM INT
    while true; do
      "$@" &
      child=$!
      wait "$child" || status=$?
      status="${status:-0}"
      echo "devbox: $name exited (status ${status}); restarting in 2 seconds" >&2
      status=0
      sleep 2
    done
  ) &
  PIDS+=("$!")
}

run_ttyd() {
  runuser -u dev -- env HOME="$HOME_DIR" USER=dev LOGNAME=dev \
    PATH="$HOME_DIR/.local/bin:$HOME_DIR/.npm-global/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
    /usr/local/bin/ttyd -p "$TTYD_PORT" -i 127.0.0.1 -W \
      -t titleFixed='Rahul Ubuntu Dev Box' -t fontSize=14 -t disableLeaveAlert=true \
      bash -lc 'exec tmux new-session -A -s main'
}

PIDS=()
case "${DEVBOX_SSH:-on}" in
  off|no|false|0) echo 'devbox: SSH disabled by DEVBOX_SSH; browser terminal only.' ;;
  *) supervise sshd /usr/sbin/sshd -D -e ;;
esac
supervise ttyd run_ttyd
supervise nginx nginx -c /run/devbox-nginx.conf -g 'daemon off;'

echo "devbox: Ubuntu 22.04 | Python $(python3 --version) | Node $(node --version) | Claude Code installed"
echo "devbox: browser terminal listens on Railway PORT ${PORT}; /healthz is available for health checks"
if [[ "${DEVBOX_SSH:-on}" != off && "${DEVBOX_SSH:-on}" != no && "${DEVBOX_SSH:-on}" != false && "${DEVBOX_SSH:-on}" != 0 ]]; then
  echo 'devbox: SSH listens on container port 22; create a Railway TCP Proxy targeting port 22.'
fi
echo 'devbox: login user is dev; use SSH_PASSWORD (or PASSWORD) from Railway Variables. Do not share it.'
echo 'devbox: mount a Railway Volume at /home/dev to persist projects and SSH host keys.'

shutdown() {
  trap '' TERM INT
  if ((${#PIDS[@]})); then kill "${PIDS[@]}" 2>/dev/null || true; fi
  sleep 1
  if ((${#PIDS[@]})); then kill -KILL "${PIDS[@]}" 2>/dev/null || true; fi
  exit 0
}
trap shutdown TERM INT
while true; do sleep 3600 & wait $! || true; done
