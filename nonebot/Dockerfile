FROM python:3.12-slim

ENV PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1

WORKDIR /app

COPY requirements.txt ./
RUN pip install --no-cache-dir -r requirements.txt \
 && pip freeze > /app/constraints.txt

COPY bot.py ./
RUN mkdir -p /app/data /app/plugins

CMD ["python", "bot.py"]
