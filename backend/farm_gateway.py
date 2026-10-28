"""
Always-on front door for the farm API on :8000.

cloudflared points at http://192.168.11.212:8000. If the real app is bound
directly to :8000, every backend restart produces tunnel ERR lines
("actively refused") for a few seconds.

This gateway stays listening forever and forwards to the app on :8001.
While the app is restarting it still accepts TCP and returns HTTP 503 —
so the tunnel no longer sees connection-refused dial failures.
"""
from __future__ import annotations

import asyncio
import os
import signal

LISTEN_HOST = os.environ.get('FARM_GATEWAY_HOST', '0.0.0.0')
LISTEN_PORT = int(os.environ.get('FARM_GATEWAY_PORT', '8000'))
UPSTREAM_HOST = os.environ.get('FARM_APP_HOST', '127.0.0.1')
UPSTREAM_PORT = int(os.environ.get('FARM_APP_PORT', '8001'))

_STARTING = (
    b'HTTP/1.1 503 Service Unavailable\r\n'
    b'Content-Type: application/json\r\n'
    b'Cache-Control: no-store\r\n'
    b'Connection: close\r\n'
    b'Content-Length: 47\r\n'
    b'\r\n'
    b'{"ok":false,"error":"backend_starting","retry":true}'
)


async def _pipe(src: asyncio.StreamReader, dst: asyncio.StreamWriter) -> None:
    try:
        while True:
            chunk = await src.read(65536)
            if not chunk:
                break
            dst.write(chunk)
            await dst.drain()
    except (ConnectionResetError, BrokenPipeError, asyncio.CancelledError):
        pass
    finally:
        try:
            dst.close()
        except Exception:
            pass


async def _handle(client_r: asyncio.StreamReader, client_w: asyncio.StreamWriter) -> None:
    up_r = up_w = None
    try:
        try:
            up_r, up_w = await asyncio.wait_for(
                asyncio.open_connection(UPSTREAM_HOST, UPSTREAM_PORT),
                timeout=1.5,
            )
        except Exception:
            client_w.write(_STARTING)
            await client_w.drain()
            return
        t1 = asyncio.create_task(_pipe(client_r, up_w))
        t2 = asyncio.create_task(_pipe(up_r, client_w))
        done, pending = await asyncio.wait(
            {t1, t2}, return_when=asyncio.FIRST_COMPLETED,
        )
        for task in pending:
            task.cancel()
        await asyncio.gather(*pending, return_exceptions=True)
    finally:
        for w in (client_w, up_w):
            if w is None:
                continue
            try:
                w.close()
                await w.wait_closed()
            except Exception:
                pass


async def _main() -> None:
    server = await asyncio.start_server(_handle, LISTEN_HOST, LISTEN_PORT)
    sockets = ', '.join(str(s.getsockname()) for s in (server.sockets or []))
    print(
        f'[gateway] listening {sockets} → {UPSTREAM_HOST}:{UPSTREAM_PORT}',
        flush=True,
    )
    print(
        '[gateway] keep this process running; restart only the app on :8001',
        flush=True,
    )
    stop = asyncio.Event()

    def _stop(*_args) -> None:
        stop.set()

    try:
        signal.signal(signal.SIGINT, _stop)
        signal.signal(signal.SIGTERM, _stop)
    except Exception:
        pass
    async with server:
        await stop.wait()


if __name__ == '__main__':
    try:
        asyncio.run(_main())
    except KeyboardInterrupt:
        pass
