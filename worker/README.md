# The sync relay

GitHub tells the relay of each push to a graph's repository. The relay then tells every device that keeps that graph:

- **iPhones** get a silent push through APNs, which wakes Prism to sync, even in the background.
- **Macs** listen on a WebSocket. Prism Mac holds one open while it keeps its own clone.

So another device's writing comes in within seconds, not when the app is next opened. Devices prove they may hear about a repository with their GitHub token. The relay checks it with GitHub and never stores it. It stores only the iPhones' push tokens, per repository.

## Pieces

- `src/index.ts`: the routes.
  - `POST /github`: GitHub's webhook.
  - `POST` and `DELETE /devices`: an iPhone registering or unregistering.
  - `GET /events`: a Mac's WebSocket.
- `src/hub.ts`: one Durable Object per repository. It holds the push tokens and the open sockets.
- `src/crypto.ts`: checks webhook signatures and signs the APNs token.

## Setting it up

1. **Install the tools.** You need [Node](https://nodejs.org), for example `brew install node`. Then:

   ```sh
   cd worker
   npm install
   npm test && npm run check
   ```

2. **Deploy:**

   ```sh
   npx wrangler login
   npx wrangler deploy
   ```

   Note the host it prints, for example `reflect-sync-relay.<account>.workers.dev`.

3. **Webhook secret.** Make one with `openssl rand -hex 32`, then:

   ```sh
   npx wrangler secret put GITHUB_WEBHOOK_SECRET
   ```

4. **GitHub App** (github.com → Settings → Developer settings → GitHub Apps → the app):
   - Under **Webhook**, tick *Active*.
   - Set the URL to `https://<host>/github` and the secret to the one from step 3.
   - Under **Permissions & events → Subscribe to events**, tick **Push**. Repository *Contents* access is already granted for syncing.

5. **APNs key** (developer.apple.com → Certificates, IDs & Profiles → Keys → +):
   - Enable *Apple Push Notifications service (APNs)* and download the `.p8` file.
   - Then:

     ```sh
     npx wrangler secret put APNS_KEY < AuthKey_XXXXXXXXXX.p8
     npx wrangler secret put APNS_KEY_ID      # the key's ID
     npx wrangler secret put APNS_TEAM_ID     # G3V66M4637
     ```

6. **The apps.** Put the host in `iOS/GitHub.local.xcconfig`:

   ```
   SYNC_RELAY_HOST = reflect-sync-relay.<account>.workers.dev
   ```

   Then rebuild:
   - **iPhone:** build from Xcode. Automatic signing adds the push capability to the App ID.
   - **Mac:** `scripts/build-prism.sh`.

7. **Check.** Write on one device. In the GitHub App's settings, under **Advanced → Recent Deliveries**, the push should show a `200` with `{"listening": …, "pushed": …}`.
   - `listening` counts the Macs told.
   - `pushed` counts the iPhones told.

`wrangler dev` cannot reach APNs from a Mac (workerd#4841). Deployed, it can.
