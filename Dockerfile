# syntax=docker/dockerfile:1.9
#
# Development image for https://github.com/lance-format/lance
#
# Contains the Rust, Java and Python toolchains the repository expects, plus
# the Docker CLI so `make integtest` can drive LocalStack through a mounted
# socket. The repository itself is NOT baked in -- bind-mount a working copy
# at /workspace so rebuilding the image never costs you a worktree.
FROM ubuntu:24.04

ARG USERNAME=lance
ARG USER_UID=1000
ARG USER_GID=1000
# Keep RUST_VERSION in sync with rust-toolchain.toml in lance-format/lance.
# rustup would honour that file anyway; baking it in just avoids the download
# on first build.
ARG RUST_VERSION=1.98.1
# .github/workflows/java.yml runs a matrix of 11/17/21/25. 25 is omitted by
# default to keep the image smaller; add it here if you need to reproduce it.
ARG JDK_VERSIONS="11 17 21"
ARG DEFAULT_JDK=17
ARG BUF_VERSION=1.47.2
# mr boxington, the Rust build cache. Pinned so an image digest names an exact
# cache client; the on-disk and wire formats are versioned separately.
ARG MBX_VERSION=1.30.0
# mbx downloads and pins this mold release itself, at first link rather than at
# image build time, into the shared cache volume. It must be an exact version;
# mbx rejects `latest`.
ARG MOLD_VERSION=3.0.0

ENV DEBIAN_FRONTEND=noninteractive \
    LANG=C.UTF-8 \
    LC_ALL=C.UTF-8

