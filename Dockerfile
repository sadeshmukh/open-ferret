FROM ruby:3.4-slim AS builder

WORKDIR /app

COPY Gemfile ./
RUN apt-get update && \
    apt-get install -y --no-install-recommends build-essential && \
    bundle config set --local force_ruby_platform true && \
    bundle install --jobs 4 && \
    rm -rf /usr/local/bundle/cache/*.gem && \
    find /usr/local/bundle/gems -name "*.c" -o -name "*.o" | xargs rm -f

FROM ruby:3.4-slim

RUN rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY --from=builder /usr/local/bundle /usr/local/bundle
COPY . .
RUN chmod +x bin/*

RUN mkdir -p data

EXPOSE 4567

CMD ["bundle", "exec", "ruby", "app.rb"]
