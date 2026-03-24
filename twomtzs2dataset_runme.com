#! /bin/tcsh -f
#
#  quick and dirty script to render Bragg data with diffuse scatter background     - James Holton 8-22-25
#
set braggmtz = "Bragg.mtz"
set diffusemtz = "sqrtIdiffuse.mtz"

set outprefix = /data/${USER}/fakedata/diffuse/fake_1

# rendering parameters
set seed = 0
set overall_scale = 1
set spot_scale = 1
set diffuse_scale = 1
set background_scale = 1
set phi_range = 360
set osc = 1
set beam = ""
set extrargs = ""

# crystal properties
set missets = ( 0 0 0 )
set mosaic = 0.2
set xtalsize = 100e-3
set domainsize = 0.05e-3
set reso = 1.0
# default is to read these from mtz file
set CELL = ()
set SG = ""
set F000 = 1000

# background properties
set background_air_thickness = 25
set background_water_thickness = 100e-3

# beamline properties
set distance = 200
set wavelength = 1
set flux = 1e12
set exposure = 0.1
set beamsize = 100e-3
set dispersion = 0.2
set horizontal_divergence = 0.1
set vertical_divergence = 0.1

# these impact speed and accuracy of spots
set oversample = 1
set phisteps = 50
set ds_phisteps = 1
set mosaic_domains = 5
set dispersion_steps            = 1
set horizontal_divergence_steps = 1
set vertical_divergence_steps   = 1

# cluster and compute options
set parallel = 0
set sruncpu = "srun --cpus-per-task=20"
set srungpu = "srun --partition=gpu --gres=gpu:1"
set CUDA = CUDA
set wget = "wget --no-check-certificate"

set debug = 0
set fast = 0

set tempfile = /dev/shm/${USER}/temp_m2d_$$_
mkdir -p /dev/shm/${USER}
mkdir -p ${CCP4_SCR}
if( ! -e /dev/shm/${USER}) set tempfile = ./tempfile_m2d_$$_

set logfile = details.log

if(-e simulation_parameters.sourceme) source simulation_parameters.sourceme

echo "command-line arguments: $* "

