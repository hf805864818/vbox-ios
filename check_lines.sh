#!/bin/sh
# 备份原始文件
cp /var/minis/workspace/repo_vbox/vbox/Views/PlayerViewsV2.swift /var/minis/workspace/repo_vbox/vbox/Views/PlayerViewsV2.swift.bak
echo "备份完成，大小: $(wc -c < /var/minis/workspace/repo_vbox/vbox/Views/PlayerViewsV2.swift) bytes"
# 检查各个关键段落的行号
echo "=== PlayerState 属性段 ==="
sed -n '60,90p' /var/minis/workspace/repo_vbox/vbox/Views/PlayerViewsV2.swift
echo ""
echo "=== PlayerContainerView ==="
sed -n '420,460p' /var/minis/workspace/repo_vbox/vbox/Views/PlayerViewsV2.swift
echo ""
echo "=== EpisodePickerPanelV2 ==="
sed -n '1036,1065p' /var/minis/workspace/repo_vbox/vbox/Views/PlayerViewsV2.swift
echo ""
echo "=== DanmakuOverlayViewV2 ==="
sed -n '781,845p' /var/minis/workspace/repo_vbox/vbox/Views/PlayerViewsV2.swift