# ── Build stage ───────────────────────────────────────────────────
FROM ghcr.io/astral-sh/uv:python3.12-bookworm-slim AS builder

WORKDIR /app

# Install dependencies first (layer cache)
COPY pyproject.toml ./
RUN uv sync --no-dev --no-install-project

# Install the project itself
COPY src/ src/
RUN uv sync --no-dev

# ── Runtime stage ────────────────────────────────────────────────
FROM python:3.12-slim-bookworm

WORKDIR /app

# Copy the virtual environment from builder
COPY --from=builder /app/.venv /app/.venv
ENV PATH="/app/.venv/bin:$PATH"

EXPOSE 8000

CMD ["pet-typeless-server"]
