# This is a multi-stage build with two stages, where the first is used to precompile assets.
FROM ruby:2.7.6
WORKDIR /build

# Begin by installing gems.
COPY Gemfile .
COPY Gemfile.lock .
RUN gem install bundler -v '2.2.33'
RUN bundle config set --local deployment true
RUN bundle config set --local without development test
RUN bundle install -j4

# We need NodeJS for precompiling assets.
RUN curl -fsSL https://deb.nodesource.com/setup_lts.x | bash -
RUN apt-get install -y nodejs

# Install JS dependencies using Yarn.
COPY package.json .
COPY yarn.lock .
RUN corepack enable
RUN yarn install

# Copy over remaining files and set up for precompilation.
COPY . /build

ENV RAILS_ENV="production"
ENV DB_ADAPTER="nulldb"
ENV SECRET_KEY_BASE="2ab04e6d7919f4f9fd1e25d41455aa26ad21c2a8d053bc00ac02db4d424d97e0716105c620907e6d829329fe275d52673117d432d6d00c9052bec26a82b2de3f"

# AWS requires a lot of keys to initialize.
ENV AWS_ACCESS_KEY_ID=provide_access_key_id
ENV AWS_SECRET_ACCESS_KEY=provide_secret_access_key
ENV AWS_REGION=provide_valid_region
ENV AWS_BUCKET=provide_bucket_name

# Export the locales.json file.
RUN bundle exec i18n export

# Compile ReScript files to JS.
RUN yarn run re:build

# Before precompiling, let's remove bin/yarn to prevent reinstallation of deps via yarn.
RUN rm bin/yarn
RUN bundle exec rails assets:precompile

# With precompilation done, we can move onto the final stage.
FROM ruby:2.7.6-slim-bullseye

# We'll need a few packages in this image.
RUN apt-get update && apt-get install -y \
  ca-certificates \
  cron \
  curl \
  gnupg \
  imagemagick \
  && rm -rf /var/lib/apt/lists/*

# We'll also need the exact version of PostgreSQL client, matching our server version, so let's get it from official repos.
RUN curl https://www.postgresql.org/media/keys/ACCC4CF8.asc | gpg --dearmor | tee /etc/apt/trusted.gpg.d/apt.postgresql.org.gpg >/dev/null
RUN echo "deb http://apt.postgresql.org/pub/repos/apt/ bullseye-pgdg main" | tee /etc/apt/sources.list.d/pgdg.list

# Now install the exact version of the client we need.
RUN apt-get update && apt-get install -y postgresql-client-12 \
  && rm -rf /var/lib/apt/lists/*

# Let's also upgrade bundler to the same version used in the build.
RUN gem install bundler -v '2.2.33'

WORKDIR /app
COPY . /app

# We'll copy over the precompiled assets, and the vendored gems.
COPY --from=0 /build/public/assets public/assets
COPY --from=0 /build/public/packs public/packs
COPY --from=0 /build/vendor vendor

# Now we can set up bundler again, using the copied over gems.
RUN bundle config set --local deployment true
RUN bundle config set --local without development test
RUN bundle install

ENV RAILS_ENV="production"

RUN mkdir -p tmp/pids

# Add Tini.
ENV TINI_VERSION v0.19.0
ADD https://github.com/krallin/tini/releases/download/${TINI_VERSION}/tini /tini
RUN chmod +x /tini
ENTRYPOINT ["/tini", "--"]

# Run under tini to ensure proper signal handling.
CMD [ "bundle", "exec", "puma", "-C", "config/puma.rb" ]
