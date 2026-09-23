#!/bin/bash
sleep 600
curl -H "Content-Type: application/json" -d '[{
  "labels": {"alertname": "JokeAlert", "severity": "info", "instance": "manual-test"},
  "annotations": {"summary": "冷笑话", "description": "为什么程序员总是分不清万圣节和圣诞节？因为 Oct 31 == Dec 25。"}
}]' \
  http://127.0.0.1:9093/api/v2/alerts
