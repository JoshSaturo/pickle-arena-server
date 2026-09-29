FROM dart:stable AS build
WORKDIR /app
COPY relay.dart main.dart ./
RUN dart compile exe main.dart -o /app/relay

FROM scratch
COPY --from=build /runtime/ /
COPY --from=build /app/relay /app/relay
USER 65532:65532
ENV PORT=8080
EXPOSE 8080
ENTRYPOINT ["/app/relay"]
