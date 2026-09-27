"""Feature engineering shared by training and serving.

This module is the single source of truth for the model inputs. It depends on
numpy only, so the Lambda image can import it without pandas or scikit-learn.
"""

from __future__ import annotations

import math
from typing import Mapping, Sequence

import numpy as np

FEATURE_ORDER: tuple[str, ...] = (
    "type_code",
    "air_temp_k",
    "process_temp_k",
    "rotational_speed_rpm",
    "torque_nm",
    "tool_wear_min",
    "power_w",
    "temp_delta_k",
    "overstrain_nm_min",
)

# Product quality variant: L (low), M (medium), H (high).
TYPE_CODES: dict[str, int] = {"L": 0, "M": 1, "H": 2}

RAW_FIELDS: tuple[str, ...] = (
    "type",
    "air_temp_k",
    "process_temp_k",
    "rotational_speed_rpm",
    "torque_nm",
    "tool_wear_min",
)

_RAD_PER_SEC_PER_RPM = 2.0 * math.pi / 60.0


def build_matrix(raw: Mapping[str, Sequence]) -> np.ndarray:
    """Return a float32 matrix with columns in FEATURE_ORDER.

    `raw` maps each name in RAW_FIELDS to an equal length sequence. The `type`
    values must be one of the keys in TYPE_CODES.
    """
    missing = [name for name in RAW_FIELDS if name not in raw]
    if missing:
        raise KeyError(f"missing raw fields: {missing}")

    try:
        type_code = np.array([TYPE_CODES[t] for t in raw["type"]], dtype=np.float64)
    except KeyError as exc:
        raise ValueError(f"unknown machine type {exc.args[0]!r}") from None

    air = np.asarray(raw["air_temp_k"], dtype=np.float64)
    process = np.asarray(raw["process_temp_k"], dtype=np.float64)
    rpm = np.asarray(raw["rotational_speed_rpm"], dtype=np.float64)
    torque = np.asarray(raw["torque_nm"], dtype=np.float64)
    wear = np.asarray(raw["tool_wear_min"], dtype=np.float64)

    columns = {
        "type_code": type_code,
        "air_temp_k": air,
        "process_temp_k": process,
        "rotational_speed_rpm": rpm,
        "torque_nm": torque,
        "tool_wear_min": wear,
        "power_w": torque * rpm * _RAD_PER_SEC_PER_RPM,
        "temp_delta_k": process - air,
        "overstrain_nm_min": torque * wear,
    }
    return np.column_stack([columns[name] for name in FEATURE_ORDER]).astype(np.float32)


def build_row(reading: Mapping[str, object]) -> np.ndarray:
    """Return a (1, n_features) float32 matrix for a single reading."""
    return build_matrix({name: [reading[name]] for name in RAW_FIELDS})
