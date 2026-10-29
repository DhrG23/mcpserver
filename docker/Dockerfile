FROM python:3.12-slim

WORKDIR /srv

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY app ./app

ENV PERSONAL_AI_DB_PATH=/data/personal_ai.db \
    FILES_ROOT=/data/files \
    BIND_HOST=0.0.0.0 \
    FORWARDED_ALLOW_IPS=*

# Ports are published only to the Caddy container (see docker-compose.yml), never to the host.
EXPOSE 8000 8001

CMD ["python3", "-m", "app.main"]
