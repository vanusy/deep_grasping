% Detection code for grasping (or really anything given different weights)
% using a DBN for scoring
%
% Given an object and background image, finds the object (detected as the
% biggest blob of changed pixels between these) and searches through
% candidate rectangles inside the object's bounding box. 
%
% I, D, BG are the grasping RGB and depth data, as well as a background 
% RGB image. I, BG are h x w x 3 double matrices, D is a h x w double
% matrix.
%
% w's are the DBN weights. Currently hard-coded for two layers, with a
% linear scoring layer on top
%
% means and stds are used to whiten the data. These should be the same
% whitening parameters used for the training data
%
% roAngs, hts, and wds are vectors of candidate rotations, heights, and
% widths to consider for grasping rectangles. Only rectangles with width >=
% height will be considered.
%
% scanStep determines the step size when sweeping the rectangles across
% image space
% 
% Visualizes the search as it runs. Shows the current rectangle (red/blue)
% and the top-ranked rectangle (yellow/green)
% 
% Author: Ian Lenz

function [bestRect,bestScore] = onePassDetectionNormDisplayMod(I, D, BG,w1,w2,wClass,means,stds,rotAngs,hts,wds,scanStep,modes)

addpath ../detectionUtils/
addpath ../../util

PAD_SZ = 20;

% Thresholds to use when transforming masks to convert back to binary
MASK_ROT_THRESH = 0.75;
MASK_RSZ_THRESH = 0.75;

% Fraction of a rectangle which should be masked in as (padded) object for
% a rectangle to be considered
OBJ_MASK_THRESH = 0.5;

FEATSZ = 24;

% Make sure heights and widths are in ascending order, since this is a
% useful property we can exploit to speed some things up
hts = sort(hts);
wds = sort(wds);

% Load grasping data. Loads into a 4-channel image where the first 3
% channels are RGB and the fourth is depth
I(:,:,4) = D;

% Find the object in the image 
[M, bbCorners] = maskInObject(I(:,:,1:3),BG,PAD_SZ);

% Do a little processing on the depth data - find points that Kinect
% couldn't get, and eliminate additional outliers where Kinect gave
% obviously invalid values
D = I(:,:,4);
DMask = D ~= 0;

[D,DMask] = removeOutliersDet(D,DMask,4);
[D,DMask] = removeOutliersDet(D,DMask,4);
D = smartInterpMaskedData(D,DMask);

figure(1);
imshow(uint8(I(:,:,1:3)));
drawnow;

% Work in YUV color
I = rgb2yuv(I(:,:,1:3));

% Pick out the area of the image corresponding to the object's (padded)
% bounding box to work with
objI = I(bbCorners(1,1):bbCorners(2,1),bbCorners(1,2):bbCorners(2,2),:);
objD = D(bbCorners(1,1):bbCorners(2,1),bbCorners(1,2):bbCorners(2,2),:);
objM = M(bbCorners(1,1):bbCorners(2,1),bbCorners(1,2):bbCorners(2,2),:);
objDM = DMask(bbCorners(1,1):bbCorners(2,1),bbCorners(1,2):bbCorners(2,2),:);

bestScore = -inf;

bestAng = -1;
bestW = -1;
bestH = -1;
bestR = -1;
bestC = -1;

% Precompute which widths we need to use with each height so we don't have
% to compute this in an inner loop
useWdForHt = false(length(hts),length(wds));

for i = 1:length(hts)
    useWdForHt(i,:) = wds > hts(i);
end

prevLines = [];
bestLines = [];
barH = [];

IMask = ones(bbCorners(2,1)-bbCorners(1,1)+1,bbCorners(2,2)-bbCorners(1,2)+1);

for curAng = rotAngs
    % Rotate image to match the current angle. Threshold masks to keep them
    % binary
    curI = imrotate(objI,curAng);
    curD = imrotate(objD,curAng);
    curMask = imrotate(objM,curAng) > MASK_ROT_THRESH;
    curDMask = imrotate(objDM,curAng) > MASK_ROT_THRESH;
    curIMask = imrotate(IMask,curAng) > MASK_ROT_THRESH;
    
    % Compute surface normals. Only do this here to avoid having to rotate
    % the normals themselves when we rotate the image (can't just
    % precompute the normals and then rotate the "normal image" since the
    % axes change)
    curN = getSurfNorm(curD);
    
    curRows = size(curI,1);
    curCols = size(curI,2);
    % Going by the r/c dimensions first, then w/h should be more cache
    % efficient since it repeatedly reads from the same locations. Who
    % knows if that actually matters but the ordering's arbitrary anyway
    for r = 1:scanStep:curRows-min(hts)
        for c = 1:scanStep:curCols-min(wds)
            for i = 1:length(hts)
                
                h = hts(i);
                
                % If we ran off the bottom, we can move on to the next col
                if r + h > curRows
                    break;
                end
                
                % Only run through the widths we need to - anything smaller
                % than the current height (as precomputed) doesn't need to
                % be used
                for w = wds(useWdForHt(i,:))
                    
                    % If we run off the side, we can move on to
                    % the next height
                    if c + w > curCols
                        break;
                    end
                    
                    % If the rectangle doesn't contain enough of the
                    % object (plus padding), move on because it's probably
                    % not a valid grasp regardless of score
                    if rectMaskFraction(curMask,r,c,h,w) < OBJ_MASK_THRESH || cornerMaskedOut(curIMask,r,c,h,w)
                        continue;
                    end
                    
                    % Have a valid candidate rectangle
                    % Extract features for the current rectangle into the
                    % format the DBN expects
                    [curFeat, curFeatMask] = featForRect(curI,curD,curN,curDMask,r,c,h,w,FEATSZ,MASK_RSZ_THRESH);
                    curFeat = simpleWhiten(curFeat,means,stds);
                    curFeat = scaleFeatForMask(curFeat, curFeatMask, modes);
                    
                    % Run the features through the DBN and get a score.
                    % Might be more efficient to collect features for a
                    % group of rectangles and run them all at once
                    w1Probs = 1./(1+exp(-[curFeat 1]*w1));
                    w2Probs = 1./(1+exp(-[w1Probs 1]*w2));
                    curScore = [w2Probs 1]* wClass;
                    
                    rectPoints = [r c; r+h c; r+h c+w; r c+w];
                    curRect = localRectToIm(rectPoints,curAng,bbCorners);
                    
                    %figure(1);
                    removeLines(prevLines);
                    prevLines = plotGraspRect(curRect);
                    %delete(barH);
                    %barH = drawScoreBar(curScore,max(bestScore*1.1,1),20,320,30,300);
                    %figure(2);
                    %bar(w2Probs);
                    %axis([0 51 0 1]);
                    drawnow;

                    if curScore > bestScore
                        bestScore = curScore;
                        bestAng = curAng;
                        bestR = r;
                        bestC = c;
                        bestH = h;
                        bestW = w;
                        
                        %figure(1);
                        removeLines(bestLines);
                        bestLines = plotGraspRect(curRect,'g','y');
                        drawnow;
                    end
                end
            end
        end
    end
end

removeLines(prevLines);

% Take the best rectangle params we found and convert to image space
% This is actually a little tricky because the image rotation operation
% isn't straighforward to invert
rectPoints = [bestR bestC; bestR+bestH bestC; bestR+bestH bestC+bestW; bestR bestC+bestW];

bestRect = localRectToIm(rectPoints,bestAng,bbCorners);