# Egg camera model (Teachable Machine)

Classes used by `/watch` and the GATE servo:

| Index | Label in `labels.txt` | Camera meaning | GATE |
|------:|----------------------|----------------|------|
| 0 | Empty Model | No egg | Middle |
| 1 | No Crack Egg | Clean | Full left |
| 2 | Crack Egg | Crack | Full right |
| 3 | Dirty Egg | Dirty | Full right |

Files:

- `savedmodel/` — TensorFlow SavedModel loaded by `backend/live_inspection_backend.py`
- `labels.txt` — class names (must stay in this order)
- `keras_model.h5` — original Keras export (reference)

The live backend prefers `models/savedmodel` over any copy in Downloads.
