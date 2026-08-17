# relay (dsh-mobile 中继) — 多阶段构建：golang 构建 + alpine 运行
# 用法（在 mobile/relay 目录）:
#   docker build -f deploy/Dockerfile -t dsh-relay .
#   docker run -d -p 8443:8443 --name dsh-relay dsh-relay
# 生产建议: 由 Caddy (deploy/Caddyfile) 或 cloudflared 提供 TLS/WSS。
#
# 国内网络拉取 Docker Hub 超时, 用镜像源覆盖基础镜像:
#   docker build -f deploy/Dockerfile \
#     --build-arg GO_IMAGE=m.daocloud.io/library/golang:1.26-alpine \
#     --build-arg RUN_IMAGE=m.daocloud.io/library/alpine:3.21 \
#     -t dsh-relay .

# syntax=docker/dockerfile:1
ARG GO_IMAGE=golang:1.26-alpine
ARG RUN_IMAGE=alpine:3.21
FROM ${GO_IMAGE} AS build
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY main.go ./
COPY store ./store
# CGO_ENABLED=0 -> 纯静态二进制，可在任意 Linux 上运行（含 scratch/distroless）
RUN CGO_ENABLED=0 GOOS=linux go build -trimpath -ldflags="-s -w" -o /relay .

FROM ${RUN_IMAGE}
RUN adduser -D -u 10001 relay
USER relay
COPY --from=build /relay /usr/local/bin/relay
EXPOSE 8443
# /healthz、/relay/healthz 由 main.go 提供（容器内直连用 /healthz）；alpine wget 来自 busybox
HEALTHCHECK --interval=30s --timeout=3s --start-period=5s \
  CMD wget -qO- http://127.0.0.1:8443/healthz >/dev/null || exit 1
ENTRYPOINT ["relay"]
