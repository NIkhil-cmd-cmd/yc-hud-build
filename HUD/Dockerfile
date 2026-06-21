# HUD platform deploy image — used by `hud deploy HUD` (not OpenHive engine).
FROM python:3.12-slim

WORKDIR /app

RUN apt-get update && apt-get install -y --no-install-recommends \
        git curl ca-certificates \
    && rm -rf /var/lib/apt/lists/*

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY . .

# Bind all interfaces so the platform can reach the control channel.
CMD ["hud", "serve", "env.py", "--host", "0.0.0.0"]
