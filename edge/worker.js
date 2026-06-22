// sxgate mail edge — Cloudflare Email Worker (inbound).
//
// Cloudflare Email Routing receives mail for the zone at Cloudflare's edge (port 25, MX
// managed by Email Routing) and invokes this Worker. We forward the raw RFC 822 message,
// plus the envelope, to maild's HTTPS webhook *through the existing Cloudflare Tunnel* —
// the only way inbound internet mail can reach a tunnel-only host. maild parses the MIME
// and delivers into the recipient's Maildir.
//
// Bindings (set by `sxgate mail setup` → wrangler.toml + `wrangler secret put`):
//   env.MAILD_WEBHOOK   — https://<host>/api/services/mail/inbound   (a [vars] entry)
//   env.INBOUND_SECRET  — shared secret, equals /etc/holistic/mail-inbound-secret (a secret)

export default {
  async email(message, env, ctx) {
    const raw = await new Response(message.raw).arrayBuffer();
    let resp;
    try {
      resp = await fetch(env.MAILD_WEBHOOK, {
        method: 'POST',
        headers: {
          'Content-Type': 'message/rfc822',
          'X-Mail-Inbound-Secret': env.INBOUND_SECRET,
          'X-Mail-Rcpt': message.to,
          'X-Mail-From': message.from,
        },
        body: raw,
      });
    } catch (e) {
      // Temporary failure → tell Cloudflare to retry/queue rather than drop.
      message.setReject(`maild webhook unreachable: ${e}`);
      return;
    }
    if (!resp.ok) {
      message.setReject(`maild webhook returned ${resp.status}`);
    }
  },
};
