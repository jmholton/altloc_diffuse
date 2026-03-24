#! /bin/tcsh -f
#
#  calculate diffuse scatter due to alt conformers, assuming:
#    every ASU is independent
#    every "A" conformer moves synchronously with every other "A", etc.
#    occupancies are on proper scale
#

set path = ( $path `dirname $0` )

set pdbfile = ""
set reso = 1.0
set CELL = ()
set SG = ""
set cellmult = 4

set ksol = 0.34
set Bsol = 40

set outfile = sqrtIdiffuse.mtz

set debug = 0

set tempfile = /dev/shm/${USER}/temp_cp2d_$$_
#set tempfile = ./tempfile_Bud_
mkdir -p /dev/shm/${USER}
mkdir -p ${CCP4_SCR}
if( ! -e /dev/shm/${USER}) set tempfile = ./tempfile_cp2d_$$_

set logfile = details.log

# cluster stuff
set srun = "auto"
set thishost = `hostname -s`
set CPUs = `grep proc /proc/cpuinfo | wc -l | awk '{print int($1/4)}'`
if( "$CPUs" == "" ) set CPUs = 1


echo "command-line arguments: $* "

set i = 0
while( $i < $#argv )
    @ i = ( $i + 1 )
    @ nexti = ( $i + 1 )
    @ lasti = ( $i - 1 )
    if($nexti > $#argv) set nexti = $#argv
    if($lasti < 1) set lasti = 1
    set Arg = "$argv[$i]"

    set arg = `echo $Arg | awk '{print tolower($0)}'`
    set assign = `echo $arg | awk '{print ( /=/ )}'`
    set Key = `echo $Arg | awk -F "=" '{print $1}'`
    set Val = `echo $Arg | awk '{print substr($0,index($0,"=")+1)}'`
    set Csv = `echo $Val | awk 'BEGIN{RS=","} {print}'`
    set key = `echo $Key | awk '{print tolower($1)}'`
    set num = `echo $Val | awk '{print $1+0}'`
    set int = `echo $Val | awk '{print int($1+0)}'`

    if( $assign ) then
      # re-set any existing variables
      set test = `set | awk -F "\t" '{print $1}' | egrep "^${Key}"'$' | wc -l`
      if ( $test ) then
          set $Key = "$Val"
          echo "$Key = $Val"
          continue
      endif
      # synonyms
      # input keyword arguments, especially the mtz output
      if("$key" == "output" || "$key" == "outmtz") set outfile = "$Val"
      if("$key" == "k_sol" ) set ksol = "$Val"
      if("$key" == "b_sol" ) set Bsol = "$Val"
      if("$key" == "mult" ) set cellmult = "$Val"
    else
      # no equal sign
      # pdb and mtz can be input arguments without invoking keywords explicit '=' assignment operator
      if("$Arg" =~ *.pdb ) set pdbfile = "$Arg"
      if("$Arg" =~ *.mtz ) set mtzfile = "$Arg"
    endif
    if("$arg" == "debug") set debug = "1"
end

if(! -e "$pdbfile") then
    set BAD = "pdbfile $pdbfile does not exist."
    goto exit
endif

# see if cannot migrate hosts because of temp files
if( "$srun" == "auto" ) then
  set thishost = `hostname -s`
  set test = `sinfo -h -n $thishost |& egrep -v "drain|n/a" | awk '$2=="up"' | wc -l`
  if ( $test ) then
    # we have slurm
    set CPUs = 1000
    if( "$tempfile" =~ /dev/shm/*  ) then
      echo "using slurm on local node"
      set srun = "srun -w $thishost"
    else
      echo "using slurm on cluster"
      set srun = "srun"
    endif
  else
    set srun = ""
  endif
endif

# shorthand for temp stuff
set t = ${tempfile}/
mkdir -p ${t}
if( ! -w "${t}" ) then
  set BAD = "cannot write to temp directory: $t"
  goto exit
endif

foreach dependency ( addup_mtzs_diffuse.com )
   echo -n "using: "
   which $dependency
   if( $status ) then
       set BAD = "need $dependency in "'$'"path"
       goto exit
   endif
end

cat << EOF
pdbfile = $pdbfile
outfile = $outfile
cellmult = $cellmult
tempfile = $tempfile
EOF

set pdbSG = `awk '/^CRYST/{print substr($0,56,12)}' $pdbfile | head -1`
set SG = `awk -v pdbSG="$pdbSG" -F "[\047]" 'pdbSG==$2{print;exit}' ${CLIBD}/symop.lib | awk '{print $4}'`
if("$SG" == "") then
    set SG = `echo $pdbSG | awk '{gsub(" ","");print}'`
    set SG = `awk -v SG=$SG '$4 == SG && $1 < 500 {print $4}' $CLIBD/symop.lib | head -1`
endif
if("$SG" == "") then
    set SG = `echo $pdbSG | awk '{gsub(" ","");print}'`
endif
# may need to be more clever here
set SG = `echo $SG | awk '{gsub("R","H"); print}'`
set pdbCELL = `awk '/^CRYST1/{print $2,$3,$4,$5,$6,$7}' $pdbfile`

if( $?CELL != 6 ) set CELL = ( $pdbCELL )

echo "getting symops for $SG"
awk -v SG=$SG '$4==SG{getline;while( /X/ ){print;getline}}' ${CLIBD}/symop.lib >! ${t}symops.txt
set ops = `awk '{print NR}' ${t}symops.txt`


unique hklout ${t}.mtz << EOF >! ${t}u.log
LABOUT F=F SIGF=SIGF
SYMM $SG
RESO 9
CELL 10 10 10 
EOF
rm -f ${t}.mtz >& /dev/null


# extract the symmetry operators from the log file
cat  ${t}u.log |\
awk '/Reciprocal space symmetry/,/Data line/' |\
awk '/positive/{pm="F+"} /negative/{pm="F-"}\
     $1=="ISYM" && $NF!="ISYM"{for(i=2;i<=NF;i+=2) print $i,pm,$(i+1)}' |\
grep "F+" >! ${t}symop_hkl.txt
set rs_ops = `awk '{print NR}' ${t}symop_hkl.txt`




set confs = `awk '/^ATOM|^HETAT/{print substr($0,17,1)}' $pdbfile | sort -u | sort `
if( $#confs > 1 ) echo "found conformers: $confs"
set models = `awk '/^MODEL/{print $2}' $pdbfile | sort -u | sort -g`
if( $#models > 1 ) echo "found models: $models"

if( $#confs <= 1 && $#models <= 1 ) then
    set BAD = "need at least two conformers/models to calculate diffuse scatter"
    goto exit
endif

if( $#models > 1 ) set confs = ( $models )

set bigcell = `echo $CELL $cellmult | awk '{print $NF*$1,$NF*$2,$NF*$3,$4,$5,$6}'`
echo "big cell: $bigcell"


foreach conf ( $confs )

  echo $conf $#models |\
  cat - $pdbfile |\
  awk 'NR==1{conf=$1;models=($NF>1);m="";next}\
    /^MODEL/{m=$2}\
    /^ENDMDL/{m=""}\
    ! /^ATOM|^HETAT/{next}\
    {c=substr($0,17,1)}\
#    c==conf{print}\
     ( ! models && ( c==conf || c==" " )) || m==conf {\
      print substr($0,1,55)" 1.00"substr($0,61);\
    }' >! ${t}asu_${conf}.pdb

  pdbset xyzin ${t}asu_${conf}.pdb xyzout ${t}sfallme${conf}.pdb << EOF >> $logfile
  cell $bigcell
  SPACE 1
EOF

  echo "fmodel conf $conf"
  rm -f ${t}asu_${conf}_${conf}.mtz
  $srun phenix.fmodel high_resolution=$reso ${t}sfallme${conf}.pdb \
     k_sol=$ksol b_sol=$Bsol \
     output.file_name=${t}asu_${conf}.mtz >! ${t}fmodel_${conf}.log &

end
wait

addup:
set mtzs = ( ${t}asu_*.mtz )
if( $#mtzs != $#confs ) then
    set BAD = "counting mismatch: $#confs conformers, but $#mtzs asu mtzs produced"
    goto exit
endif
echo "calculating Idiff = avg(F^2) - avg(F@PHI)^2"
addup_mtzs_diffuse.com $mtzs tempdir=${t}/addup/ outfile=${t}sum.mtz debug=$debug |& tee ${t}addup.log >> $logfile
if( $status || ! -e ${t}sum.mtz ) then
    set BAD = "addup_mtzs_diffuse.com failed."
    goto exit
endif

#set scale = `echo $#mtzs $#confs | awk '{print 1/$1/$2}'`
set scale = `echo $#mtzs | awk '{print 1/$1}'`
cad hklin1 ${t}sum.mtz hklout ${t}avg.mtz << EOF >> $logfile
labin file 1 E1=Fsum E2=PHIsum E3=Isum
scale file 1 $scale
labou file 1 E1=FCavg E2=PHICavg E3=ICavg
EOF

rm -f ${t}diffuse_1.mtz
sftools << EOF >> $logfile
read ${t}avg.mtz
set labels
Favg
PHI
Iavg
calc COL Favgsq = COL Favg COL Favg *
#the variance in the structure factor between the conformers is the diffuse scattering
calc COL Idiff = COL Iavg COL Favgsq -
write ${t}diffuse_1.mtz col Idiff
quit
y
EOF


foreach op ( $rs_ops )

if( $op == 1 ) then
  continue
endif

set hklop = `head -n $op ${t}symop_hkl.txt | tail -n 1 | awk '{print $NF}'`

echo "applying $hklop"
echo reindex $hklop | reindex hklin ${t}diffuse_1.mtz hklout ${t}diffuse_${op}.mtz >> $logfile &
#cad hklin1 ${t}reindexed.mtz hklout ${t}diffuse_${op}.mtz << EOF >> $logfile
#labin file 1 all
#EOF

end
wait



echo "adding up..."
rm -f ${t}diffuse.mtz
foreach op ( $ops )

  echo $op
  if(! -e ${t}diffuse.mtz) then
     cp ${t}diffuse_${op}.mtz ${t}diffuse.mtz
     continue
  endif

rm -f ${t}new.mtz
sftools << EOF >> $logfile
read ${t}diffuse.mtz col Idiff
read ${t}diffuse_${op}.mtz col Idiff
set labels
I1
I2
calc COL Idiff = COL I1 COL I2 +
write ${t}new.mtz col Idiff
quit
y
EOF
mv ${t}new.mtz ${t}diffuse.mtz

end

echo "taking sqrt(Idiff)"
rm -f ${t}sqrt.mtz
sftools << EOF >> $logfile
read ${t}diffuse.mtz col Idiff
calc F COL sqrtIdiff = COL Idiff 0.5 **
write ${t}sqrt.mtz col sqrtIdiff
quit
y
EOF

mv ${t}sqrt.mtz ${outfile}

exit:

if( ! $debug && "${tempfile}" != "" && "${tempfile}" != "./" ) then
  rm -f ${tempfile}* >& /dev/null
endif

if($?BAD) then
    echo "ERROR $BAD"
    exit 9
endif


ls -l $outfile

exit

##############################
#  notes on remediating mtz files to fit into sftools
#
set reso = 1.65

foreach mtz ( ../asu_*.mtz )

set num = `echo $mtz | awk -F "_" '{print $2+0}'`

echo "labin file 1 all\nresolution over_all $reso" | cad hklin1 $mtz hklout ../lores_${num}.mtz | grep HKLOUT &

end
wait

foreach mtz ( ../asu_*.mtz )

set num = `echo $mtz | awk -F "_" '{print $2+0}'`

end

