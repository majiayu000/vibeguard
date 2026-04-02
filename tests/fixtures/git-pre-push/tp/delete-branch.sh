#!/bin/bash
# Deleting remote branches (local_sha all zeros) should be intercepted
ZEROS="0000000000000000000000000000000000000000"
echo "refs/heads/feature $ZEROS refs/heads/feature abc123"