# --- base system packages ---------------------------------------------------
# protobuf-compiler: prost build scripts. libssl-dev/pkg-config: native TLS.
# libhdf5-dev: the hdf5 benchmark. lld/cmake: native deps in the tree. clang is
# also how mbx drives mold -- every linker selection other than `system` links
# through it, and Rust builds fail outright without it.
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      bash-completion \
      build-essential \
      ca-certificates \
      clang \
      cmake \
      curl \
      file \
      git \
      gnupg \
      htop \
      jq \
      less \
      libhdf5-dev \
      libssl-dev \
      lld \
      make \
      openssh-client \
      pkg-config \
      protobuf-compiler \
      python3 \
      python3-venv \
      ripgrep \
      rsync \
      sudo \
      tmux \
      tzdata \
      unzip \
      util-linux \
      vim \
      wget \
      zip \
      zstd \
 && rm -rf /var/lib/apt/lists/*

# --- docker client ----------------------------------------------------------
# Client only. The container talks to the host daemon over a mounted socket;
# nothing is nested.
RUN install -m 0755 -d /etc/apt/keyrings \
 && curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc \
 && chmod a+r /etc/apt/keyrings/docker.asc \
 && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
      > /etc/apt/sources.list.d/docker.list \
 && apt-get update \
 && apt-get install -y --no-install-recommends \
      docker-ce-cli \
      docker-buildx-plugin \
      docker-compose-plugin \
 && rm -rf /var/lib/apt/lists/*

# --- JDKs (Temurin, matching actions/setup-java in CI) ----------------------
RUN curl -fsSL https://packages.adoptium.net/artifactory/api/gpg/key/public -o /etc/apt/keyrings/adoptium.asc \
 && chmod a+r /etc/apt/keyrings/adoptium.asc \
 && echo "deb [signed-by=/etc/apt/keyrings/adoptium.asc] https://packages.adoptium.net/artifactory/deb $(. /etc/os-release && echo "$VERSION_CODENAME") main" \
      > /etc/apt/sources.list.d/adoptium.list \
 && apt-get update \
 && for v in ${JDK_VERSIONS}; do apt-get install -y --no-install-recommends "temurin-${v}-jdk"; done \
 && rm -rf /var/lib/apt/lists/*

# A stable JAVA_HOME regardless of architecture suffix. Switch JDKs for a
# matrix run with `sudo update-alternatives --config java`.
RUN set -eux; \
    jhome="$(ls -d /usr/lib/jvm/temurin-${DEFAULT_JDK}-jdk-* | head -n1)"; \
    ln -sfn "$jhome" /usr/lib/jvm/default; \
    update-alternatives --set java "$jhome/bin/java"; \
    update-alternatives --set javac "$jhome/bin/javac"
ENV JAVA_HOME=/usr/lib/jvm/default
ENV PATH=/usr/lib/jvm/default/bin:${PATH}

# --- uv (the only sanctioned Python entry point for this repo) --------------
ENV UV_INSTALL_DIR=/usr/local/bin \
    UV_NO_MODIFY_PATH=1
RUN curl -LsSf https://astral.sh/uv/install.sh | sh && uv --version

# --- buf (protos/ linting) --------------------------------------------------
RUN set -eux; \
    curl -fsSL "https://github.com/bufbuild/buf/releases/download/v${BUF_VERSION}/buf-Linux-$(uname -m)" \
      -o /usr/local/bin/buf; \
    chmod +x /usr/local/bin/buf; \
    buf --version

# --- mr boxington (mbx) -----------------------------------------------------
# The Rust build cache. It replaces sccache rather than joining it: both wrap
# rustc through RUSTC_WRAPPER, so the two cannot be combined.
RUN set -eux; \
    case "$(dpkg --print-architecture)" in \
      amd64) triple=x86_64-unknown-linux-gnu ;; \
      arm64) triple=aarch64-unknown-linux-gnu ;; \
      *) echo "unsupported architecture for mbx" >&2; exit 1 ;; \
    esac; \
    archive="mbx-${triple}.tar.gz"; \
    release="https://github.com/jdx/mr-boxington/releases/download/v${MBX_VERSION}"; \
    tmp="$(mktemp -d)"; \
    curl -fsSL -o "${tmp}/${archive}" "${release}/${archive}"; \
    curl -fsSL -o "${tmp}/SHA256SUMS" "${release}/SHA256SUMS"; \
    cd "$tmp"; \
    grep "  ${archive}$" SHA256SUMS | sha256sum --check --strict -; \
    tar -xzf "$archive" mbx; \
    install -m 0755 mbx /usr/local/bin/mbx; \
    cd /; rm -rf "$tmp"; \
    mbx --version

# --- unprivileged user ------------------------------------------------------
# Ubuntu 24.04 ships a default `ubuntu` account at uid 1000; reclaim it so the
# bind-mounted workspace is owned by the same uid as the host user.
RUN set -eux; \
    if getent passwd "${USER_UID}" >/dev/null; then \
      userdel -r "$(getent passwd "${USER_UID}" | cut -d: -f1)" 2>/dev/null || true; \
    fi; \
    if getent group "${USER_GID}" >/dev/null; then \
      groupdel "$(getent group "${USER_GID}" | cut -d: -f1)" 2>/dev/null || true; \
    fi; \
    groupadd -g "${USER_GID}" "${USERNAME}"; \
    useradd -m -u "${USER_UID}" -g "${USER_GID}" -s /bin/bash "${USERNAME}"; \
    printf '%s ALL=(ALL) NOPASSWD:ALL\n' "${USERNAME}" > "/etc/sudoers.d/90-${USERNAME}"; \
    chmod 0440 "/etc/sudoers.d/90-${USERNAME}"

# Bind-mounted checkouts are owned by the host uid, which git otherwise
# rejects as dubious ownership.
RUN git config --system --add safe.directory '*'

# --- Rust -------------------------------------------------------------------
USER ${USERNAME}
ENV HOME=/home/${USERNAME}
ENV CARGO_HOME=${HOME}/.cargo \
    RUSTUP_HOME=${HOME}/.rustup
ENV PATH=${HOME}/.cargo/bin:${HOME}/.local/bin:${PATH}

RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs \
      | sh -s -- -y --no-modify-path --profile minimal \
        --default-toolchain "${RUST_VERSION}" \
        -c rustfmt -c clippy -c rust-analyzer -c rust-src \
 && rustup toolchain install nightly --profile minimal \
        -c llvm-tools-preview -c rustfmt -c clippy \
 && rustup default "${RUST_VERSION}" \
 && rustc --version && cargo --version

# Prebuilt binaries via binstall; building these from source would add ~20
# minutes to every image build.
# cargo-llvm-cov backs `cargo +nightly llvm-cov`. Caching is mbx's job, so
# there is no sccache here.
RUN curl -L --proto '=https' --tlsv1.2 -sSf \
      https://raw.githubusercontent.com/cargo-bins/cargo-binstall/main/install-from-binstall-release.sh | bash \
 && cargo binstall --no-confirm cargo-llvm-cov cargo-nextest cargo-deny \
 && rm -rf "${CARGO_HOME}/registry/cache" "${CARGO_HOME}/registry/src"

# Route plain `cargo` through mbx. `mbx setup` writes a Cargo shim at a stable
# path and points rust-analyzer's background check at that same shim, so the
# terminal, maturin, the JNI build and the editor all share one cache without
# anyone remembering to type `mbx`. The shim has to precede ~/.cargo/bin.
ENV PATH=${HOME}/.local/share/mbx/bin:${PATH}
# Compiler shims are executables, not cached artifacts, and mbx keeps them
# under the cache directory by default -- which compose shares between boxes.
# Give each container a private one, on its own writable layer.
ENV MBX_SHIMS_DIR=${HOME}/.local/state/mbx-shims
RUN mkdir -p "${MBX_SHIMS_DIR}" \
 && mbx setup \
 && [ "$(command -v cargo)" = "${HOME}/.local/share/mbx/bin/cargo" ]

# mold for every Rust link. This is mbx's global configuration, the lowest
# precedence of its three sources, so a repository that ships its own .mbx.toml
# still wins and MBX_LINKER overrides both for one invocation. mbx fetches the
# release on first use, verifies GitHub's digest and keeps it under the shared
# cache volume, so one box's download serves them all.
RUN mkdir -p "${HOME}/.config/mbx" \
 && printf '[linker]\ndefault = "mold@%s"\n' "${MOLD_VERSION}" \
      > "${HOME}/.config/mbx/config.toml" \
 && [ "$(mbx settings get linker.default)" = "mold@${MOLD_VERSION}" ]

# python/Makefile's `install` target runs `uv tool run pre-commit install`.
RUN uv tool install pre-commit

# --- runtime ----------------------------------------------------------------
USER root
COPY scripts/entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh \
 && mkdir -p /workspace \
 && chown "${USER_UID}:${USER_GID}" /workspace

ENV DEVBOX_USER=${USERNAME}
WORKDIR /workspace
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["sleep", "infinity"]
