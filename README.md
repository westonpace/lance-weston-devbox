# lance-weston-devbox

A Docker image with the Rust, Java and Python toolchains that
[lance-format/lance](https://github.com/lance-format/lance) expects, plus the
glue to run one or more of them on a single EC2 host.

The image is the unit you version, not an AMI. Tweaking the environment is a
`docker build` (seconds, with layer cache) instead of an AMI bake, running a
second box is `docker run` rather than a second instance, and the same image
works on a laptop.

```
Dockerfile                   the environment
compose.yml                  how a box runs (mounts, caches, networking)
scripts/devbox               build / push / up / shell / down
scripts/entrypoint.sh        reconciles the Docker socket GID, drops privileges
host/user-data.sh            EC2 Launch Template user data for the host
.devcontainer/               VS Code / Dev Containers attach
.github/workflows/build.yml  builds and pushes to ghcr.io on every push to main
```

## Quick start

On the host:

```bash
git clone https://github.com/westonpace/lance-weston-devbox && cd lance-weston-devbox
```

```bash
cp .env.example .env && $EDITOR .env
```

```bash
scripts/devbox up && scripts/devbox shell
```

Then, once, inside the box:

```bash
git clone https://github.com/lance-format/lance /workspace/lance
```

```bash
cd /workspace/lance/python && make install
```

`make install` runs `uv sync`, which builds the `pylance` extension. It takes a
while on a first run and must not be interrupted.

Daily cycle is `scripts/devbox stop` / `scripts/devbox start`. `down` removes
the container and its `$HOME`; the shared caches and your `/workspace`
checkout survive it.

## What is in the image

| | |
|---|---|
| Rust | `1.98.1` (matching `rust-toolchain.toml`) with rustfmt, clippy, rust-analyzer, rust-src; plus `nightly` with `llvm-tools-preview` for `cargo +nightly llvm-cov` |
| Cargo tools | `cargo-llvm-cov`, `cargo-nextest`, `cargo-deny`, `cargo-binstall` |
| Build cache | [mr boxington](https://mr-boxington.jdx.dev/) (`mbx`), wired in so plain `cargo` goes through it. See [Rust build cache](#rust-build-cache) |
| Java | Temurin 11, 17 and 21; `JAVA_HOME` points at 17. Maven comes from the repo's `./mvnw` |
| Python | `uv` only — the repo forbids bare `python`/`pip`/`pytest`/`maturin`. `pre-commit` preinstalled as a uv tool |
| Native | `protobuf-compiler`, `libssl-dev`, `pkg-config`, `cmake`, `clang`, `lld`, `libhdf5-dev` (the hdf5 benchmark) |
| Linker | mold, pinned and fetched by mbx. See [Linker](#linker) |
| Protos | `buf` |
| Docker | client + compose plugin, pointed at the host's socket |

The Rust version, the JDK set and the default JDK are build args:

```bash
scripts/devbox build --build-arg RUST_VERSION=1.99.0 --build-arg JDK_VERSIONS="17 21 25"
```

To switch JDKs inside a running box, `sudo update-alternatives --config java`.

## Integration tests and LocalStack

`python/Makefile`'s `integtest` target starts LocalStack itself through
`docker compose`, and both the Rust and Python S3/DynamoDB tests hardcode
`localhost:4566`. Two things in `compose.yml` make that work unchanged:

- `/var/run/docker.sock` is mounted, so `docker compose` inside the box starts
  LocalStack as a *sibling* container on the host — not Docker-in-Docker.
- the box uses `network_mode: host`, so the port LocalStack publishes on the
  host is the `localhost:4566` the tests look for.

`scripts/entrypoint.sh` fixes up the socket's group at start, because the
host's `docker` GID differs between Ubuntu, Amazon Linux and a laptop and is
not knowable at build time.

Consequence: boxes share one network stack. Run `make integtest` in one box at
a time, or set `KEEP_COMPOSE=1` and share a single LocalStack.

## Running several boxes

Every setting is per-invocation, so a second box is:

```bash
DEVBOX_NAME=box2 DEVBOX_WORKSPACE=/data/box2 scripts/devbox up
```

```bash
DEVBOX_NAME=box2 scripts/devbox shell
```

What is shared and what is not:

- **Shared** (fixed volume names, outside the compose project namespace):
  the Cargo registry and git caches, `~/.m2`, the uv cache, and mbx's action
  store. All are safe under concurrent access, and sharing them is the
  difference between downloading the crate index once and once per box — or,
  for mbx, between compiling a crate once and once per box.
- **Not shared**: `/workspace`, and therefore each box's build outputs. Give
  each box its own checkout. Disk, not CPU, is what this costs you — the
  workspace has three separate Cargo trees (root, `python/`,
  `java/lance-jni/`), each tens of GB with tests and benches built.

Consider capping `CARGO_BUILD_JOBS` once several boxes build at once, so
parallel rustc link steps do not race for RAM.

## Rust build cache

[mr boxington](https://mr-boxington.jdx.dev/) (`mbx`) is the compilation cache.
It replaces sccache — both wrap rustc through `RUSTC_WRAPPER`, so they cannot
be combined — and it caches more: Cargo's whole build plan rather than
individual rustc invocations, with keys that survive a different checkout path.

There is nothing to turn on. `mbx setup` runs at image build time and puts a
Cargo shim ahead of `~/.cargo/bin` on `PATH`, so plain `cargo build`, `make`,
`uv sync`'s maturin step, the `java/lance-jni` build and rust-analyzer's
background check all go through it. `mbx build` still works if you prefer to be
explicit. Check what a box is actually doing with:

```bash
mbx doctor
```

Three paths matter, all set in [`compose.yml`](compose.yml):

| | |
|---|---|
| `MBX_CACHE_DIR` | `~/.cache/mbx`, a shared Docker volume. The cached compilations every box reuses |
| `MBX_SHIMS_DIR` | `~/.local/state/mbx-shims`, per container. Compiler shims are executables, not artifacts, and each box has its own mbx binary |
| `MBX_TARGET_ROOT` | `/workspace/.mbx-targets`, per box. mbx replaces `target/` with a symlink into here |

The per-box target root is not an accident. mbx keys a managed target
directory by the checkout's path, and every box mounts its checkout at the same
`/workspace` — one shared root would hand two boxes the same directory and let
Cargo's lock serialise them. Keeping the workspace mount and Docker's volumes
on one filesystem (both are on `/data` on the EC2 host) also lets a restore
hard-link out of the store instead of copying gigabytes.

`MBX_GC_MAX_TOTAL_SIZE` (default `50GiB`) is one budget covering the store, the
managed targets and incremental state.

### Linker

mold, pinned to an exact version (`MOLD_VERSION` in the
[`Dockerfile`](Dockerfile)), is the default linker for every Rust link. mbx
downloads that release itself on first use — verified against GitHub's digest,
and kept under the shared cache volume, so one box's download serves them all.
Nothing is baked into the image but the choice.

It is set in mbx's *global* configuration, the lowest-precedence of its three
sources, so a repository that ships its own `.mbx.toml` still wins and
`MBX_LINKER` overrides both for a single invocation:

```bash
MBX_LINKER=system cargo build
```

`system` is GNU `ld`; `rust-lld` is the toolchain's own LLD with no download.
`MBX_LINKER` also passes through `compose.yml`, so a box can be pinned to one
in `.env`.

Two consequences worth knowing:

- **`clang` is load-bearing now.** Every linker selection other than `system`
  links through it. It was already in the image for native dependencies, but
  dropping it would now break every Rust build outright, not just a few crates.
- **The linker is part of the cache key for native links.** A box on `system`
  stops sharing those results with the boxes on mold — and so would CI, if it
  ever writes to the same namespace. Compare equivalent builds when you measure
  what mold bought you.

### S3 as the shared cache

On EC2, point the boxes at a bucket and they stop compiling what another box,
or an earlier instance, already built:

```ini
MBX_REMOTE_URL=s3://lance-build-cache/devbox
MBX_REMOTE_NAMESPACE=lance
MBX_REMOTE_S3_REGION=us-east-1
```

in `.env`. Credentials are the instance role: mbx reads IMDSv2 itself and
refreshes before expiry, so a long build keeps its cache. Nothing is written to
the host. Because the boxes use host networking, the instance's default
metadata hop limit of 1 is not in the way.

Give the instance role, for the bucket and the `<prefix>/<namespace>/` that
`MBX_REMOTE_URL` and `MBX_REMOTE_NAMESPACE` select:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    { "Effect": "Allow",
      "Action": ["s3:GetObject", "s3:PutObject"],
      "Resource": "arn:aws:s3:::lance-build-cache/devbox/lance/*" },
    { "Effect": "Allow",
      "Action": "s3:ListBucket",
      "Resource": "arn:aws:s3:::lance-build-cache" }
  ]
}
```

`s3:ListBucket` is not optional in practice. mbx never lists anything, but
without it S3 answers `403` rather than `404` for an absent object, and a cache
miss becomes indistinguishable from a refusal.

Two things to know about writes:

- mbx only publishes from CI on a protected branch unless told the environment
  is trusted, so a devbox would silently be read-only. `compose.yml` sets
  `MBX_REMOTE_TRUST_WRITES=true` for that reason. Set
  `MBX_REMOTE_MODE=read-only` for a box that should only consume.
- Mounting `~/.aws` into the box (as
  [`compose.override.yml.example`](compose.override.yml.example) does for S3
  tests) stops the instance-role lookup: a `[default]` profile is a credential
  source the AWS tools would prefer, and mbx refuses to sign as the instance
  instead. Either drop that mount or export credentials that can reach the
  bucket.

A fresh box can warm its store from a lockfile before building anything:

```bash
mbx prefetch build --workspace
```

## The EC2 host

Keep the host dumb: a stock Ubuntu 24.04 AMI plus
[`host/user-data.sh`](host/user-data.sh) in a Launch Template. It installs
Docker, puts Docker's data-root on a second EBS volume, logs in to GHCR using
a token read from SSM Parameter Store, and optionally installs an idle
auto-stop timer.

Sizing notes:

- **Instance**: `m7i.8xlarge` (32 vCPU / 128 GB) is a reasonable starting
  point. Prefer the m-family over c-family: rustc's LTO link steps are
  memory-hungry, and more so with several boxes building at once.
- **Storage**: a 500 GB gp3 data volume. Three Cargo trees per checkout, times
  the number of boxes, is the driver. Keep the workspaces and Docker's
  data-root on it together — `host/user-data.sh` already does — so mbx can
  hard-link restores instead of copying them.
- **Cache bucket**: an S3 bucket in the same region, with a lifecycle rule
  expiring objects after a few weeks. See
  [Rust build cache](#s3-as-the-shared-cache).
- **Lifecycle**: set the instance's shutdown behaviour to **stop**, never
  terminate, so the EBS caches survive. Stopped instances bill only for
  storage (~$0.08/GB-month for gp3, so ~$40/month for a 500 GB volume sitting
  idle).

Spin up and down with `aws ec2 start-instances` / `stop-instances`, or let the
idle timer do it by setting `IDLE_SHUTDOWN_MINUTES` in the user data. The
timer only fires when nobody is logged in *and* load is low, so an unattended
build will not be stopped out from under you.

### GHCR credentials

The image is published to `ghcr.io/westonpace/lance-weston-devbox`. If the
package is private, the host needs a classic PAT with `read:packages`:

```bash
aws ssm put-parameter --name /devbox/ghcr-token --type SecureString --value ghp_...
```

Give the instance role `ssm:GetParameter` on that parameter and `kms:Decrypt`
for its key. The token is read at boot rather than embedded in user data,
which anything that can reach IMDS from the instance can read.

## Building the image

GitHub Actions builds and pushes on every push to `main` touching the
`Dockerfile` or the entrypoint, and smoke-tests every toolchain in the result.

To iterate faster, build on the host itself and skip the registry round trip:

```bash
scripts/devbox build && scripts/devbox up
```

```bash
scripts/devbox push
```

## Editors

Attach VS Code or Cursor with **Dev Containers: Attach to Running Container**
after an SSH connection to the host, or use the `devcontainer` CLI against
[`.devcontainer/devcontainer.json`](.devcontainer/devcontainer.json).

For your own SSH key, git identity and AWS credentials inside the box, copy
`compose.override.yml.example` to `compose.override.yml`. Compose picks it up
automatically and it is gitignored.
