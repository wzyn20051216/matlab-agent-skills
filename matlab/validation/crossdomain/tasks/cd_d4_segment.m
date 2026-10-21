function out = cd_d4_segment()
%CD_D4_SEGMENT  Image processing: segmentation with a known-by-construction answer.
%
% INDEPENDENT REFERENCE
%   The test image is synthetic: two axis-aligned rectangles are PAINTED into a
%   blank canvas, so their areas are known exactly (20x30 = 600 and 10x10 = 100)
%   and their centroid positions are known. The segmentation is graded against
%   those integers, not against whatever regionprops happens to return.

H = 64; W = 64;
img = false(H, W);
img(11:30, 21:50) = true;      % 20 x 30 = 600
img(41:50, 11:20) = true;      % 10 x 10 = 100

% a little dropout so the task is not a trivial copy: remove one pixel row block
% inside the first rectangle, and require the algorithm to report it honestly
img(15:16, 30:33) = false;     % removes 2*4 = 8 pixels from the first object

lab = bwlabel(img, 8);
st  = regionprops(lab, 'Area', 'Centroid');
area = sort([st.Area], 'descend');

refArea = [600-8, 100];
% regionprops returns Centroid as [x y] = [COLUMN ROW], not [row col]. Comparing
% it against [row col] failed a correct segmentation by ~15 px.
refCentroid = [ (21+50)/2, (11+30)/2 ];   % [col row] of the LARGE object

% bwlabel numbers objects in scan order (column-major), so st(1) is the object
% with the SMALLEST column index -- here the small rectangle at cols 11-20, not
% the large one. The first version assumed st(1) was the large object and failed
% a correct segmentation. Match by AREA instead of by index.
[~, iBig] = max([st.Area]);
cBig = st(iBig).Centroid;

ok = numel(area) == 2 && all(abs(area - refArea) <= 1) && ...
     abs(cBig(1) - refCentroid(1)) < 1.5 && abs(cBig(2) - refCentroid(2)) < 1.5;

out.values = struct('areas',area,'nObjects',numel(area),'centroidBig',cBig);
out.reference = struct('areas',refArea,'centroidBig',refCentroid);
out.status = tern(ok,'PASS','FAIL');
out.detail = sprintf('%d objects, areas [%s] vs ref [%s]', numel(area), ...
    num2str(area), num2str(refArea));
end

function s = tern(c,a,b)
if c, s = a; else, s = b; end
end
