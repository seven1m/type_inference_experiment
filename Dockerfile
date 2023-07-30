FROM ubuntu:23.10

RUN apt-get update && \
    apt-get install -y -q build-essential ruby ruby-dev llvm-16-dev && \
    gem install bundler

COPY . /tie
WORKDIR /tie

RUN bundle config set --local deployment 'true' && \
    bundle install
