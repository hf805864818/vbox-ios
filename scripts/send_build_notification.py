#!/usr/bin/env python3
"""vbox 构建结果邮件通知脚本

环境变量:
  EMAIL_PASSWORD     SMTP 授权码 (必须)
  JOB_STATUS         构建状态 success/failure (必须)
  MARKETING_VERSION  版本号 (可选)
  BUILD_NUM          构建编号 (可选)
  BUILD_START_TIME   构建开始时间戳 (可选)
"""

import smtplib
import os
import time
import subprocess
import sys
from email.mime.text import MIMEText
from email.mime.multipart import MIMEMultipart

# SMTP 配置 (Foxmail 使用 QQ 邮箱 SMTP 服务)
SMTP_SERVER = "smtp.qq.com"
SMTP_PORT = 465
SMTP_USER = "hfkj88@foxmail.com"
SMTP_PASSWORD = os.environ.get("EMAIL_PASSWORD", "")

TO_EMAIL = "hfkj88@foxmail.com"
REPO_URL = "https://github.com/hf805864818/vbox-ios"


def main():
    if not SMTP_PASSWORD:
        print("❌ 未配置 EMAIL_PASSWORD 环境变量")
        sys.exit(1)

    job_status = os.environ.get("JOB_STATUS", "failure")
    is_success = job_status == "success"
    status_text = "✅ 编译成功" if is_success else "❌ 编译失败"
    status_color = "#34c759" if is_success else "#ff3b30"

    version = os.environ.get("MARKETING_VERSION", "") or "未知"
    build_num = os.environ.get("BUILD_NUM", "") or "未知"

    # 构建时长
    start_time_str = os.environ.get("BUILD_START_TIME", "")
    if start_time_str:
        try:
            start_time = int(start_time_str)
            duration = int(time.time()) - start_time
            minutes = duration // 60
            seconds = duration % 60
            duration_text = f"{minutes}分{seconds}秒"
        except ValueError:
            duration_text = "未知"
    else:
        duration_text = "未知"

    # 提交信息
    try:
        commit_msg = subprocess.check_output(
            ["git", "log", "-1", "--pretty=format:%s"],
            stderr=subprocess.DEVNULL,
        ).decode().strip()
    except Exception:
        commit_msg = "未知"

    # 下载地址（仅成功时）
    download_url = ""
    direct_ipa_url = ""
    if is_success and version != "未知":
        download_url = f"{REPO_URL}/releases/tag/v{version}"
        direct_ipa_url = f"{REPO_URL}/releases/download/v{version}/vbox.ipa"

    # 构建 HTML 邮件
    rows = [
        ("构建状态", f'<span style="color: {status_color}; font-weight: bold; font-size: 16px;">{status_text}</span>'),
        ("版本号", f"v{version} (build {build_num})"),
        ("提交信息", commit_msg),
        ("构建时长", duration_text),
    ]
    if download_url:
        rows.append(("Release 页面", f'<a href="{download_url}">{download_url}</a>'))
    if direct_ipa_url:
        rows.append(("IPA 下载", f'<a href="{direct_ipa_url}">{direct_ipa_url}</a>'))

    table_rows = "".join(
        f'<tr>'
        f'<td style="padding: 10px 16px; border: 1px solid #e0e0e0; font-weight: bold; background: #f5f5f5; width: 130px; white-space: nowrap;">{label}</td>'
        f'<td style="padding: 10px 16px; border: 1px solid #e0e0e0;">{value}</td>'
        f'</tr>'
        for label, value in rows
    )

    html = f"""\
<html><body style="font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', 'PingFang SC', sans-serif; max-width: 640px; margin: 0 auto; padding: 20px;">
<h2 style="color: {status_color}; border-bottom: 2px solid {status_color}; padding-bottom: 10px;">vbox {status_text}</h2>
<table style="border-collapse: collapse; width: 100%; margin-top: 12px;">
{table_rows}
</table>
<p style="color: #999; margin-top: 24px; font-size: 12px;">此邮件由 GitHub Actions 自动发送，请勿直接回复。</p>
</body></html>"""

    # 发送邮件
    subject = f"vbox{status_text} - v{version} (build {build_num})"
    msg = MIMEMultipart("alternative")
    msg["Subject"] = subject
    msg["From"] = f"vbox-ci <{SMTP_USER}>"
    msg["To"] = TO_EMAIL
    msg.attach(MIMEText(html, "html", "utf-8"))

    try:
        with smtplib.SMTP_SSL(SMTP_SERVER, SMTP_PORT, timeout=30) as server:
            server.login(SMTP_USER, SMTP_PASSWORD)
            server.send_message(msg)
        print(f"✅ 邮件发送成功: {subject}")
    except Exception as e:
        print(f"❌ 邮件发送失败: {e}")
        sys.exit(1)


if __name__ == "__main__":
    main()
