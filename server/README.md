# Pickle Arena online rooms

This is a **private-room relay** deployed at
`https://pickle-arena-relay.onrender.com`, with game endpoint
`wss://pickle-arena-relay.onrender.com/play`. Live health and two-client relay
checks passed on October 3, 2026. This records a successful check, not an uptime
guarantee. Both phones
connect outbound to one public WSS endpoint. The room creator's phone validates
shots and runs physics/scoring; the server pairs two players and routes their
messages. Optional Supabase integration now verifies accounts and saves completed
matches for both signed-in players. Configure it using
[the database setup guide](../supabase/SETUP.md). These changes have not yet been
deployed to the existing live relay. Use it for friend matches; it has no public
matchmaking, server-authoritative anti-cheat, or host migration.

## Run locally

From the project root, with the installed Dart SDK on PATH:

```sh
dart server/main.dart
```

The server listens on port 8080. `http://127.0.0.1:8080/health` returns JSON.
The WebSocket endpoint is `ws://127.0.0.1:8080/play`. Set `PORT` and `MAX_ROOMS`
environment variables to change the defaults (8080 and 100). There are no server
package dependencies, so no server `pub get` step is required.

A Windows executable is also built at `build/server/pickle_arena_relay.exe`.
It was smoke-tested on a temporary local port with `/health` returning status
`ok`. The Render deployment has also passed public health and WebSocket checks.

The automated suite starts real servers on ephemeral loopback ports and connects
two app session controllers. Run it with:

```sh
flutter test --no-pub test/online_test.dart
```

## Deploy with a container hosting service

### Prepared Render configuration

If the game is not in a Git repository yet, use the small server-only package
at `build/deploy/pickle-arena-online-server.zip`. Follow
[the upload instructions](RENDER_SETUP.md); the full Flutter project is not
needed on the hosting service.

