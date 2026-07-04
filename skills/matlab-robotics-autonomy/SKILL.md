---
name: matlab-robotics-autonomy
description: MATLAB R2026a robotics and autonomy workflow for ROS Toolbox, Robotics System Toolbox, Navigation Toolbox, UAV Toolbox, sensor fusion, trajectory planning, simulation, and reproducible robot experiments. Use for ROS/ROS 2 bags, robot models, path planning, SLAM, state estimation, and autonomy prototyping.
---

# MATLAB Robotics Autonomy

Use this skill for robotics, autonomy, and ROS workflows.

## Workflow

1. Confirm environment: ROS or ROS 2, bag files, robot model, coordinate frames, sensors, and MATLAB toolboxes.
2. Load data or simulator deterministically.
3. Validate frames, units, timestamps, and message types before algorithms.
4. Build the smallest loop first: read data, process one frame, save one metric.
5. Scale to full trajectory, bag, or simulation only after the small loop passes.

## Preferred APIs

- ROS: `ros2bagreader`, `rosbagreader`, message readers, publishers, subscribers.
- Robotics: `rigidBodyTree`, `inverseKinematics`, `manipulatorRRT`.
- Navigation: occupancy maps, planners, controllers, localization.
- Sensor fusion: Kalman filters, tracking filters, coordinate transforms.
- UAV: scenario, trajectory, and sensor simulation APIs when installed.

## Acceptance Checks

Use at least one:

- Bag metadata and topic count parsed correctly.
- Frame transform chain is valid.
- Path has finite waypoints and no obvious obstacle collision.
- State estimator output has finite covariance.
- Trajectory tracking error is within tolerance.
- Figures or videos are exported with reproducible scripts.

## Risk Checklist

Watch for:

- ENU/NED/body/world frame mixups.
- Degrees vs radians.
- Timestamp drift.
- Sensor rate mismatch.
- ROS domain ID or middleware mismatch.
- Large bag files that need sampled processing.
