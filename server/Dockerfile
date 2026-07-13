FROM golang:1.24.13-alpine3.22 AS build

WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=0 GOOS=linux go build \
    -trimpath \
    -ldflags="-s -w" \
    -o /out/signaling-server \
    ./cmd/signaling-server

FROM gcr.io/distroless/static-debian12:nonroot@sha256:b7bb25d9f7c31d2bdd1982feb4dafcaf137703c7075dbe2febb41c24212b946f

COPY --from=build /out/signaling-server /signaling-server
USER nonroot:nonroot
EXPOSE 8080
ENTRYPOINT ["/signaling-server"]
