# Shared links

A shared link shows photos, or an album as it is when the link is opened, as a simple web page
to people without Halden. You make links in the app (a photo's share menu, the chosen photos in
the library, an album's menu) and see and withdraw them in Settings › Shared links.

What a link shows:

- previews (JPEG, about 2048 px, **without the place**) and videos as their small copy;
- the originals (full size, **with the place**) only when the link allows it;
- nothing else of the server: the page has its own listener that knows only `/s/<link>`.

A link can end after a time and can have a password (tried wrongly, it waits after ten tries;
every wrong try is in the security log). Withdrawn or ended, it says so.

Edits made in Halden are not shown on the page yet (the server keeps an edit as what was set;
the apps apply it).

## Putting the page on the internet

The server shows the page on `share.listen` (default `127.0.0.1:47131`, plain HTTP, only on this
computer). Something on the same computer that has a real certificate passes requests from the
internet on to it. Pick one:

### Tailscale Funnel (the easiest)

If the server is in your tailnet already:

```sh
sudo tailscale funnel --bg 47131
tailscale funnel status          # shows the address, e.g. https://aurelia.tail1234.ts.net
```

Then tell Halden that address and turn the links on:

```sh
sudo halden config set share.public_url https://aurelia.tail1234.ts.net
sudo halden config set share.enabled true
```

Funnel publishes only that one port; the server's own port (for the apps) stays private.

### Cloudflare Tunnel

With a domain at Cloudflare: create a tunnel (`cloudflared tunnel create halden`) and route a
host name to `http://127.0.0.1:47131`, for example `photos.example.com`. Then
`share.public_url = https://photos.example.com` and `share.enabled = true`.

### Caddy with your own domain

With the domain pointing at your router and ports 80/443 forwarded to the server:

```
photos.example.com {
    reverse_proxy 127.0.0.1:47131
}
```

Caddy gets the certificate by itself. Then set `share.public_url` and `share.enabled` as above.

## Settings

| Setting | Default | |
|---|---|---|
| `share.enabled` | `false` | Links can be opened (the page is served) |
| `share.listen` | `127.0.0.1:47131` | Where the page is served, for the tunnel or proxy |
| `share.public_url` | empty | The address people open; links get it in front of `/s/…` |

Without `share.public_url` links can still be made; they get their address once it is set.
All three need the owner's password when changed from the app.
