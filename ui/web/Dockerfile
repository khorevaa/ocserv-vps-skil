ARG BUILD_IMAGE=golang:1.26.5-alpine@sha256:0178a641fbb4858c5f1b48e34bdaabe0350a330a1b1149aabd498d0699ff5fb2
FROM ${BUILD_IMAGE} AS build

ARG UI_VERSION
WORKDIR /src
COPY go.mod ./
COPY *.go ./
COPY app/static ./app/static
RUN go test ./... \
    && CGO_ENABLED=0 GOOS=linux go build \
      -trimpath \
      -ldflags="-s -w -buildid= -X main.version=${UI_VERSION}" \
      -o /out/ocserv-ui . \
    && mkdir -p /out/data

FROM scratch

ARG BUILD_IMAGE
ARG UI_VERSION

LABEL org.opencontainers.image.title="ocserv-vps-ui" \
      org.opencontainers.image.description="Go web management UI for the Dockerized ocserv VPS" \
      org.opencontainers.image.source="https://github.com/khorevaa/ocserv-vps-skil" \
      org.opencontainers.image.licenses="GPL-2.0-or-later" \
      org.opencontainers.image.version="${UI_VERSION}" \
      org.opencontainers.image.base.name="${BUILD_IMAGE}" \
      org.ocserv-vps.component="ui"

ENV OCSERV_UI_JSON=/var/lib/ocserv-ui/state.json \
    OCSERV_UI_CONTROL_SOCKET=/run/ocserv-ui/control.sock \
    OCSERV_UI_WEB_SOCKET=/run/ocserv-ui-web/web.sock

COPY --from=build /out/ocserv-ui /usr/local/bin/ocserv-ui
COPY --from=build --chown=10001:10001 /out/data /var/lib/ocserv-ui

USER 10001:10001

HEALTHCHECK --interval=30s --timeout=3s --start-period=10s --retries=3 \
  CMD ["/usr/local/bin/ocserv-ui", "healthcheck"]

ENTRYPOINT ["/usr/local/bin/ocserv-ui"]
