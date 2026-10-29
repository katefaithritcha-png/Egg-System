# Egg camera models

ESP32-CAM pushes JPEG only. Classification runs on the laptop.

| File / folder | Role |
|---------------|------|
| `crackegg.tflite` | **New** YOLO — Crack only (replaces old crack class) |
| `dirty.tflite` | **New** YOLO — Dirty only (replaces old dirty class) |
| `savedmodel/` | **Kept** Teachable Machine — Empty + Clean (No Crack) |
| `labels.txt` | UI labels: Empty / No Crack / Crack / Dirty |

Decision order:
1. If crack TFLite is strong → Crack Egg  
2. Else if dirty TFLite is strong → Dirty Egg  
3. Else Empty vs Clean from `savedmodel/`
