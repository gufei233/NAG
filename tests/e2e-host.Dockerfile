FROM ghcr.io/astral-sh/uv:0.9.29-python3.12-bookworm-slim

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update \
  && apt-get install --no-install-recommends -y \
    ca-certificates \
    curl \
    docker.io \
    git \
    jq \
    openssl \
    sudo \
    systemd \
    systemd-sysv \
  && rm -rf /var/lib/apt/lists/*

ARG COMPOSE_VERSION=v2.40.3
RUN install -d -m 0755 /usr/local/lib/docker/cli-plugins \
  && curl -fL \
    "https://github.com/docker/compose/releases/download/${COMPOSE_VERSION}/docker-compose-linux-x86_64" \
    -o /usr/local/lib/docker/cli-plugins/docker-compose \
  && chmod 0755 /usr/local/lib/docker/cli-plugins/docker-compose

RUN systemctl enable docker.service

STOPSIGNAL SIGRTMIN+3

CMD ["/sbin/init"]
