# Publish the Pickle Arena relay

This package contains only the multiplayer server and Render configuration.
Creating the package does not publish a server. The Flutter game stays in your
existing project.

1. Extract `pickle-arena-online-server.zip`.
2. Create a GitHub repository named `pickle-arena-server`. It can be private.
   Upload the extracted **contents**, keeping `render.yaml` at the repository
   root and the Dart files and Dockerfile inside `server/`. Commit the files.
   Do not upload the ZIP itself or place everything inside an extra parent folder.
3. Sign in to Render and grant it access to that repository. Choose
   **New > Blueprint**, select the repository, and review the configuration.
   It requests one **Free** Docker web service in Singapore. Deploy it.
4. Wait for a successful deployment. Copy the actual public service URL from
   Render. Open `https://YOUR_ACTUAL_HOST/health` and wait for status `ok`.
5. Share that public URL with Codex to verify the live relay and build a game APK
   configured to use it. No password, API key, or room code is needed.

For a manual connection in the existing game, both phones can enter
`wss://YOUR_ACTUAL_HOST/play` under **VS PLAYER > Online > Server connection**.
One player creates a room and shares its code with the other player.

Free services sleep after 15 minutes without incoming HTTP or WebSocket traffic
and may take about a minute to wake up. Open `/health` before a demo; if the app
times out during startup, wait and retry. Restarting the service ends its rooms.
See https://render.com/docs/free and https://render.com/docs/blueprint-spec.

This is a private-room relay for friend matches. It does not provide public
matchmaking or accounts. Test a complete match on two phones on different
networks before relying on it for a presentation.
