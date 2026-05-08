# janeczku/powerdns_exporter: upstream has no go.mod; without GOPATH fetching we build with pinned deps + Go 1.22.
FROM golang:1.22-alpine AS build
RUN apk add --no-cache git ca-certificates
WORKDIR /src
RUN git clone --depth 1 https://github.com/janeczku/powerdns_exporter.git .
# Local copy replaces upstream main: CounterVec + .Set never compiled with current client_golang -> use GaugeVec for API counters.
COPY go.mod powerdns_exporter.go ./
RUN go mod tidy \
    && CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /powerdns_exporter .

FROM alpine:3.20
RUN apk add --no-cache ca-certificates
COPY --from=build /powerdns_exporter /usr/local/bin/powerdns_exporter
USER nobody
EXPOSE 9120
ENTRYPOINT ["/usr/local/bin/powerdns_exporter"]
