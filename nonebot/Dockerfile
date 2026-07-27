FROM python:3.12-slim

ENV PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1

WORKDIR /app

RUN apt-get update \
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
