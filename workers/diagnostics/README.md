# Diagnostic report relay

The app sends the preview over HTTPS after the user taps **Send report**. The Worker creates a ZIP containing only `diagnostics.txt` and sends it to one configured Telegram chat. It rejects malformed and oversized reports and applies per-sender and per-location limits. The chat and bot credentials stay in Worker secrets.

1. In Telegram, use BotFather to revoke any exposed token and create a new one. Set up the destination chat with the bot. For a private chat, send the bot a message first. Use the destination's chat ID, which differs from the bot ID.
2. With Wrangler authenticated to your Cloudflare account, run the following from this directory. Enter the token and chat ID at the prompts and keep both out of the repository.

   ```sh
   npm ci
   npx wrangler deploy
   npx wrangler secret put TELEGRAM_BOT_TOKEN
   npx wrangler secret put TELEGRAM_CHAT_ID
   ```

3. Add the deployed HTTPS URL ending in `/report` as the GitHub Actions repository variable `NEUROMESH_REPORT_ENDPOINT`. For a local app build, pass `--dart-define=NEUROMESH_REPORT_ENDPOINT=https://YOUR-WORKER.workers.dev/report`. This URL is public configuration. The credentials remain in Cloudflare.
4. Submit a test report and check that the ZIP arrives in the intended chat before distributing the build.
