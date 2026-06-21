import json
import os
import unittest

os.environ["HOME"] = "/tmp"

import ultraplan
from ultraplan import match_subtask_to_workflow, parse_planner_json


class UltraPlanTests(unittest.TestCase):
    def test_parse_planner_json_valid(self):
        plan = parse_planner_json(
            json.dumps(
                {
                    "summary": "Trip to Italy planning and booking support",
                    "subtasks": [
                        {
                            "id": "subtask_1",
                            "title": "Find flights",
                            "goal": "Find flight options for the Italy trip",
                            "domain": "travel.flights",
                            "requiredInputs": ["origin", "dates", "travelers"],
                            "safety": "stop_before_purchase",
                        }
                    ],
                }
            )
        )

        self.assertEqual(plan["summary"], "Trip to Italy planning and booking support")
        self.assertEqual(plan["subtasks"][0]["id"], "subtask_1")
        self.assertEqual(plan["subtasks"][0]["domain"], "travel.flights")

    def test_parse_planner_json_rejects_invalid(self):
        invalid_values = [
            "",
            "not json",
            "{}",
            json.dumps({"summary": "x", "subtasks": []}),
            json.dumps({"summary": "x", "subtasks": [{"title": "Missing goal"}]}),
        ]
        for raw in invalid_values:
            with self.subTest(raw=raw):
                with self.assertRaises((ValueError, json.JSONDecodeError)):
                    parse_planner_json(raw)

    def test_parse_planner_json_rejects_overlong(self):
        with self.assertRaisesRegex(ValueError, "too large"):
            parse_planner_json(" " + ("x" * 40_001))

    def test_flight_subtask_matches_flight_workflow_metadata(self):
        workflow = {
            "id": "google_flights",
            "name": "Flight Search (Google Flights)",
            "metadata": {
                "domains": ["travel.flights"],
                "capabilities": ["flight_search"],
                "inputSchema": ["origin", "destination", "departDate"],
                "stopCondition": "results_visible",
            },
        }
        subtask = {
            "title": "Find flights",
            "goal": "Find flight options from SFO to Rome",
            "domain": "travel.flights",
        }

        match = match_subtask_to_workflow(subtask, [workflow])

        self.assertIsNotNone(match)
        self.assertEqual(match.workflow["id"], "google_flights")

    def test_non_flight_subtasks_do_not_match_flight_workflow(self):
        workflow = {
            "id": "google_flights",
            "name": "Flight Search (Google Flights)",
            "metadata": {
                "domains": ["travel.flights"],
                "capabilities": ["flight_search"],
            },
        }
        for subtask in [
            {"title": "Find hotels", "goal": "Find hotels in Rome", "domain": "travel.hotels"},
            {"title": "Find attractions", "goal": "Find museums in Florence", "domain": "travel.attractions"},
        ]:
            with self.subTest(subtask=subtask):
                self.assertIsNone(match_subtask_to_workflow(subtask, [workflow]))

    def test_missing_metadata_falls_back_to_name_matching_conservatively(self):
        workflow = {"id": "legacy_flights", "name": "Flight Search Google Flights"}
        flight = {"title": "Find flights", "goal": "Search for flight options", "domain": "travel.flights"}
        hotel = {"title": "Find hotels", "goal": "Search for hotel options", "domain": "travel.hotels"}

        self.assertIsNotNone(match_subtask_to_workflow(flight, [workflow]))
        self.assertIsNone(match_subtask_to_workflow(hotel, [workflow]))


class UltraPlanAsyncTests(unittest.IsolatedAsyncioTestCase):
    async def test_run_ultraplan_with_mocked_planner_and_workflow_runner(self):
        events = []

        async def send(payload):
            events.append(payload)

        async def fake_decompose(goal, context=None):
            return {
                "summary": "Mock plan",
                "subtasks": [
                    {
                        "id": "subtask_1",
                        "title": "Find flights",
                        "goal": "Find flight options from SFO to Rome",
                        "domain": "travel.flights",
                        "requiredInputs": [],
                        "safety": "stop_before_purchase",
                    }
                ],
            }

        class FakeSession:
            async def run_workflow_subtask(self, subtask, workflow, *, max_steps):
                return {"success": True, "steps": 2, "reason": "done"}

        old_decompose = ultraplan.decompose_goal
        ultraplan.decompose_goal = fake_decompose
        try:
            result = await ultraplan.run_ultraplan(
                send,
                "Plan a trip to Italy",
                workflows=[
                    {
                        "id": "google_flights",
                        "name": "Flight Search (Google Flights)",
                        "metadata": {"domains": ["travel.flights"], "capabilities": ["flight_search"]},
                    }
                ],
                session=FakeSession(),
            )
        finally:
            ultraplan.decompose_goal = old_decompose

        self.assertTrue(result["success"])
        self.assertEqual(
            [event["type"] for event in events],
            [
                "ultraplan_started",
                "execute_started",
                "ultraplan_subtask_started",
                "ultraplan_subtask_done",
                "ultraplan_done",
                "execute_done",
            ],
        )


if __name__ == "__main__":
    unittest.main()
