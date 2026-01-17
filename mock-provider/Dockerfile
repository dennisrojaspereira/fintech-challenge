FROM golang:1.22-alpine AS build
WORKDIR /src
COPY go.mod ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=0 go build -o /mock-provider ./

FROM alpine:3.20
WORKDIR /
COPY --from=build /mock-provider /mock-provider
EXPOSE 8080
ENTRYPOINT ["/mock-provider"]
