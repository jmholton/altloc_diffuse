#! /bin/tcsh -f
#
# example commands for simulating diffuse scatter for the 2-member ensemble of the Untangle Challenge
#


wget https://bl831.als.lbl.gov/~jamesh/challenge/twoconf/sqrtIdiffuse4x_groundtruth.mtz
wget https://bl831.als.lbl.gov/~jamesh/challenge/twoconf/nonoize.mtz
wget https://bl831.als.lbl.gov/~jamesh/challenge/twoconf/ground_truth.pdb
wget https://bl831.als.lbl.gov/~jamesh/challenge/twoconf/lotswrong.pdb
wget https://bl831.als.lbl.gov/~jamesh/challenge/twoconf/longrangetraps.pdb

./confpdb2diffuse_runme.com ground_truth.pdb outfile=sqrtIdiffuse_groundtruth.mtz
#./confpdb2diffuse_runme.com lotswrong.pdb outfile=sqrtIdiffuse_lotswrong.mtz
#./confpdb2diffuse_runme.com longrangetraps.pdb outfile=sqrtIdiffuse_lrt.mtz

./twomtzs2dataset_runme.com ./nonoise.mtz ./sqrtIdiffuse_groundtruth.mtz \
 outprefix=/data/${USER}/fakedata/diffuse/1aho/untangle_gt/360/sample \
  missets=10,20,30 \
  phi_range=360 osc=1 exposure=0.1 \
  background_water_thickness=10e-3 \
  background_air_thickness=20 \
  parallel=1 spot_scale=1 diffuse_scale=1 background_scale=1 \
  seed=1 |& tee twomtz2dataset_nonoise.log
  
./twomtzs2dataset_runme.com ./nonoise.mtz ./sqrtIdiffuse_groundtruth.mtz \
 outprefix=/data/${USER}/fakedata/diffuse/1aho/untangle_gt/360/background \
  missets=10,20,30 \
  phi_range=360 osc=1 exposure=0.1 \
  background_water_thickness=10e-3 \
  background_air_thickness=20 \
  parallel=1 spot_scale=0 diffuse_scale=0 background_scale=1 \
  seed=2 fast=1 |& tee twomtz2dataset_nonoise.log
  
mkdir process
cd process
xia2 data/${USER}/fakedata/diffuse/1aho/untangle_gt/360/


