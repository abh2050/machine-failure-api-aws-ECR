import json
from dataclasses import dataclass

import pytest

import app


@dataclass
class FakeContext:
    function_name: str = "machine-failure-api"
    memory_limit_in_mb: int = 512
    invoked_function_arn: str = "arn:aws:lambda:us-east-2:000000000000:function:machine-failure-api"
    aws_request_id: str = "test-request"


BASE_READING = {
    "type": "M",
    "air_temp_k": 298.1,
    "process_temp_k": 308.6,
    "rotational_speed_rpm": 1551,
    "torque_nm": 42.8,
    "tool_wear_min": 0,
}


def http_event(body: dict) -> dict:
    """Build a minimal API Gateway HTTP API (payload 2.0) event for POST /predict."""
    return {
        "version": "2.0",
        "routeKey": "POST /predict",
        "rawPath": "/predict",
        "rawQueryString": "",
        "headers": {"content-type": "application/json"},
        "requestContext": {
            "http": {"method": "POST", "path": "/predict", "protocol": "HTTP/1.1", "sourceIp": "127.0.0.1", "userAgent": "pytest"},
            "requestId": "test-request",
            "routeKey": "POST /predict",
            "stage": "$default",
        },
        "body": json.dumps(body),
        "isBase64Encoded": False,
    }


def invoke(body: dict) -> tuple[int, dict]:
    response = app.lambda_handler(http_event(body), FakeContext())
    return response["statusCode"], json.loads(response["body"])


def test_valid_reading_returns_prediction():
    status, body = invoke(BASE_READING)

    assert status == 200
    assert set(body) == {"failure_probability", "failure", "threshold", "model_version"}
    assert 0.0 <= body["failure_probability"] <= 1.0
    assert body["failure"] is False
    assert body["threshold"] == app.THRESHOLD
    assert body["model_version"] == app.MODEL_VERSION


@pytest.mark.parametrize(
    "override",
    [
        {"air_temp_k": -5.0},
        {"torque_nm": 500.0},
        {"rotational_speed_rpm": 0},
        {"type": "X"},
        {"process_temp_k": 290.0},  # cooler than the 298.1 K ambient air
        {"humidity": 40},  # unknown field
    ],
)
def test_implausible_reading_is_rejected(override):
    status, body = invoke({**BASE_READING, **override})

    assert status == 422
    assert body["message"] == "invalid reading"
    assert body["errors"]


def test_high_torque_with_worn_tool_scores_higher():
    _, healthy = invoke(BASE_READING)
    _, stressed = invoke({**BASE_READING, "rotational_speed_rpm": 1380, "torque_nm": 65.0, "tool_wear_min": 220})

    assert stressed["failure_probability"] > healthy["failure_probability"]
    assert stressed["failure"] is True
