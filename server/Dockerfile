FROM python:3.11-slim

# No special system deps needed — 豆包 ASR uses pure Python websockets
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Install uv
RUN pip install --no-cache-dir uv

WORKDIR /app

# Copy dependency files first for better caching
COPY pyproject.toml uv.lock ./

# Copy source code
COPY src/ src/

# Install dependencies
RUN uv sync

EXPOSE 8000

CMD ["uv", "run", "pet-typeless-server"]
