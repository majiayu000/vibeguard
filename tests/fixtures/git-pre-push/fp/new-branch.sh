#!/bin/bash
# The new remote branch (remote_sha all zeros) should be allowed
ZEROS="0000000000000000000000000000000000000000"
echo "refs/heads/feature abc123 refs/heads/feature $ZEROS"