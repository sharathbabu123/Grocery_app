import numpy as np
import tensorflow as tf
from PIL import Image
from pathlib import Path

# --- CONFIGURATION ---
# Resolve paths relative to this script's directory
BASE_DIR = Path(__file__).parent.resolve()
MODEL_PATH = BASE_DIR / 'grocery_model.tflite'
LABELS_PATH = BASE_DIR / 'labels.txt'

# Collect all JPG/JPEG images in this folder
IMAGE_PATHS = sorted(list(BASE_DIR.glob('*.jpg')) + list(BASE_DIR.glob('*.jpeg')))
if not IMAGE_PATHS:
    print('No JPG images found in', BASE_DIR)
    raise SystemExit(0)

# Load the labels
with open(LABELS_PATH, 'r') as f:
    labels = [line.strip() for line in f.readlines()]

# Load the TFLite model and get its details
interpreter = tf.lite.Interpreter(model_path=str(MODEL_PATH))
interpreter.allocate_tensors()
input_details = interpreter.get_input_details()[0]
output_details = interpreter.get_output_details()[0]

# --- THIS IS THE MOST IMPORTANT PART ---
# Print the exact input details the model expects
print("--- Model Input Details ---")
print(f"  Shape: {input_details['shape']}")  # e.g., [1, 224, 224, 3]
print(f"  Data Type: {input_details['dtype']}")  # e.g., <class 'numpy.float32'>
print("---------------------------")

# Get the required input size from the model details
_, height, width, _ = input_details['shape']

def preprocess(img_path):
    img_original = Image.open(img_path).convert('RGB')
    img_resized = img_original.resize((width, height))
    arr = np.asarray(img_resized)
    arr = np.expand_dims(arr, axis=0)
    if input_details['dtype'] == np.float32:
        # Normalize to [-1, 1]; adjust if your model expects 0..1
        arr = (arr.astype(np.float32) - 127.5) / 127.5
    return arr

def topk(scores, k=5):
    idx = np.argsort(scores)[-k:][::-1]
    return [(int(i), float(scores[i])) for i in idx]

# Run inference on all images
for img_path in IMAGE_PATHS:
    input_data = preprocess(img_path)
    interpreter.setTensor = interpreter.set_tensor  # convenience alias if desired
    interpreter.setTensor(input_details['index'], input_data)
    interpreter.invoke()
    output_data = interpreter.get_tensor(output_details['index'])
    scores = output_data[0]

    print(f"\n--- Top 5 Predictions for {img_path.name} ---")
    for i, score in topk(scores, 5):
        label = labels[i] if i < len(labels) else f'class_{i}'
        print(f"  - {label:<20}: {score:.4f}")
