"""Simple API-token authentication for WebSocket connections.

The client passes the token as a query parameter: ``/ws?token=<TOKEN>``.
"""

from __future__ import annotations

from fastapi import Query, WebSocket, WebSocketException, status


async def authenticate_ws(
    websocket: WebSocket,
    expected_token: str,
    token: str = Query(default=""),
) -> None:
    """Validate the bearer token on a WebSocket upgrade request.

    Raises ``WebSocketException`` with 1008 (policy violation)
    if the token is missing or invalid.
    """
    if not token or token != expected_token:
        raise WebSocketException(
            code=status.WS_1008_POLICY_VIOLATION,
            reason="Invalid or missing API token",
        )