The project-root [`render.yaml`](../render.yaml) defines a **free** Docker web
service in Singapore, one instance, a `/health` check, and a 20-room application
cap. Automatic code deployments are off so a source update does not immediately
interrupt matches. This is a testing configuration, not a capacity guarantee.
The schema/settings follow [Render's Blueprint reference](https://render.com/docs/blueprint-spec).

To deploy it, connect your Render account and a Git repository containing this
file and `server/`. A private repository is suitable when Render has access.
In Render, create a Blueprint from that repository and confirm that its plan
is **Free**. No service has been created by adding this file.

Render Free services sleep after 15 minutes without incoming HTTP/WebSocket
traffic and may take about a minute to wake up. They can also restart. Before a
demo, open the service's `/health` URL and wait for its `ok` response. If the app
times out while the service is waking, wait and retry. See
[Render's free-tier limits](https://render.com/docs/free). A continuously running
paid plan is an optional later choice; none is selected here.

After Render returns its real public hostname, run this from the project root:

```sh
dart tool/check_online_server.dart wss://YOUR_SERVICE.onrender.com/play
flutter build apk --release --dart-define=PICKLE_ARENA_SERVER=wss://YOUR_SERVICE.onrender.com/play
```

The first command checks the live health endpoint, pairs two WebSocket clients,
verifies messages in both directions, and closes its temporary room. Only bake
the URL into the APK after this check passes. The hostname is supplied by Render;
the service name in the YAML does not guarantee a particular public URL.

### Other container providers

1. Use a service that supports a continuously running Docker container, public
   HTTPS, and WebSocket upgrades. Deploy `server/Dockerfile` with **server/** as
   the Docker build context. If the dashboard needs a command, the image already
   has an entrypoint. The provider should pass its assigned `PORT`.
2. Set the health-check path to `/health` and use one replica. Keep the service
   running during matches; sleeping/scale-to-zero services can interrupt rooms.
3. Enable the provider's HTTPS endpoint. A domain such as
   `https://your-service.example` gives the game endpoint
   `wss://your-service.example/play`.
4. On each phone choose **VS PLAYER → Online → ENTER THE ARENA → Server
   connection** and enter that same WSS URL. One player creates a room; the
   other joins with its eight-character code. The URL is retained for the current
   app session. Room codes are never part of the URL or HTTP logs.
5. Once the server URL is fixed, bake it into your distribution build so players
   do not need to configure it:

```sh
flutter build apk --release --dart-define=PICKLE_ARENA_SERVER=wss://your-service.example/play
```

The source has no fallback endpoint. Build with the saved deployed configuration
using `flutter build apk --release --dart-define-from-file=config/online.json`
from the project root, or supply your own endpoint as shown above.

## Deploy on your own Linux server with a domain

Install Docker with Compose, point a domain's DNS to the server, and allow inbound
ports 80/443. Copy `.env.example` to `.env` inside `server/` and replace the example
domain. Then run **from server/**:

```sh
docker compose up -d --build
docker compose logs -f relay proxy
```

Caddy terminates TLS and forwards WebSocket connections to the relay's private
port 8080. Its certificates persist in Docker volumes. The public game URL is
`wss://YOUR_DOMAIN/play`; verify `https://YOUR_DOMAIN/health` before configuring
the phones. These files are prepared for deployment; they have not been deployed
or container-tested in the Windows workspace.

The image follows the official [Dart container layout](https://hub.docker.com/_/dart).
TLS setup follows [Caddy automatic HTTPS](https://caddyserver.com/docs/automatic-https)
and [WebSocket proxying](https://caddyserver.com/docs/caddyfile/directives/reverse_proxy).

## Development on two phones

For a local laptop server without TLS, make a **development-only** build:

```sh
flutter build apk --debug --dart-define=ALLOW_INSECURE_ONLINE=true --dart-define=PICKLE_ARENA_SERVER=ws://YOUR_LAPTOP_LAN_IP:8080/play
```

Allow TCP 8080 through the laptop's local firewall and keep the phones on that
network. `127.0.0.1` on a phone refers to the phone, not the laptop. Production
builds reject non-TLS public/LAN server URLs. No global TLS-validation bypass or
cleartext-permission override is enabled by these changes.

## Operational behavior

- Rooms live in one process's memory. **Use one replica**; restarting/redeploying
  ends all rooms. Scaling to multiple replicas requires shared room routing.
- Only two players fit in a room. Cryptographically random eight-character codes
  use an alphabet without I/O/0/1. Unused rooms expire after 15 minutes; active
  rooms have a two-hour maximum lifetime.
- Application heartbeats run every two seconds. Lost clients/rooms are removed;
  the app returns to the lobby. Rejoining starts a new match, not a resumed match.
- Four acknowledged snapshots can be in flight online (one for direct LAN).
  The bounded window permits 30 updates/sec at moderate round-trip latency;
  high latency can still reduce update rate and affect shot timing. Choose a
  hosting region near both players. This is not a latency-compensated competitive
  simulation.
- The relay validates message directions and input ranges; guests cannot submit
  state/score snapshots. It limits decoded messages to 16,384 characters, per-client
  traffic to 120 messages and 262,144 characters per second, and upgrade attempts
  to 60/minute per socket source address. Behind a reverse proxy that address may
  be shared by all users; enforce additional limits at the public ingress when
  scaling. Forwarded-IP headers are deliberately not trusted from clients.
- The Docker sample caps the relay at 512 MB and one CPU as a starting resource
  budget, not a load-tested capacity claim. Dart's built-in WebSocket API assembles
  messages before the application-size check; use an ingress with WebSocket
  frame/message limits and traffic controls before broad public exposure.
- Supabase is optional for guest matches and required for account records. The container runs as an unprivileged
  user. The server only logs startup; it does not log room codes or match packets.

Before your presentation, deploy the endpoint, install the configured release APK
on two phones, use **different networks** (for example home Wi-Fi and mobile data),
and play a complete match. Verify serving in both directions, pause, rematch,
backgrounding, and disconnection. Loopback tests do not establish real internet
latency, TLS hosting compatibility, device behavior, or production capacity.