foreach Arg ( $* )
    set arg = `echo $Arg | awk '{print tolower($0)}'`
    set assign = `echo $arg | awk '{print ( /=/ )}'`
    set Key = `echo $Arg | awk -F "=" '{print $1}'`
    set Val = `echo $Arg | awk '{print substr($0,index($0,"=")+1)}'`
    set Csv = `echo $Val | awk 'BEGIN{RS=","} {print}'`
    set key = `echo $Key | awk '{print tolower($1)}'`
    set num = `echo $Val | awk '{print $1+0}'`
    set int = `echo $Val | awk '{print int($1+0)}'`

    if( $assign ) then
      # special
      if("$key" =~ misset* && $#Csv == 3 ) then
          set missets = ( $Csv )
          continue
      endif
      # re-set any existing variables
      set test = `set | awk -F "\t" '{print $1}' | egrep "^${Key}"'$' | wc -l`
      if ( $test ) then
          set $Key = $Val
          echo "$Key = $Val"
          continue
      endif
      # synonyms
      if("$key" == "output" || "$key" == "outprefix") set outfile = "$Val"
      if("$key" == "lambda" ) set wavelength = "$Val"
      if("$key" == "mosaicity" ) set mosaic = "$Val"
      if("$key" == "mosaic_spread" ) set mosaic = "$Val"
      if("$key" == "mosaic_steps" ) set mosaic_domains = "$Val"
    else
      # no equal sign
      if("$Arg" =~ *.mtz && "$arg" !~ *diff* ) set braggmtz = "$Arg"
      if("$Arg" =~ *.mtz && "$arg" =~ *diff* ) set diffusemtz = "$Arg"
    endif
    if("$arg" == "debug") set debug = "1"
end

if( $debug && $tempfile =~ /dev/shm/* ) set tempfile = ./tempfile_m2d_

set t = "$tempfile"

# calculate volume multiplier from one mosaic domain to all
set xtal_scale = `echo $xtalsize $domainsize | awk '{print ($1/$2)**3}'`
set missets = `echo $missets | awk 'BEGIN{RS=","} {print}'`

if(! -e "$braggmtz" || ! -e "$diffusemtz" ) then
    set BAD = "need two mtz files: Bragg.mtz and sqrtIdiffuse.mtz"
    goto exit
endif

if( $fast > 99 ) then
    echo "fast > 99 so switching to fast-rendering nanoBragg settings"

    set dispersion = 0
    set horizontal_divergence = 0
    set vertical_divergence = 0
    set mosaic = 0

    # these impact speed and accuracy of spots
    set oversample = 1
    set phisteps = 10
    set ds_phisteps = 1
    set mosaic_domains = 1
    set dispersion_steps            = 1
    set horizontal_divergence_steps = 1
    set vertical_divergence_steps   = 1

endif


set path = ( . $path )

echo "testing slurm"
set test = `echo setenv | $sruncpu tcsh -f |& grep SLURM | wc -l`
if( ! $test ) then
    echo "no slurm detected"
    set sruncpu = ""
else
    set test = `$srungpu nvidia-smi |& grep CUDA | wc -l`
    if( ! $test ) then
        echo "no gpus in slurm"
        set srungpu = ""
    endif
endif
if( "$srungpu" != "" ) then
  echo "slurm good"
else
  set test = `nvidia-smi |& grep CUDA | wc -l`
  if( ! $test ) set CUDA = ""
endif


foreach file ( nanoBragg nonBragg noisify float_add int2cbf )
if( ! -x $file ) then
   echo "getting and compiling $file "
   $wget https://bl831.als.lbl.gov/~jamesh/nanoBragg/${file}.c
   $sruncpu gcc -o ${file} ${file}.c -lm -fopenmp -static-libgcc
endif
end
foreach file ( nanoBraggCUDA mtz_to_P1hkl.com UBtoA.awk water.stol air.stol )
if( ! -x $file ) then
   echo "getting $file"
   $wget https://bl831.als.lbl.gov/~jamesh/nanoBragg/$file
   chmod a+x $file
endif
end

foreach file ( nanoBragg nonBragg noisify int2cbf mtz_to_P1hkl.com UBtoA.awk water.stol air.stol )
    if( ! -x "$file" ) then
        set BAD = "cannot find $file"
        goto exit
    endif
end

# try a quick cuda job
set test = `$srungpu nanoBraggCUDA |& grep Holton | wc -l`
if( ! $test) set CUDA = ""
if( "$CUDA" != "CUDA" ) set CUDA = ""
if( "$CUDA" == "" ) then
   echo "no CUDA"
else
   echo "CUDA works"
endif

#############
cat << EOF

settings:

braggmtz = $braggmtz
diffusemtz = $diffusemtz
outprefix = $outprefix
seed = $seed

overall_scale = $overall_scale
spot_scale = $spot_scale
diffuse_scale = $diffuse_scale
background_scale = $background_scale

phi_range = $phi_range
osc = $osc

beam = $beam
missets = $missets deg
mosaic = $mosaic deg
xtalsize = $xtalsize mm
domainsize = $domainsize mm
F000 = $F000 e-

background_air_thickness = $background_air_thickness mm
background_water_thickness = $background_water_thickness mm

distance = $distance mm
wavelength = $wavelength A
flux = $flux ph/s
exposure = $exposure s
beamsize = $beamsize mm
dispersion = $dispersion %
horizontal_divergence = $horizontal_divergence mrad
vertical_divergence = $vertical_divergence mrad

oversample = $oversample
phisteps = $phisteps
ds_phisteps = $ds_phisteps
mosaic_domains = $mosaic_domains
dispersion_steps = $dispersion_steps
horizontal_divergence_steps = $horizontal_divergence_steps
vertical_divergence_steps = $vertical_divergence_steps

sruncpu = $sruncpu
srungpu = $srungpu
CUDA = $CUDA
wget = $wget

debug = $debug
fast = $fast
parallel = $parallel
tempfile = $tempfile

EOF
set totaltime = `echo $exposure $phi_range $osc | awk '{print $1*$2/$3}'`
set totaldose = `echo $flux $beamsize $totaltime $wavelength | awk '{sq_um=($2*1000)^2;print $1/sq_um*$3/(2000./($4*$4))/1e6}'`
echo "dataset dose: $totaldose MGy"

set test = `echo $phi_range | awk '{print ( $1+0<=0 )}'`
if( $test ) then
  set BAD = "invalid phi range"
  goto exit
endif


if(! -w .) then
  set BAD = "cannot write to current working directory."
  goto exit
endif


set braggCELL = `echo header | mtzdump hklin $braggmtz | awk '/Cell Dimensions/{getline;getline;print}'`
set bigCELL = `echo header | mtzdump hklin $diffusemtz | awk '/Cell Dimensions/{getline;getline;print}'`

if( $#braggCELL != 6 ) then
   set BAD = "bad Bragg cell: $braggCELL"
   goto exit
endif
if( $#bigCELL != 6 ) then
   set BAD = "bad diffuse cell: $bigCELL"
   goto exit
endif


if($fast > 0 && -e Bragg.hkl) then
  echo "re-using Bragg.hkl"
else
  echo "converting $braggmtz to Bragg.hkl"
  mtz_to_P1hkl.com $braggmtz >> $logfile
  echo "0 0 0 $F000" >> P1.hkl
  awk '$4>0' P1.hkl >! Bragg.hkl
endif

if($fast > 0 && -e sqrt_ds.hkl) then
  echo "re-using sqrt_ds.hkl"
else 
  echo "converting $diffusemtz to sqrt_ds.hkl"
  mtz_to_P1hkl.com $diffusemtz  >> $logfile
#  echo "0 0 0 100" >> P1.hkl
  awk '$4>0' P1.hkl >! sqrt_ds.hkl
endif

echo "generating orientation matricies with missetting angles: $missets"
UBtoA.awk << EOF >! Abragg.mat
CELL $braggCELL
MISSET $missets
EOF

UBtoA.awk << EOF >! Adiff.mat
CELL $bigCELL
MISSET $missets
EOF

if( $fast > 9 && -e background.bin ) goto skipbg

echo "generating background: air: $background_air_thickness mm, water: $background_water_thickness mm"
# make the water background.  Only need to do this once
nonBragg -stol water.stol \
  -thick $background_water_thickness -noprogress \
  -detpixels_f 2463 -detpixels_s 2527 -pixel 0.172 \
  $beam \
  -distance $distance \
  -wavelength $wavelength \
  -flux $flux -beamsize $beamsize -exposure $exposure \
  -nonoise -nopgm \
  -floatfile water.bin | tee water.log >> $logfile
if( $status ) then
    set BAD = "could not render water scatter with ./nonBragg"
    goto exit
endif

# make the air background.  Only need to do this once
nonBragg -stol air.stol \
  -thick $background_air_thickness -density 1.2e-3 -MW 28 -noprogress \
  -detpixels_f 2463 -detpixels_s 2527 -pixel 0.172 \
  $beam \
  -distance $distance \
  -wavelength $wavelength \
  -flux $flux -beamsize $beamsize -exposure $exposure \
  -nonoise -nopgm \
  -floatfile air.bin | tee air.log  >> $logfile
if( $status ) then
    set BAD = "could not render air scatter with ./nonBragg"
    goto exit
endif

float_add water.bin air.bin \
      -output background.bin >> $logfile
if( $status ) then
    set BAD = "could not run float_add"
    goto exit
endif

skipbg:


set nframes = `echo $phi_range $osc | awk '{print int($1/$2)}'`
set test = `echo $nframes | awk '{print ( $1+0<=0 )}'`
if( $test ) then
  set BAD = "invalid number of frames: $nframes"
  goto exit
endif
echo "will make $nframes diffraction patterns as ${outprefix}_#####.cbf"
set outdir = `dirname $outprefix`
mkdir -p $outdir
if(! -w $outdir) then
  set BAD = "cannot write to $outdir"
  goto exit
endif

if( $fast == 0 ) rm -f Fdump.bin >& /dev/null
foreach n ( `seq 1 $nframes` )

set num = `echo $n | awk '{printf("%05d",$1)}'`
set phi = `echo $num $osc | awk '{print $2*($1-1)}'`

if(-e ${outprefix}_${num}.cbf && $fast > 10 ) then
   echo "${outprefix}_${num}.cbf already exists."
   continue
endif

if($fast > 10 && -e fullsum_${num}.bin) continue
if($fast > 2 && -e osc_spots_${num}.bin ) continue

echo -n "rendering image $n spots : "

set hkl = "-hkl Bragg.hkl"
if( $fast > 0 && -e Fdump.bin ) set hkl = ""
rm -f osc_spots_${num}.bin >& /dev/null
$srungpu nanoBragg$CUDA $hkl -dump Fdump.bin \
    -mat Abragg.mat -tophat_spots -nonoise -nopgm \
    -detpixels_f 2463 -detpixels_s 2527 -pixel 0.172 \
    $beam \
    -distance $distance -lambda $wavelength \
    -phi $phi -osc $osc -phisteps $phisteps \
    -beamsize $beamsize -flux $flux -exposure $exposure \
    -xtalsize $domainsize \
    -tophat_spots -nointerpolate -noprogress \
    -mosaic $mosaic -mosaic_domains $mosaic_domains \
    -dispersion $dispersion -dispsteps $dispersion_steps \
    -hdivrange $horizontal_divergence -hdivsteps $horizontal_divergence_steps \
    -vdivrange $vertical_divergence -vdivsteps $vertical_divergence_steps \
    -oversample $oversample \
    -floatimage osc_spots_${num}.bin \
    -intimage osc_spots_${num}.img \
    $extrargs >&! render_spots_${num}.log &
    
    if(! $parallel || ( $n == 1 && ! -e Fdump.bin ) ) wait
end

echo "diffuse "

if( $fast == 0 ) rm -f DSdump.bin >& /dev/null
foreach n ( `seq 1 $nframes` )

set num = `echo $n | awk '{printf("%05d",$1)}'`
set phi = `echo $num $osc | awk '{print $2*($1-1)}'`

if(-e ${outprefix}_${num}.cbf && $fast > 10 ) then
   echo "${outprefix}_${num}.cbf already exists."
   continue
endif
if($fast > 10 && -e fullsum_${num}.bin) continue
if($fast > 2 && -e diffuse_${num}.bin ) continue

echo -n "rendering image $n diffuse : "

set hkl = "-hkl sqrt_ds.hkl"
if( $fast > 0 && -e DSdump.bin ) set hkl = ""
#setenv OMP_NUM_THREADS 1
rm -f diffuse_${num}.bin >& /dev/null
$sruncpu nanoBragg $hkl -N 1 -dump DSdump.bin \
    -mat Adiff.mat -nonoise -nopgm \
    -detpixels_f 2463 -detpixels_s 2527 -pixel 0.172 \
    $beam \
    -distance $distance -lambda $wavelength \
    -phi $phi -osc $osc -phisteps $ds_phisteps \
    -beamsize $beamsize -flux $flux -exposure $exposure \
    -oversample 1 \
    -floatimage diffuse_${num}.bin \
    -intimage diffuse_${num}.img \
    $extrargs >&! render_ds_${num}.log &

    if(! $parallel || ( $n == 1 && ! -e DSdump.bin ) ) wait
end
echo "waiting for rendering jobs ..."
wait

combine:
set Ncells = `awk '$2=="xtal:"{print $3}' render_spots_00001.log | awk -F "x" '{print $1*$2*$3}'`
echo "mosaic domain of Bragg rendering was $Ncells x larger than that of diffuse rendering; compensating"
set scale2 = `echo $diffuse_scale $Ncells | awk '{print $1*$2}'`
#set scale = `echo $xtal_scale $overall_scale | awk '{print $1*$2}'`

echo "summations..."
foreach n ( `seq 1 $nframes` )
set num = `echo $n | awk '{printf("%05d",$1)}'`

if( ! -e osc_spots_${num}.bin ) then
    set BAD = "failed to render spots for $num with ./nanoBragg$CUDA "
    goto exit
endif
if( ! -e diffuse_${num}.bin ) then
    set BAD = "failed to render diffuse scatter for $num with ./nanoBragg"
    goto exit
endif
if($fast > 10 && -e bdsum_${num}.bin) continue

$sruncpu float_add -nostats -scale1 $spot_scale osc_spots_${num}.bin \
          -scale2 $scale2 diffuse_${num}.bin -outfile bdsum_${num}.bin >&! bdsum_${num}.log &
end
echo "waiting for bdsum ..."
wait

echo "summing with background"
foreach n ( `seq 1 $nframes` )
set num = `echo $n | awk '{printf("%05d",$1)}'`

if( ! -e bdsum_${num}.bin ) then
    set BAD = "failed to combine float images with float_add at Bragg-Diffuse sum "
    goto exit
endif
if($fast > 11 && -e fullsum_${num}.bin) continue

$sruncpu float_add -nostats -scale1 $xtal_scale bdsum_${num}.bin \
          -scale2 $background_scale background.bin -outfile fullsum_${num}.bin >&! fullsum_${num}.log &
end
echo "waiting for fullsum ..."
wait


if( ! -e fullsum_${num}.bin ) then
    set BAD = "failed to combine float images with background using float_add"
    goto exit
endif



noisify:
echo "noise "
foreach n ( `seq 1 $nframes` )
set num = `echo $n | awk '{printf("%05d",$1)}'`

if( ! -e fullsum_${num}.bin ) then
    set BAD = "failed to combine summed float images with float_add"
    goto exit
endif
if($fast > 12 && -e noisy_${num}.img) continue

set thisseed = `echo $seed $num | awk '{print $1+$2}'`
$sruncpu noisify -seed $thisseed -scale $overall_scale \
    -detpixels_f 2463 -detpixels_s 2527 -pixel 0.172 -distance $distance \
    -phi $phi -osc $osc \
    -floatfile fullsum_${num}.bin -nopgm -intfile /dev/null \
    -bits 32 -adc_offset 0 -noiseimage noisy_${num}.img \
    $extrargs >&! noisify_${num}.log &

end
echo "waiting for noisify ..."
wait


echo "cbf "
foreach n ( `seq 1 $nframes` )
set num = `echo $n | awk '{printf("%05d",$1)}'`
if( ! -e noisy_${num}.img ) then
    set BAD = "noisify failed on image $num "
    goto exit
endif

# convert the header
head -c 512 diffuse_${num}.img >! ${t}header.txt
echo "\nTIME=$exposure" >> ${t}header.txt
echo "\nDATE=2099-01-01T00:00:00.000" >> ${t}header.txt
cat ${t}header.txt |\
awk -F "=" '{gsub(";","")}\
  /^PIXEL/{pix=$2}\
  /^SIZE1/{xpixels=ypixels=$2}\
  /^SIZE2/{ypixels=$2}\
  /^BEAM_CENTER_X/{beamx=$2}\
  /^BEAM_CENTER_Y/{beamy=$2}\
  /^XDS_ORGX/{orgx=$2}\
  /^XDS_ORGY/{orgy=$2}\
  /^DATE/{date=$2}\
  /^TIME/{expo=$2}\
  /^DISTAN/{dist=$2}\
  /^OSC_RANGE/{osc=$2}\
  /^OSC_START/{phi0=$2}\
  /^PHI/{phi=$2}\
  /^WAVE/{wave=$2}\
  END{ORS="\r\n";if(orgx==""){orgx=beamx/pix+1.5;orgy=ypixels-beamy/pix+1.5};\
    print  "###CBF: VERSION 1.5, CBFlib v0.7.8 - PILATUS detectors\r\n\r\ndata_fake_\r\n";\
    print  "_array_data.header_convention \"PILATUS_1.2\"";\
    print  "_array_data.header_contents\r\n;";\
    print  "# Detector: FAKE PILATUS, S/N 000, ";\
    printf("# %s\r\n",date);\
    printf("# Pixel_size %.3fe-6 m x %.3fe-6 m\r\n",pix*1000,pix*1000);\
    print  "# Silicon sensor, thickness 0.000450 m";\
    printf("# Exposure_time %.7f s\r\n",expo);\
    printf("# Exposure_period %.7f s\r\n",expo);\
    print  "# Tau = 0 s";\
    print  "# Count_cutoff 1049990 counts";\
    print  "# Threshold_setting: 0 eV";\
    printf("# Wavelength %s A\r\n",wave);\
    printf("# Detector_distance %.5f m\r\n",dist/1000);\
    printf("# Beam_xy (%.2f, %.2f) pixels\r\n",orgx,orgy);\
    printf("# Start_angle %.4f deg.\r\n",phi0);\
    printf("# Angle_increment %.4f deg.\r\n",osc);\
    printf("# Phi %.4f deg.\r\n",phi);\
    print  ";";\
    print  "";\
    print  "_array_data.data";\
    print  ";";\
}' >! ${outprefix}_${num}.cbf


int2cbf noisy_${num}.img -header 512 -bits 32 -signed -output ${t}.bin >&! int2cbf_${num}.log
if( $status ) then
    set BAD = "failed to convert image $num to cbf"
    goto exit
endif

cat ${t}.bin >> ${outprefix}_${num}.cbf
ls -l ${outprefix}_${num}.cbf

end



exit:

if( ! $debug && "${tempfile}" != "" && "${tempfile}" != "./" ) then
  rm -f ${tempfile}* >& /dev/null
endif

if($?BAD) then
    echo "ERROR $BAD"
    exit 9
endif


echo "all done"

exit



