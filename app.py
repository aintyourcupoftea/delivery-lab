import asyncio
import os
import threading

import uvicorn
from fastapi import FastAPI
from fastapi.responses import JSONResponse

# Flipped to False on SIGTERM so readiness starts failing while the server is
# still accepting connections. See GracefulServer below for why that matters.
_accepting_traffic = True

app = FastAPI()


@app.get("/")
async def index():
    return {
        "service": "delivery-lab",
        "version": os.getenv("APP_VERSION", "dev"),
    }


@app.get("/health/live")
async def live():
    """Liveness: is this process itself wedged?

    Deliberately has no dependencies and no shutdown awareness - a pod that is
    draining is still alive and must not be killed by the kubelet mid-drain.
    """
    return {"alive": True}


@app.get("/health/ready")
async def ready():
    """Readiness: should this pod receive traffic right now?"""
    if not _accepting_traffic:
        return JSONResponse({"ready": False, "reason": "shutting down"}, status_code=503)
    if os.getenv("READY", "true") != "true":
        return JSONResponse({"ready": False, "reason": "READY=false"}, status_code=503)
    return {"ready": True}


@app.get("/work")
async def work():
    await asyncio.sleep(float(os.getenv("WORK_DELAY", "0")))
    return {"ok": True}


class GracefulServer(uvicorn.Server):
    """Adds a lame-duck window to uvicorn's shutdown.

    Plain uvicorn closes its listening socket the instant it gets SIGTERM. In
    Kubernetes that is a race: endpoint removal and SIGTERM happen
    concurrently, so for a moment kube-proxy is still sending connections to a
    socket that has already closed - the user sees connection refused, not a
    graceful drain.

    So on the first SIGTERM this does NOT shut down. It flips readiness to 503
    and keeps serving for DRAIN_SECONDS, which is what actually lets the
    endpoints controller and every proxy notice and stop routing here. Only
    then does uvicorn begin its own graceful shutdown of in-flight requests.

    A second SIGTERM exits immediately, so the shutdown is still interruptible.
    """

    def handle_exit(self, sig, frame):
        global _accepting_traffic
        drain = float(os.getenv("DRAIN_SECONDS", "5"))
        if _accepting_traffic and drain > 0:
            _accepting_traffic = False
            print(f"SIGTERM received: readiness now 503, draining for {drain}s", flush=True)
            threading.Timer(
                drain, lambda: uvicorn.Server.handle_exit(self, sig, frame)
            ).start()
            return
        uvicorn.Server.handle_exit(self, sig, frame)


if __name__ == "__main__":
    config = uvicorn.Config(
        app,
        host="0.0.0.0",
        port=int(os.getenv("PORT", "8080")),
        # Give in-flight /work requests time to finish before the worker exits.
        timeout_graceful_shutdown=int(os.getenv("GRACEFUL_TIMEOUT", "20")),
        access_log=True,
    )
    GracefulServer(config).run()
