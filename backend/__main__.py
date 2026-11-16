"""Run the API with safe local defaults; demo tokens must never bind to a public interface."""

import os
import uvicorn


if __name__ == "__main__":
    host = os.getenv("HOST", "127.0.0.1")
    if os.getenv("DEMO_MODE", "0") == "1" and host not in {"127.0.0.1", "::1", "localhost"}:
        raise SystemExit("DEMO_MODE is restricted to a loopback interface.")
    uvicorn.run("backend.app:app", host=host, port=int(os.getenv("PORT", "8000")), proxy_headers=False)
