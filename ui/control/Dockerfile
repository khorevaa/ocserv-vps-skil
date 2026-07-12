ARG BUILD_IMAGE=golang:1.26.5-alpine@sha256:0178a641fbb4858c5f1b48e34bdaabe0350a330a1b1149aabd498d0699ff5fb2
ARG OCSERV_IMAGE=ghcr.io/khorevaa/ocserv-vps:1.5.0
FROM ${BUILD_IMAGE} AS build

WORKDIR /src
COPY go.mod ./
COPY *.go ./
RUN CGO_ENABLED=0 GOOS=linux GOARCH=amd64 \
    go build -trimpath -ldflags='-s -w' -o /out/ocserv-control .

FROM ${OCSERV_IMAGE} AS ocserv-tools

RUN set -eux; \
    install -d /runtime/usr/local/bin; \
    cp /usr/local/bin/occtl /usr/local/bin/ocpasswd /runtime/usr/local/bin/; \
    { \
      ldd /usr/local/bin/occtl; \
      ldd /usr/local/bin/ocpasswd; \
    } | awk '$2 == "=>" && $3 ~ /^\// {print $3} $1 ~ /^\// {print $1}' \
      | sort -u \
      | while IFS= read -r library; do \
          install -d "/runtime$(dirname "${library}")"; \
          cp -L "${library}" "/runtime${library}"; \
        done

FROM scratch

ARG BUILD_IMAGE
ARG OCSERV_IMAGE
ARG UI_VERSION

LABEL org.opencontainers.image.title="ocserv-vps-ui-control" \
      org.opencontainers.image.description="Minimal Go control sidecar for the ocserv VPS UI" \
      org.opencontainers.image.source="https://github.com/khorevaa/ocserv-vps-skil" \
      org.opencontainers.image.licenses="GPL-2.0-or-later" \
      org.opencontainers.image.version="${UI_VERSION}" \
      org.opencontainers.image.base.name="scratch" \
      org.ocserv-vps.build-image="${BUILD_IMAGE}" \
      org.ocserv-vps.ocserv-image="${OCSERV_IMAGE}" \
      org.ocserv-vps.component="control"

COPY --from=ocserv-tools /runtime /
COPY --from=build --chmod=0755 /out/ocserv-control /usr/local/bin/ocserv-control

STOPSIGNAL SIGTERM
HEALTHCHECK --interval=10s --timeout=3s --retries=6 --start-period=20s \
    CMD ["/usr/local/bin/ocserv-control", "healthcheck"]

ENTRYPOINT ["/usr/local/bin/ocserv-control"]
CMD ["serve"]
