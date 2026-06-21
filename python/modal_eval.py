"""Modal parallel workflow evaluation."""

from __future__ import annotations

try:
    import modal
except ImportError:
    modal = None

if modal:

    app = modal.App("openhive-eval")
    vol = modal.Volume.from_name("openhive-eval-data", create_if_missing=True)

    @app.function(volumes={"/data": vol}, timeout=300)
    def eval_workflow(workflow_json: str, params: dict) -> dict:
        import json

        wf = json.loads(workflow_json)
        return {"workflow": wf.get("name"), "params": params, "reward": 0.0, "status": "stub"}

    @app.local_entrypoint()
    def main():
        print(eval_workflow.remote("{}", {}))
