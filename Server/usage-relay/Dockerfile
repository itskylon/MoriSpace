FROM python:3.13-slim

RUN groupadd --gid 10001 relay \
    && useradd --uid 10001 --gid 10001 --no-create-home --shell /usr/sbin/nologin relay \
    && mkdir -p /app /data /run/secrets \
    && chown 10001:10001 /data \
    && chmod 700 /data
WORKDIR /app
COPY relay.py snapshot.py /app/
USER 10001:10001
EXPOSE 48764
VOLUME ["/data"]
HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
    CMD python -B -E -s -c "import http.client; c=http.client.HTTPConnection('127.0.0.1',48764,timeout=2); c.request('GET','/health'); r=c.getresponse(); raise SystemExit(0 if r.status==200 else 1)"
ENTRYPOINT ["python", "-B", "-E", "-s", "-u", "/app/relay.py"]
CMD ["--bind", "0.0.0.0", "--data-dir", "/data", "--config", "/run/secrets/usage.json"]
