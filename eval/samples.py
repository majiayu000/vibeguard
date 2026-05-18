"""Backward-compatible access to the default versioned eval dataset."""

from __future__ import annotations

from dataset import DEFAULT_DATASET_PATH, load_dataset

SAMPLES = load_dataset(DEFAULT_DATASET_PATH)
