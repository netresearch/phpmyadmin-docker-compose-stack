# Using only the image

The compose stack in this repository is one way to run phpMyAdmin, not the only
one. Consumers that already operate a web server — a TYPO3 stack behind Traefik,
say — take the image and keep their own routing. This is how netresearch.de
uses it.

## What the image provides

php-fpm on port 9000, the phpMyAdmin tree under `/var/www/html`, and an
entrypoint that writes `config.inc.php` from the environment. It runs as
`www-data` (uid 82) and needs no privileges.

It deliberately contains no web server. Something has to answer HTTP and serve
phpMyAdmin's static files; routing every asset through php-fpm would work but
wastes a PHP worker per image.

## The one thing that is easy to get wrong

The web server needs the same file tree php-fpm has, because it resolves
`SCRIPT_FILENAME` against its own filesystem. Mounting an empty named volume
into both containers looks like the obvious answer and is a trap: Docker seeds
such a volume from the image **once**, at creation. After an image update the
volume still holds the old release, and nothing tells you.

The `app-assets` service in `compose.yml` solves it by copying the tree into
the shared volume on every start, swapping entry by entry so a request arriving
mid-sync sees either the old or the new file. Copy that service, or build the
static files into your web image.

## A minimal consumer

```yaml
services:
  pma-assets:
    image: ghcr.io/netresearch/phpmyadmin-php-fpm:latest
    entrypoint: ["/bin/bash", "-c"]
    command:
      - |
        set -eu
        STAGE=/shared-html/.new
        rm -rf "$$STAGE"; mkdir -p "$$STAGE"
        find /var/www/html -mindepth 1 -maxdepth 1 ! -name tmp \
          -exec cp -a {} "$$STAGE"/ \;
        for entry in "$$STAGE"/* "$$STAGE"/.[!.]*; do
          [ -e "$$entry" ] || continue
          name=$$(basename "$$entry")
          rm -rf "/shared-html/$$name"; mv "$$entry" "/shared-html/$$name"
        done
        rm -rf "$$STAGE"
    volumes:
      - pma-html:/shared-html
    restart: "no"

  pma:
    image: ghcr.io/netresearch/phpmyadmin-php-fpm:latest
    environment:
      PMA_HOST: db
      PMA_ABSOLUTE_URI: https://pma.example.org/
      PMA_BLOWFISH_SECRET: ${PMA_BLOWFISH_SECRET}
    volumes:
      - pma-tmp:/var/www/html/tmp
    restart: unless-stopped

  pma-web:
    image: nginx:1.29-alpine
    depends_on:
      pma-assets: { condition: service_completed_successfully }
      pma: { condition: service_healthy }
    environment:
      PMA_FPM_UPSTREAM: pma:9000
    volumes:
      - ./config/nginx/nginx.conf:/etc/nginx/nginx.conf:ro
      - ./config/nginx/templates:/etc/nginx/templates:ro
      - ./config/nginx/snippets:/etc/nginx/snippets:ro
      - pma-html:/var/www/html:ro
    restart: unless-stopped

volumes:
  pma-tmp:
  pma-html:
```

Take `config/nginx/` from this repository as it is; `PMA_FPM_UPSTREAM` is the
only value in it that changes per deployment.

## Coming from the upstream single-container image

The environment variables carry over: `PMA_HOST`, `PMA_PORT`,
`PMA_ABSOLUTE_URI`, `PMA_ARBITRARY`, `UPLOAD_LIMIT`, `MEMORY_LIMIT`,
`MAX_EXECUTION_TIME` all mean what they meant. Two differences to plan for:

- The upstream image serves HTTP itself on port 80. This one does not, so the
  proxy in front of it points at the new web container rather than at the app.
- `PMA_BLOWFISH_SECRET` was optional there and is worth setting here: without
  it sessions live and die with the `tmp` volume.
