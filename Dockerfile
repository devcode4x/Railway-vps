# Ubuntu 22.04 development box for Railway
# SSH (Termius) + browser terminal + persistent /home/dev
# Ngrok intentionally not included.

FROM ubuntu:22.04

ARG DEBIAN_FRONTEND=noninteractive
ARG TTYD_VERSION=1.7.7
ARG TTYD_SHA256=8a217c968aba172e0dbf3f34447218dc015bc4d5e59bf51db2f2cd12b7be4f55

ENV DEBIAN_FRONTEND=noninteractive \
    TZ=Asia/Kolkata \
    LANG=C.UTF-8 \
    LC_ALL=C.UTF-8 \
    TERM=xterm-256color \
    DISABLE_AUTOUPDATER=1

# Base utilities, SSH, Python 3.12 from deadsnakes, and development tools.
RUN apt-get update && apt-get install -y --no-install-recommends \
      apt-utils ca-certificates curl wget gnupg2 lsb-release tzdata \
      openssh-server openssh-client sudo nano vim less htop jq ripgrep tree \
      file rsync unzip zip xz-utils git git-lfs build-essential pkg-config \
      software-properties-common \
      tmux nginx-light openssl iproute2 iputils-ping dnsutils net-tools \
      procps util-linux locales \
    && ln -snf "/usr/share/zoneinfo/${TZ}" /etc/localtime \
    && echo "${TZ}" > /etc/timezone \
    && dpkg-reconfigure -f noninteractive tzdata \
    && add-apt-repository ppa:deadsnakes/ppa -y \
    && apt-get update \
    && apt-get install -y --no-install-recommends python3.12 python3.12-venv python3.12-dev \
    && ln -sf /usr/bin/python3.12 /usr/local/bin/python3 \
    && ln -sf /usr/bin/python3.12 /usr/local/bin/python \
    && rm -rf /var/lib/apt/lists/*

# Node.js 24 LTS (NodeSource) and GitHub CLI (official apt repository).
RUN curl -fsSL https://deb.nodesource.com/setup_24.x | bash - \
    && install -d -m 0755 /etc/apt/keyrings \
    && curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
       -o /etc/apt/keyrings/githubcli-archive-keyring.gpg \
    && chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
       > /etc/apt/sources.list.d/github-cli.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends nodejs gh \
    && npm install --global @anthropic-ai/claude-code \
    && npm cache clean --force \
    && node --version && npm --version && gh --version && claude --version \
    && rm -rf /var/lib/apt/lists/*

# ttyd provides the optional browser terminal. Verify the downloaded binary.
RUN curl -fsSLo /usr/local/bin/ttyd \
      "https://github.com/tsl0922/ttyd/releases/download/${TTYD_VERSION}/ttyd.x86_64" \
    && echo "${TTYD_SHA256}  /usr/local/bin/ttyd" | sha256sum -c - \
    && chmod 0755 /usr/local/bin/ttyd

# Create a non-root SSH user. Use sudo for administration; direct root SSH is off.
RUN useradd --uid 1000 --user-group --create-home --shell /bin/bash dev \
    && echo 'dev ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/dev \
    && chmod 0440 /etc/sudoers.d/dev \
    && mkdir -p /run/sshd /etc/ssh/authorized_keys.d /etc/ssh/sshd_config.d \
    && printf '\ncase "$-" in *i*) PS1="dev@Rahul:\\w\\$ ";; esac\n' >> /home/dev/.bashrc \
    && chown dev:dev /home/dev \
    && rm -f /etc/nginx/sites-enabled/default

# SSH hardening and per-source login throttling (no root login).
COPY sshd_config /etc/ssh/sshd_config.d/10-railway-devbox.conf
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod 0755 /usr/local/bin/entrypoint.sh \
    && chmod 0644 /etc/ssh/sshd_config.d/10-railway-devbox.conf

EXPOSE 22 8080

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
