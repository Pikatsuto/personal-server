# personal-server

> **Personal dotfiles for my home lab server, built as an AlmaLinux bootc image.**
>
> This repo is the source of truth for the OS image that runs on my home
> server. It is opinionated, tailored to what I personally run, and **not
> intended as a turnkey distribution**. It is, however, designed to be a
> complete and readable base for anyone who wants to build their own
> variant — the architecture is fully generic, every service is
> self-contained, and the build pipeline adapts to whatever services you
> drop into `services/`.
>
> **Fork it, strip the services you don't want, add yours, and you have your
> own home-lab OS image in under an hour.**

## What's inside

An immutable [bootc](https://containers.github.io/bootc/) container image
based on [`quay.io/almalinuxorg/almalinux-bootc:9`](https://quay.io/repository/almalinuxorg/almalinux-bootc)
that ships the following stack, installed and wired together at build time:

| Service | Role | Install method |
|---|---|---|
| **ZFS** (kmod) | storage backend for the pools the home server runs on | `dnf` via `zfsonlinux` EL9 kmod repo |
| **WebZFS** | web UI to manage pools/datasets/snapshots post-install | native Python/FastAPI from upstream `install_linux.sh` |
| **Incus** | LXC + KVM hypervisor | COPR `neelc/incus` + `incus-ui-canonical` extracted from the Zabbly `.deb` |
| **Docker Engine** | OCI runtime for everything else | upstream `docker-ce.repo` on Rocky/Alma |
| **Arcane** | web UI for Docker | container, network `coolify` |
| **Watchtower** | auto-updates containers every Friday 04:00 | systemd timer running a one-shot `docker run` |
| **Pangolin** + **Gerbil** + **Traefik v3.6** | WireGuard VPN + identity-aware reverse proxy + ACME wildcard | compose stack rendered from upstream `fosrl/pangolin` templates |
| **PocketID** | OIDC identity provider (passkeys), wired into Pangolin | container, network `coolify` |
| **Coolify** | self-hosted PaaS, with its bundled Traefik disabled and its deployed apps routed by the Pangolin Traefik via the shared `coolify` Docker network | upstream installer with `ROOT_USER_*` env pre-fill |

Plus housekeeping baked into the image:

- `personal-server-reboot.timer` — full reboot every Sunday 04:00
- `personal-server-firstboot.service` — interactive wizard on `tty1` on the first boot, asks for the domain + DNS provider + optional ZFS pools, then runs every service's `configure.sh` and writes `/etc/personal-server/first-boot-checklist.txt` with the handful of one-time UI clicks the upstream projects can't skip (Pangolin admin, PocketID admin, Coolify `Proxy → None`, OIDC client wiring).
- `/usr/local/bin/personal-server` — runtime CLI (`status`, `list`, `move <svc> <pool>`, `reconfigure`, `build-report`)
- `/usr/local/bin/move-service-storage` — generic ZFS migration tool that moves any service's `data_path` to a different pool, lossless, reusable at any point in the server's life.

Everything past the first-boot wizard is idempotent and the wizard can be
re-run at any time with `personal-server reconfigure`.

## Design constraints (the rules this repo obeys)

1. **Zero hardcoded service names** anywhere in `Dockerfile`, `docker-bake.hcl`, or any build/first-boot script. Adding a service = dropping a folder under `services/` with a `service.yaml` and a couple of scripts, nothing else to touch.
2. **Every service is self-contained** under `services/<name>/` — its YAML manifest, its `install.sh`, its `configure.sh`, optional `files/` tree for static assets (systemd units, compose templates, etc.).
3. **Fully generic helpers** in `shared/lib/` iterate over `services/*/service.yaml` — they never know a specific service exists.
4. **Dockerfile and bake.hcl are generated** from `shared/base-packages.yaml` + every `service.yaml` by `build/generate.sh`. The generated files are git-ignored.
5. **Dev builds are tolerant, prod builds are strict.** Same script, flag-switched.
6. **Every upstream pin is verified against the vendor's own docs**, not copied from random tutorials.

## Repository layout

```
personal-server/
├── services/                   # one folder per service, fully self-contained
│   └── <name>/
│       ├── service.yaml        # manifest: packages, deps, storage, runtime, SSO, Pangolin hooks
│       ├── install.sh          # runs inside the service-<name> build stage
│       ├── configure.sh        # runs on first-boot after the wizard collects inputs
│       └── files/              # optional: systemd units, compose templates, configs
├── shared/
│   ├── base-packages.yaml      # packages installed in the base-common stage
│   ├── lib/
│   │   ├── yaml.sh             # yq helpers used everywhere
│   │   ├── service-loader.sh   # discovers services/* and topo-sorts by depends_on
│   │   ├── storage.sh          # generic ZFS snapshot/send-recv/mount helpers
│   │   ├── run-install.sh      # executed inside every service-<name> stage
│   │   └── install-base.sh     # EPEL + CRB + ZFS kmod (runs in base-common)
│   ├── systemd/                # shared units (firstboot, weekly reboot)
│   └── first-boot/
│       ├── wizard.sh           # interactive, runs on tty1 on first boot
│       └── apply-domain.sh     # writes /etc/personal-server/first-boot-checklist.txt
├── build/
│   ├── generate.sh             # produces Dockerfile + docker-bake.hcl from the YAMLs
│   ├── build.sh                # orchestrates: generate → bake services → bake final
│   └── templates/              # Dockerfile.tmpl + docker-bake.hcl.tmpl
├── bin/
│   ├── personal-server         # CLI wrapper baked into the image
│   └── move-service-storage    # generic ZFS migration CLI
├── .github/workflows/
│   └── build.yml               # CI: discover → build → iso → rolling weekly release
└── README.md                   # this file
```

## How the build pipeline works

The build system is designed to satisfy two constraints that would normally
fight each other: **every service is its own stage** (so the cache is as
granular as possible) and **everything that gets installed must land in the
final image** (no orphan filesystems per stage).

### 1. `shared/base-packages.yaml` → `base-common` stage

`build/generate.sh` reads `base_image` and `packages` from this file and
emits a `base-common` stage in the generated Dockerfile. After the package
install, `base-common` runs `shared/lib/install-base.sh` which does the
multi-step bootstraps that a flat YAML can't express: enabling EPEL, CRB,
and the ZFS kmod repo (not DKMS — bootc images can't compile kernel modules
at runtime).

### 2. `services/*/service.yaml` → `service-<name>` stages, chained in topological order

For every service, `generate.sh` emits one Docker stage named
`service-<name>`. The stages are **chained in dependency order**
(`service-X FROM service-(X-1)`), which means:

- ✅ Everything that any `install.sh` puts on disk (rpms, users, `/opt/…`, systemd units, etc.) accumulates into a single rootfs that the `final` stage inherits as-is.
- ✅ BuildKit's layer cache stays granular: changing `services/webzfs/install.sh` only invalidates `service-webzfs` and everything after it in the chain; the services before it remain cache-hit.
- ❌ The trade-off: services can't be built in parallel in a CI matrix, and a failing service early in the chain blocks every service after it. For this scale (8 services, ~6 min cold build, ~1 min warm) it's a reasonable cost to pay for correctness.

Each `service-<name>` stage runs `shared/lib/run-install.sh`, which is
**generic**: it reads the service's YAML, installs the packages, applies
any COPR/repo setup, runs the service's own `install.sh`, and stages the
service's runtime assets under `/etc/personal-server/services/<name>/` so
the first-boot wizard can find them later.

### 3. `final` stage inherits the chain head

The `final` stage is simply `FROM service-<last>` plus the shared
first-boot scripts, the shared systemd units, the `bin/` CLIs, and the
build report. `systemctl enable personal-server-firstboot.service` and
`personal-server-reboot.timer` are activated here.

### 4. `build/build.sh` orchestrates

```bash
./build/build.sh dev    # tolerant: per-service logs, continues on failure
./build/build.sh prod   # strict: first failure aborts
NO_CACHE=1 ./build/build.sh prod   # weekly: --pull --no-cache
```

What it does:
1. `generate.sh` — produces `build/Dockerfile` and `build/docker-bake.hcl` from the YAMLs.
2. For each service (in topo order): `docker buildx bake service-<name>`, tee-ing the log to `build/logs/<name>.log` and recording the status in `build/report.json`.
3. (dev mode) `generate.sh --filter-from-report build/report.json` — rebuilds a shorter chain omitting failed services and their cascading dependents.
4. `docker buildx bake final` — assemble.
5. Extract a manifest (rpm set + pinned container image refs + image digest) to `build/manifest.txt` so the CI can diff it against the previous release and show what actually changed upstream.

### 5. First-boot wizard

On first boot, `personal-server-firstboot.service` launches `wizard.sh`
on `tty1`. It asks for:

- Root domain (ex. `home.example.com`)
- ACME email + DNS provider (any Lego name) + DNS provider credentials
- Optional ZFS pool names per service (can be skipped — data lives on rootfs until `personal-server move <service> <pool>` is run later)

The wizard then iterates over every service in dependency order, copies
its systemd units into `/etc/systemd/system/`, and runs its `configure.sh`
with the answers exposed as env vars. After all configures are done,
`apply-domain.sh` writes `/etc/personal-server/first-boot-checklist.txt`
with the handful of one-time UI clicks that Pangolin / PocketID / Coolify
genuinely cannot skip (no non-interactive admin bootstrap in any of them —
verified in their source code).

## CI / GitHub Actions

`.github/workflows/build.yml` has 4 jobs:

1. **`discover`** — compute mode (`dev` on `dev` branch, `prod` on `main`, `prod` on cron) and the tag.
2. **`build`** — run `./build/build.sh $mode`, push the image to `ghcr.io/<user>/personal-server:{tag,latest|dev}`, upload `build/manifest.txt` as an artefact. `NO_CACHE=1` is injected when the trigger is the weekly cron so the rebuild actually picks up upstream bumps instead of restoring from GHA cache.
3. **`iso`** — prod only. `quay.io/centos-bootc/bootc-image-builder` → bootable Anaconda ISO artefact.
4. **`release`** — prod only. Maintains a single rolling release tagged `weekly` on GitHub, updated in place on every successful main build (manual push or cron). The release body is regenerated each time to show:
   - commits since the previous release target SHA (`git log --oneline <prev>..HEAD`)
   - a `diff -U0` of the manifest (added/removed rpms, image digest change, container image refs)

   The ISO and manifest.txt are re-uploaded with `--clobber`.

Triggers:

| Event | Mode | Image tag | `weekly` release updated |
|---|---|---|---|
| push `main` | prod | `prod-<sha>` + `:latest` | ✅ |
| push `dev` | dev | `dev-<sha>` + `:dev` | ❌ |
| `schedule` Sun 02:00 UTC | prod | `prod-<sha>` + `:latest` | ✅ (via `--pull --no-cache`) |
| `workflow_dispatch` | choose | either | only if prod |

## Writing your own variant

If you want to base a home-lab image on this repo, the adapting steps are:

1. **Fork.**
2. **Strip the services you don't want.** Delete `services/<name>/` folders. Nothing else needs to change — `generate.sh` re-discovers the set on every run.
3. **Add your own services.** Create `services/<myservice>/` with at minimum a `service.yaml` and an `install.sh`. Use an existing service as a template (`watchtower` is the simplest, `pangolin` is the most complex).
4. **(optional) Re-point the base image.** Edit `base_image:` in `shared/base-packages.yaml`. The pipeline has been tested against AlmaLinux bootc 9 but anything OCI + dnf-based should work with minimal edits.
5. **(optional) Change the runtime CLIs.** `bin/personal-server` and `bin/move-service-storage` are generic — they iterate over whatever is in `/etc/personal-server/services/` at runtime, so they adapt to your set automatically.
6. **(optional) Re-point the registry.** Edit `REGISTRY` / `IMAGE_NAME` defaults in `build/build.sh` and the corresponding env in `.github/workflows/build.yml`.

### The `service.yaml` schema

Every service describes itself through the same schema, parsed by
`shared/lib/yaml.sh`. Only `name` and `build:` are mandatory; everything
else is opt-in and the build pipeline gracefully handles missing sections.

```yaml
name: myservice
display_name: My Service
description: What this service is for
depends_on: [docker]            # other service names, used by the topo sort

build:
  packages: [pkg1, pkg2]        # installed by run-install.sh before install.sh runs
  copr_repos: [owner/project]   # optional, enabled before packages are installed
  extra_repos:                  # optional, raw .repo URLs or .rpm URLs
    - https://example.com/thing.repo
  install_script: install.sh    # defaults to install.sh

storage:                        # optional, only if the service has persistent data
  data_path: /var/lib/myservice
  pool_key: myservice           # key under /etc/personal-server/storage.yaml
  default_dataset_name: myservice
  migration_strategy: zfs-or-rsync   # or rsync-only, or none
  pre_migrate_hook: pre.sh           # optional
  post_migrate_hook: post.sh         # optional

runtime:                        # optional, used by the CLI and by move-service-storage
  systemd_units: [myservice.service]
  stop_cmd: systemctl stop myservice
  start_cmd: systemctl start myservice
  health:
    type: http                  # http | tcp | systemd | exec
    url: http://localhost:1234

sso:                            # optional, consumed by the first-boot checklist
  type: oidc                    # oidc | proxy-auth | none
  client_name: myservice

pangolin:                       # optional, consumed by apply-domain.sh checklist
  resource_name: myservice
  subdomain: myservice          # final FQDN = <subdomain>.<root_domain>
  upstream: http://localhost:1234
  auth: pocketid                # pocketid | proxy-auth | public

configure:
  first_boot: configure.sh      # defaults to configure.sh
```

### What `install.sh` should do

- Runs **in the Docker build stage**, inheriting from the previous service in the chain (or `base-common` for the first service).
- Has root, has a full dnf, has access to the service's own tree under `/build/svc/`.
- Should install whatever can be frozen into the image at build time: binaries, users, systemd units, config templates.
- Must NOT start services, run `systemctl daemon-reload`, or do anything that requires a live systemd — the build container has none. If the service's upstream installer insists on calling `systemctl`, shim it with a no-op wrapper (see [services/webzfs/install.sh](services/webzfs/install.sh) for an example).

### What `configure.sh` should do

- Runs **on first-boot** (and on every `personal-server reconfigure`) on the real running system, as root, with a live systemd.
- Has access to the wizard's answers via env vars: `PS_DOMAIN`, `PS_ACME_EMAIL`, `PS_ACME_DNS_PROVIDER`, `PS_POOL` (the ZFS pool the operator assigned to this specific service, empty if rootfs), and every DNS provider credential the wizard collected.
- Should render any templates (`envsubst` is available in the base), bring the service's systemd unit up, and do any idempotent first-run setup.

## Status

This is my personal home-lab image. The architecture, the per-service split,
and the first-boot wizard are deliberately generic — fork-friendly — but
the specific service list is **mine**: ZFS, Incus, Docker, Pangolin, PocketID,
Coolify, Arcane, Watchtower, WebZFS. That set answers my needs today and
isn't intended to be a general-purpose distribution.

If you fork it and end up with something useful for your own home lab,
that's the whole point. Issues and PRs that improve the **generic** bits
(build pipeline, generators, helpers, docs) are welcome; PRs that add
new services to my personal set probably aren't, but you're free to keep
them in your own fork.

## Licence

LGPL 2.1 — see [LICENSE](LICENSE).
