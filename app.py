"""Lambda handler that scores one AI4I 2020 machine reading.

Route: POST /predict behind an API Gateway HTTP API (payload format 2.0).
"""

from __future__ import annotations

import json
import os
import time
from pathlib import Path
from typing import Literal

import numpy as np
import onnxruntime as ort
from aws_lambda_powertools import Logger, Metrics
from aws_lambda_powertools.event_handler import APIGatewayHttpResolver, Response, content_types
from aws_lambda_powertools.event_handler.openapi.exceptions import RequestValidationError
from aws_lambda_powertools.metrics import MetricUnit
from pydantic import BaseModel, ConfigDict, Field, model_validator

from features import FEATURE_ORDER, build_row

SERVICE = "machine-failure-api"
MODEL_DIR = Path(os.environ.get("MODEL_DIR", Path(__file__).parent / "model"))

logger = Logger(service=SERVICE)
metrics = Metrics(namespace="MachineFailureApi", service=SERVICE)
app = APIGatewayHttpResolver(enable_validation=True)


class Reading(BaseModel):
    """One sensor reading. Bounds reject physically implausible values, not merely rare ones."""

    model_config = ConfigDict(extra="forbid")

    type: Literal["L", "M", "H"]
    air_temp_k: float = Field(ge=250.0, le=350.0)
    process_temp_k: float = Field(ge=250.0, le=400.0)
    rotational_speed_rpm: float = Field(gt=0.0, le=5000.0)
    torque_nm: float = Field(ge=0.0, le=150.0)
    tool_wear_min: float = Field(ge=0.0, le=400.0)

    @model_validator(mode="after")
    def process_not_cooler_than_air(self) -> "Reading":
        # The process heats the machine, so process temperature cannot sit below ambient air.
        if self.process_temp_k < self.air_temp_k:
            raise ValueError("process_temp_k must be greater than or equal to air_temp_k")
        return self


class Prediction(BaseModel):
    failure_probability: float
    failure: bool
    threshold: float
    model_version: str


def _load_model() -> tuple[ort.InferenceSession, str, dict]:
    metadata = json.loads((MODEL_DIR / "metadata.json").read_text())
    if metadata["feature_order"] != list(FEATURE_ORDER):
        raise RuntimeError(
            f"feature order mismatch: metadata={metadata['feature_order']} features.py={list(FEATURE_ORDER)}"
        )
    session = ort.InferenceSession(str(MODEL_DIR / "model.onnx"), providers=["CPUExecutionProvider"])
    return session, session.get_inputs()[0].name, metadata


# Loaded once per container during the init phase, then reused by every warm invocation.
SESSION, INPUT_NAME, METADATA = _load_model()
THRESHOLD = float(METADATA["threshold"])
MODEL_VERSION = METADATA["version"]


@app.exception_handler(RequestValidationError)
def handle_invalid_reading(exc: RequestValidationError) -> Response:
    errors = [{"loc": list(e.get("loc", ())), "msg": e.get("msg", ""), "type": e.get("type", "")} for e in exc.errors()]
    logger.warning("rejected reading", extra={"errors": errors})
    metrics.add_metric(name="InvalidReadings", unit=MetricUnit.Count, value=1)
    return Response(
        status_code=422,
        content_type=content_types.APPLICATION_JSON,
        body=json.dumps({"message": "invalid reading", "errors": errors}),
    )


@app.post("/predict")
def predict(reading: Reading) -> Prediction:
    start = time.perf_counter()
    X = build_row(reading.model_dump())
    _, probabilities = SESSION.run(None, {INPUT_NAME: X})
    probability = float(np.asarray(probabilities)[0, 1])
    flagged = probability >= THRESHOLD
    latency_ms = (time.perf_counter() - start) * 1000.0

    metrics.add_metric(name="Predictions", unit=MetricUnit.Count, value=1)
    metrics.add_metric(name="FailuresFlagged", unit=MetricUnit.Count, value=int(flagged))
    metrics.add_metric(name="InferenceLatency", unit=MetricUnit.Milliseconds, value=latency_ms)
    logger.info("scored reading", extra={"probability": probability, "failure": flagged, "latency_ms": latency_ms})

    return Prediction(
        failure_probability=probability,
        failure=flagged,
        threshold=THRESHOLD,
        model_version=MODEL_VERSION,
    )


@logger.inject_lambda_context(log_event=False)
@metrics.log_metrics
def lambda_handler(event: dict, context) -> dict:
    logger.append_keys(model_version=MODEL_VERSION)
    return app.resolve(event, context)
