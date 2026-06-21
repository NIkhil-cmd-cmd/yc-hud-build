"""Modal parallel workflow evaluation with HUD grading."""

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
        import asyncio
        import json

        from hud_grade import grade_execution

        wf = json.loads(workflow_json)
        outcome = {
            "url": params.get("url", "https://www.google.com/travel/flights"),
            "title": params.get("title", wf.get("name", "")),
            "workflowName": wf.get("name", ""),
            "workflowId": wf.get("id", ""),
            "params": params,
            "actionsExecuted": wf.get("actions", []),
            "steps": wf.get("steps", 0),
        }
        grade = asyncio.run(grade_execution(outcome))
        return {
            "workflow": wf.get("name"),
            "params": params,
            "reward": grade.get("reward", 0.0),
            "status": grade.get("status", "unknown"),
        }

    @app.local_entrypoint()
    def main():
        print(eval_workflow.remote("{}", {}))
