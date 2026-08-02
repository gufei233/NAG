FROM python:3.12-slim

ARG PIP_INDEX_URL
ARG NAG_DEBIAN_MIRROR

ENV PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1

WORKDIR /app

RUN if [ -n "$NAG_DEBIAN_MIRROR" ]; then \
      find /etc/apt -type f \( -name '*.list' -o -name '*.sources' \) \
        -exec sed -i \
          -e "s|deb.debian.org|$NAG_DEBIAN_MIRROR|g" \
          -e "s|security.debian.org|$NAG_DEBIAN_MIRROR|g" {} +; \
    fi \
 && apt-get update \
 && apt-get install --no-install-recommends -y \
      ffmpeg \
      libcairo2 \
 && rm -rf /var/lib/apt/lists/*

COPY requirements.txt ./
RUN pip install --no-cache-dir -r requirements.txt \
 && pip freeze > /app/constraints.txt

COPY bot.py ./
RUN mkdir -p /app/data /app/plugins

CMD ["python", "bot.py"]
