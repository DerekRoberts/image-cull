FROM python:3.12-slim

RUN apt-get update \
    && apt-get install -y --no-install-recommends libheif1 \
    && rm -rf /var/lib/apt/lists/* \
    && useradd -u 10001 -U -d /app -s /usr/sbin/nologin appuser

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY image_cull.py .

USER appuser

HEALTHCHECK NONE

ENTRYPOINT ["python", "image_cull.py"]
