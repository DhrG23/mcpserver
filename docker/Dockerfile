FROM python:3.12-slim

WORKDIR /srv

COPY pyproject.toml .
RUN pip install --no-cache-dir fastapi "uvicorn[standard]" "mcp>=2.0" pydantic aiosqlite httpx python-multipart ddgs cryptography

COPY app ./app

ENV PERSONAL_AI_DB_PATH=/data/personal_ai.db
ENV FILES_ROOT=/data/files
ENV BIND_HOST=0.0.0.0

EXPOSE 8000 8001

CMD ["python3", "-m", "app.main"]
