FROM ruby:3.3-slim

WORKDIR /app

COPY Gemfile Gemfile.lock* ./
RUN bundle install --without development test

COPY exporter.rb ./

RUN mkdir -p /export

ENTRYPOINT ["ruby", "exporter.rb"]
