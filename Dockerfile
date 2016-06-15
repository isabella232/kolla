FROM python:2.7.11-onbuild
ADD https://github.com/kelseyhightower/confd/releases/download/v0.12.0-alpha3/confd-0.12.0-alpha3-linux-amd64 /usr/bin/confd
ADD ./run.sh /run.sh
ADD ./confd /etc/confd
RUN ./scripts/bootstrap && \
    chmod +x /usr/bin/confd
