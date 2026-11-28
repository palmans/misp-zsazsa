# Upstream sources

These folders are copies of their upstream repositories, written by
`scripts/update-upstream.sh`, with the patches in `deploy/patches/<folder>/`
applied. Changes made in them are lost on the next update: deployment-specific
changes belong in `deploy/`.

| Folder | Repository | Commit | Date |
|---|---|---|---|
| `misp-docker/` | https://github.com/MISP/misp-docker | `d9e2dd1a07ec` | 2026-11-26 |
| `misp-scraper/` | https://github.com/cudeso/misp-scraper | `0405808fb5dd` | 2026-11-18 |
| `zsazsa/` | https://github.com/zsazsa-project/zsazsa | `2d3729774f51` | 2026-11-26 |

