FROM ruby:2.6.4-alpine

RUN apk add --update build-base ruby-dev && mkdir /project

WORKDIR /project

COPY Gemfile /project/

RUN cd /project && bundle install --with jekyll_plugins

COPY build.sh /build.sh

CMD ["/bin/sh", "/build.sh"]
