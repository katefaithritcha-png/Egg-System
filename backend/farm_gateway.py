"""
REMOVED from the live stack.

cloudflared now targets live_inspection_backend.py on :8000 directly.
Do not run this file — browsers and CAM use https://egg-farm.eggsorting.site only.
"""
from __future__ import annotations

import sys

if __name__ == '__main__':
    print(
        'farm_gateway is retired. Use start-egg-farm.bat '
        '(Cloudflare tunnel → live_inspection_backend on :8000).',
        file=sys.stderr,
    )
    sys.exit(1)
