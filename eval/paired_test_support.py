#!/usr/bin/env python3
"""Shared helpers for the paired evaluation test modules."""

from __future__ import annotations

from unittest.mock import Mock


def sequence_client(replies: list[str]) -> Mock:
    client = Mock()
    client.messages.create.side_effect = [
        type("Response", (), {"content": [type("Block", (), {"text": reply})()]})()
        for reply in replies
    ]
    return client
