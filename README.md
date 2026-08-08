# phpMyAdmin Docker Compose Stack

phpMyAdmin as a php-fpm image plus the nginx in front of it, rebuilt daily so
the base underneath the application stays current.

## Why this exists

The upstream `phpmyadmin/phpmyadmin` image is rebuilt when phpMyAdmin itself is
released, not when its base picks up fixes. Measured on 2026-08-08, with
`trivy` against the published images:

| image | size | findings | **with a fix** | **CRITICAL+HIGH with a fix** |
|---|---:|---:|---:|---:|
| `phpmyadmin/phpmyadmin:5.2.3` (built 2025-10-08) | 708 MB | 4623 | 3396 | 562 |
| `phpmyadmin-php-fpm` (pinned) | 157 MB | 18 | 18 | 10 |
| `phpmyadmin-php-fpm` (rolling) | 157 MB | **0** | **0** | **0** |

The application code is the same in all three. What differs is the age of the
Debian base — and, for the rolling variant, of phpMyAdmin's own bundled PHP
libraries. `:latest` upstream is byte-identical to `:5.2.3`, so waiting for an
upstream rebuild is not a plan.

## Two variants

**Pinned** (default) ships the libraries exactly as the phpMyAdmin release did.
Reproducible, and identical to upstream in everything but the base image.

**Rolling** (`ROLLING_DEPS=true`) refreshes those libraries within the
constraints phpMyAdmin's own `composer.json` declares — `twig/twig` moves from
the released 3.11.3 to 3.28.0, for instance. That is where the last 18 findings
go. It is a deliberate deviation from the released tarball, so it is opt-in.

## Quick start

```bash
cp .env.example .env          # set MARIADB_ROOT_PASSWORD for the demo database
make up                       # app + web + a MariaDB to look at
```

phpMyAdmin then answers on <http://localhost:8080>.

Against a database you already run, leave the demo out and point at it:

```bash
PMA_HOST=your-db-host docker compose up -d app-assets app web
```

## Using only the image

The image is useful on its own to anyone who already runs a web server — this
is how the netresearch.de stack consumes it. php-fpm listens on 9000; the web
server needs the application tree to serve static files, which `app-assets`
copies into a shared volume on every start. See
[docs/using-the-image-standalone.md](docs/using-the-image-standalone.md).

## Configuration

Everything is environment-driven and the variable names match the upstream
image, so an existing deployment can switch without rewriting its environment.
`.env.example` documents each one. Two are worth calling out:

- `PMA_BLOWFISH_SECRET` — exactly 32 characters, encrypts the auth cookie.
  Without it the container generates one into its `tmp` volume and warns; lose
  that volume and everyone is logged out.
- `PMA_ABSOLUTE_URI` — needed when phpMyAdmin is served under a path or a
  public hostname the container itself never sees.

A `config.inc.php` you mount yourself is left alone; one this image generated
is rewritten on each start, so a changed environment takes effect.

## What the image does not contain

`setup/`, `examples/` and `test/` are removed. The setup wizard writes
configuration through the browser, which in a container is both pointless — the
configuration comes from the environment — and a way in.

`/ping` and `/status` are php-fpm's own endpoints. The shipped nginx config
answers them on loopback only: in Docker every request through a published port
arrives from the bridge gateway, so allowing "the private ranges" would publish
them to anyone who can reach the port.

## Maintenance

`make lint` runs hadolint and a compose validation, `make test` builds and runs
the container-structure tests, `make scan` runs trivy against the built image.
The daily CI rebuild is what keeps the promise in the table above true;
Renovate bumps the base versions and the release pin.

## Licence

MIT for everything in this repository (see `LICENSE-MIT`), documentation under
CC-BY-SA-4.0. phpMyAdmin itself is GPL-2.0-only and is downloaded at build
time, not vendored here.
