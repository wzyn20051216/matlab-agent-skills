@echo off
"E:\matlab\bin\matlab.exe" -batch "addpath('E:/desktop/MATLAB/skills/matlab-codegen-deploy/scripts'); addpath('E:/desktop/MATLAB/skills/matlab-codegen-deploy/tests'); test_codegen(true);" > "E:/desktop/MATLAB/artifacts/phase54/evidence/concurrency_regression/20261022_122810/round2_proc2.log" 2>&1
echo %ERRORLEVEL% > "E:/desktop/MATLAB/artifacts/phase54/concurrency_runs/20261022_122810/round2_proc2.exit"
