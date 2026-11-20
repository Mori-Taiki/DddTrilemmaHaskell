FROM debian:trixie-slim

# Prebuilt Haskell libraries shorten the first Cabal build in a new Codespace.
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        build-essential ca-certificates curl git openssh-client sudo \
        cabal-install ghc zlib1g-dev \
        libghc-blaze-textual-dev libghc-hspec-dev libghc-only-dev \
        libghc-temporary-dev libghc-wai-extra-dev libghc-warp-dev \
    && rm -rf /var/lib/apt/lists/* \
    && useradd --create-home --shell /bin/bash vscode \
    && echo 'vscode ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/vscode \
    && chmod 0440 /etc/sudoers.d/vscode

ENV LANG=C.UTF-8
USER vscode
