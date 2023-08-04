FROM ubuntu:23.10

RUN apt-get update && \
    apt-get install -y -q build-essential ruby ruby-dev llvm-16-dev git && \
    gem install bundler

COPY Gemfile /tie/Gemfile
COPY Gemfile.lock /tie/Gemfile.lock
WORKDIR /tie

RUN bundle config set --local deployment 'true' && \
    bundle install

COPY . /tie
