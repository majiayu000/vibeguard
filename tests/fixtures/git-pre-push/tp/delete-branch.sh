#!/bin/bash
# 删除远端分支（local_sha 全零）应被拦截
ZEROS="0000000000000000000000000000000000000000"
echo "refs/heads/feature $ZEROS refs/heads/feature abc123"