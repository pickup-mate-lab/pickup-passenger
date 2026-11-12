FROM golang:1.27.4-alpine AS build
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=0 go build -trimpath -o /out/pickup-server .

FROM alpine:3.24
RUN apk add --no-cache ca-certificates tzdata && addgroup -S pickup && adduser -S -G pickup pickup && mkdir -p /data && chown pickup:pickup /data
COPY --from=build /out/pickup-server /usr/local/bin/pickup-server
USER pickup
ENV LISTEN_ADDR=127.0.0.1:8787 PICKUP_DATA_FILE=/data/pickup.db
EXPOSE 80 443
CMD ["pickup-server"]
