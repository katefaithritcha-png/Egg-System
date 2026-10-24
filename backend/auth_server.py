"""Lightweight auth-only server for when the inspection backend is not running."""

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from flask import Flask
from flask_cors import CORS

from auth import init_auth
from security_http import allow_local_browser, cors_origins

app = Flask(__name__)
allow_local_browser(app)
CORS(
    app,
    origins=cors_origins(),
    supports_credentials=False,
    allow_headers=['Authorization', 'Content-Type', 'X-Farm-Device-Token'],
)
init_auth(app)


if __name__ == '__main__':
    print('[auth] Starting authentication server on http://0.0.0.0:8000')
    app.run(host='0.0.0.0', port=8000, debug=False)
