# syntax=docker/dockerfile:latest

# Build stage - compile xray-core from source
FROM --platform=$BUILDPLATFORM golang:latest AS build

WORKDIR /src
COPY . .
ARG TARGETOS
ARG TARGETARCH
RUN GOOS=$TARGETOS GOARCH=$TARGETARCH CGO_ENABLED=0 go build -o xray -trimpath -buildvcs=false -gcflags="all=-l=4" -ldflags "-s -w -buildid=" ./main

# Runtime stage - Alpine-based image
FROM alpine:latest

# Install runtime dependencies
RUN apk add --no-cache bash tzdata ca-certificates openssl

# Create directories
RUN mkdir -p /var/log/xray /usr/share/xray /etc/xray

# Copy binary from build stage
COPY --from=build /src/xray /usr/bin/xray

# Download geodata
ADD https://raw.githubusercontent.com/Loyalsoldier/v2ray-rules-dat/release/geoip.dat /usr/share/xray/geoip.dat
ADD https://raw.githubusercontent.com/Loyalsoldier/v2ray-rules-dat/release/geosite.dat /usr/share/xray/geosite.dat

# Create default config file (single JSON, teddysun style)
RUN cat <<'EOF' > /etc/xray/config.json
{
  "log": {
    "error": "/var/log/xray/error.log",
    "loglevel": "warning"
  },
  "inbounds": [],
  "outbounds": [
    {
      "protocol": "freedom",
      "settings": {}
    }
  ]
}
EOF

# Create log files
RUN touch /var/log/xray/access.log /var/log/xray/error.log

VOLUME /etc/xray
VOLUME /var/log/xray

ARG TZ=Asia/Shanghai
ENV TZ=$TZ

ENTRYPOINT ["/usr/bin/xray"]
CMD ["-config", "/etc/xray/config.json"]
