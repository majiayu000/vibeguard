#!/usr/bin/env python3
"""Aggregate entry point for the paired with/without rule evaluation tests.

The suite is split by test domain into sibling ``test_paired_*`` modules;
running this module still executes every test so the documented
``python3 eval/test_paired_eval.py`` verify command keeps working.
"""

from __future__ import annotations

import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from test_paired_dataset import DatasetAndIdentityTest  # noqa: E402,F401
from test_paired_judge import JudgeAndVerdictTest  # noqa: E402,F401
from test_paired_real_execution import RealExecutionTest  # noqa: E402,F401
from test_paired_removal import RemovalFixture, RepositoryRemovalTest  # noqa: E402,F401

if __name__ == "__main__":
    unittest.main()
