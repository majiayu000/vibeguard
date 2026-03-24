#!/bin/bash
# 新建远端分支（remote_sha 全零）应放行
ZEROS="0000000000000000000000000000000000000000"
echo "refs/heads/feature abc123 refs/heads/feature $ZEROS"