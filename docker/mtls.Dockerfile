
FROM --platform=$BUILDPLATFORM golang:latest AS build

WORKDIR /src
COPY . .
ARG TARGETOS
ARG TARGETARCH
RUN GOOS=$TARGETOS GOARCH=$TARGETARCH CGO_ENABLED=0 go build -o xray -trimpath -buildvcs=false -gcflags="all=-l=4" -ldflags "-s -w -buildid=" ./main

FROM alpine:latest

RUN apk add --no-cache bash tzdata ca-certificates openssl

RUN mkdir -p /var/log/xray /usr/share/xray /etc/xray

COPY --from=build /src/xray /usr/bin/xray

ADD https://raw.githubusercontent.com/Loyalsoldier/v2ray-rules-dat/release/geoip.dat /usr/share/xray/geoip.dat
ADD https://raw.githubusercontent.com/Loyalsoldier/v2ray-rules-dat/release/geosite.dat /usr/share/xray/geosite.dat

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

RUN touch /var/log/xray/access.log /var/log/xray/error.log

VOLUME /etc/xray
VOLUME /var/log/xray

ARG TZ=Asia/Shanghai
ENV TZ=$TZ

CMD ["/usr/bin/xray", "-config", "/etc/xray/config.json"]
