FROM golang:1.22-alpine AS build
WORKDIR /src
COPY go.mod ./
RUN go mod download
COPY . ./
RUN go build -o /out/participant-mock ./main.go

FROM alpine:3.19
WORKDIR /app
COPY --from=build /out/participant-mock ./participant-mock
EXPOSE 8081
ENV PORT=8081
ENV PROVIDER_URL=http://mock-provider:8080
CMD ["/app/participant-mock"]
