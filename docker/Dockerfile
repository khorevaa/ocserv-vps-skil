ARG BASE_IMAGE
FROM ${BASE_IMAGE}

ARG BASE_IMAGE
ARG OCSERV_VERSION
ARG SOURCE_SHA256

LABEL org.opencontainers.image.title="ocserv-vps" \
      org.opencontainers.image.description="Dockerized ocserv built from a verified upstream source release" \
      org.opencontainers.image.source="https://github.com/khorevaa/ocserv-vps-skil" \
      org.opencontainers.image.licenses="GPL-2.0-or-later" \
      org.opencontainers.image.version="${OCSERV_VERSION}" \
      org.opencontainers.image.base.name="${BASE_IMAGE}" \
      org.ocserv-vps.source-sha256="${SOURCE_SHA256}"

ENV DEBIAN_FRONTEND=noninteractive

RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
      ca-certificates build-essential pkg-config meson ninja-build \
      autoconf automake libtool gettext gperf \
      libgnutls28-dev libev-dev libpam0g-dev liblz4-dev libseccomp-dev \
      libreadline-dev libnl-route-3-dev libprotobuf-c-dev protobuf-c-compiler \
      libtalloc-dev iproute2 iptables openssl tini; \
    for package in \
      autopoint libllhttp-dev libhttp-parser-dev liboath-dev libkrb5-dev \
      libradcli-dev libsystemd-dev libmaxminddb-dev libpcre2-dev libwrap0-dev; do \
      if apt-cache show "${package}" >/dev/null 2>&1; then \
        apt-get install -y --no-install-recommends "${package}"; \
      fi; \
    done; \
    rm -rf /var/lib/apt/lists/*

COPY source /usr/src/ocserv
COPY entrypoint.sh /usr/local/sbin/ocserv-container-entrypoint

RUN set -eux; \
    cd /usr/src/ocserv; \
    if [ -f meson.build ]; then \
      meson setup /tmp/ocserv-build . --prefix=/usr/local --buildtype=release --wrap-mode=nodownload; \
      meson compile -C /tmp/ocserv-build; \
      meson install -C /tmp/ocserv-build --no-rebuild; \
    else \
      if [ ! -x ./configure ]; then autoreconf -fiv; fi; \
      mkdir -p /tmp/ocserv-build; \
      cd /tmp/ocserv-build; \
      /usr/src/ocserv/configure --prefix=/usr/local; \
      make -j"$(nproc)"; \
      make install; \
    fi; \
    getent group ocserv >/dev/null || groupadd --system ocserv; \
    id -u ocserv >/dev/null 2>&1 || useradd --system --gid ocserv --home-dir /nonexistent --shell /usr/sbin/nologin ocserv; \
    install -d -m 0750 -o root -g ocserv /etc/ocserv /run/ocserv; \
    chmod 0755 /usr/local/sbin/ocserv-container-entrypoint; \
    /usr/local/sbin/ocserv --version; \
    install -d -m 0755 /usr/share/licenses/ocserv; \
    if [ -f /usr/src/ocserv/COPYING ]; then cp /usr/src/ocserv/COPYING /usr/share/licenses/ocserv/COPYING; fi; \
    rm -rf /tmp/ocserv-build

ENTRYPOINT ["/usr/bin/tini", "-g", "--"]
CMD ["/usr/local/sbin/ocserv-container-entrypoint"]
