"""Backward-compatible access to the default versioned eval dataset."""

from __future__ import annotations

try:
    from .dataset import DEFAULT_DATASET_PATH, load_dataset
except ImportError:
    from dataset import DEFAULT_DATASET_PATH, load_dataset

SAMPLES = load_dataset(DEFAULT_DATASET_PATH)
