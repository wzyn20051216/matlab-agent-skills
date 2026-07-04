---
name: matlab-signal-vision-ai
description: MATLAB R2026a workflow for signal processing, DSP, image processing, computer vision, lidar, medical imaging, deep learning, and AI-assisted reproducible experiments. Use for filters, spectrograms, wavelets, object detection, segmentation, classification, training, inference, and generated figures.
---

# MATLAB Signal Vision AI

Use this skill when the core artifact is a processed signal, image, video, point cloud, neural network, or AI experiment.

## Workflow

1. Identify data modality, sampling rate, image size, color space, labels, and expected outputs.
2. Confirm toolbox availability before using specialized APIs.
3. Build a tiny reproducible subset first.
4. Save intermediate outputs so failures are inspectable.
5. Validate with numerical metrics, visual artifacts, and data shape checks.

## Preferred APIs

- Signal: `designfilt`, `filter`, `spectrogram`, `pwelch`, `findpeaks`, wavelet functions.
- Vision: `imread`, `im2gray`, `imresize`, `imbinarize`, `regionprops`, `detectSURFFeatures`, `bboxOverlapRatio`.
- Deep learning: `dlnetwork`, `trainnet`, datastores, `minibatchqueue`, pretrained models when licensed.
- Lidar/medical imaging: use domain importers and viewers when available; keep metadata.

## Validation

Choose relevant checks:

- Signal-to-noise ratio, peak frequency, filter stability.
- Image dimensions, pixel range, mask area, IoU, accuracy, F1.
- Training loss decreases on a smoke subset.
- Inference output has expected class names, boxes, or mask shape.
- Exported figure or video is nonempty.

## Reproducibility

Record random seed, split policy, pretrained model version, GPU availability, and dataset hash or URL.
