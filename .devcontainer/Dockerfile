# syntax=docker/dockerfile:1
# The development image: the dev container (devcontainer.json, GitHub Codespaces) and the one command Docker demo
# (compose.demo.yml) both run it. System packages only: the source is mounted, and the gems install into the bundle
# volume at /bundle, so a Gemfile change needs no rebuild. Production builds from the Dockerfile at the root instead.

# Keep in step with .ruby-version. -slim-bookworm, not -slim: plain -slim moved to Debian trixie.
ARG RUBY_VERSION=3.4.12
FROM docker.io/library/ruby:${RUBY_VERSION}-slim-bookworm

# build-essential, pkg-config and the -dev packages: native gems (pg, psych, bigdecimal, ...).
# libvips42 and fonts-dejavu-core: image variants and share images. postgresql-client: bin/rails dbconsole, pg_isready.
# git: the editor and bundler. tzdata: tzinfo reads /usr/share/zoneinfo. No Node: importmap and tailwindcss-rails.
RUN apt-get update -qq && \
    apt-get install --no-install-recommends -y \
      build-essential pkg-config libssl-dev zlib1g-dev libffi-dev libgmp-dev libyaml-dev libpq-dev \
      git curl ca-certificates tzdata postgresql-client libvips42 fonts-dejavu-core && \
    rm -rf /var/lib/apt/lists /var/cache/apt/archives

# bin/dev runs Procfile.dev with foreman; in the image, so a fresh container doesn't install it on every start. The
# mounted checkout belongs to another user, which git refuses without this.
RUN gem install foreman --no-document && \
    git config --system --add safe.directory '*'

ENV BUNDLE_PATH=/bundle \
    BUNDLE_JOBS=4 \
    BUNDLE_RETRY=3
