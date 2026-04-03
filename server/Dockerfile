# ── Build stage ───────────────────────────────────────────────────
FROM ghcr.io/astral-sh/uv:python3.12-bookworm-slim AS builder

WORKDIR /app

# Install dependencies first (layer cache)
COPY pyproject.toml uv.lock ./
RUN uv sync --no-dev --no-install-project --frozen

# Install the project itself
COPY src/ src/
RUN uv sync --no-dev --frozen

# ── Runtime stage ────────────────────────────────────────────────
FROM python:3.12-slim-bookworm

WORKDIR /app

# Copy the virtual environment and source from builder
COPY --from=builder /app/.venv /app/.venv
COPY --from=builder /app/src /app/src
ENV PATH="/app/.venv/bin:$PATH"

RUN useradd --system --no-create-home app
USER app

EXPOSE 8000

CMD ["pet-typeless-server"]
