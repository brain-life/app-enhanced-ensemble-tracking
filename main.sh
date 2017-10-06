#!/bin/bash

[ "$PBS_O_WORKDIR" ] && cd $PBS_O_WORKDIR

if [ $ENV == "IUHPC" ]; then
    module load mrtrix/0.2.12
    module load freesurfer/6.0.0
    module load matlab
    module load python
    SUBJECTS_DIR=`pwd`
    source $FREESURFER_HOME/SetUpFreeSurfer.sh
fi

if [ $ENV == "VM" ]; then
    export FREESURFER_HOME=/usr/local/freesurfer
    source $FREESURFER_HOME/SetUpFreeSurfer.sh
fi

OUTDIR=./output
mkdir $OUTDIR

## grab the config.json inputs
DWI=`$SERVICE_DIR/jq -r '.dwi' config.json`/dwi_aligned_trilin.nii.gz
BVALS=`$SERVICE_DIR/jq -r '.bvals' config.json`/dwi_aligned_trilin.bvals
BVECS=`$SERVICE_DIR/jq -r '.bvecs' config.json`/dwi_aligned_trilin.bvecs

MASK=`$SERVICE_DIR/jq -r '.mask' config.json`/mask_anat.nii.gz
WMMASK=`$SERVICE_DIR/jq -r '.wmmask' config.json`/wm_anat.nii.gz
CCMASK=`$SERVICE_DIR/jq -r '.ccmask' config.json`/cc_anat.nii.gz
TMASK=`$SERVICE_DIR/jq -r '.tmask' config.json`/wm_full.nii.gz

DOPROB=`$SERVICE_DIR/jq -r '.do_probabilistic' config.json`
PROB_CURVS=`$SERVICE_DIR/jq -r '.prob_curvs' config.json`

DOSTREAM=`$SERVICE_DIR/jq -r '.do_deterministic' config.json`
STREAM_CURVS=`$SERVICE_DIR/jq -r '.detr_curvs' config.json`

DOTENSOR=`$SERVICE_DIR/jq -r '.do_tensor' config.json`

NUMWMFIBERS=`$SERVICE_DIR/jq -r '.fibers' config.json`
MAXNUMWMFIBERS=$(($NUMWMFIBERS*2))

NUMCCFIBERS=$(($NUMWMFIBERS/5))
MAXNUMCCFIBERS=$(($NUMCCFIBERS*2))

## make grad.b from bvals / bvecs
cat $BVECS $BVALS >> $OUTDIR/tmp.b

awk '
{ 
    for (i=1; i<=NF; i++)  {
        a[NR,i] = $i
    }
}
NF>p { p = NF }
END {    
    for(j=1; j<=p; j++) {
        str=a[1,j]
        for(i=2; i<=NR; i++){
            str=str" "a[i,j];
        }
        print str
    }
}' $OUTDIR/tmp.b > $OUTDIR/grad.b

rm -f $OUTDIR/tmp.b

GRAD=$OUTDIR/grad.b

## THIS IS BROKE SOMEHOW
MAXLMAX=`$SERVICE_DIR/jq -r '.max_lmax' config.json`
if [[ $MAXLMAX == "null" || -z $MAXLMAX ]]; then

    echo "Maximum L_{max} is empty. Determining highest L_{max} possible from grad.b"

    ## determine count of b0s
    VOLS=`cat $OUTDIR/grad.b | wc -l`
    BNOT=`grep '0 0 0 0' $OUTDIR/grad.b | wc -l`
    COUNT=$(($VOLS-$BNOT))
    
    lmax=0
    while [ $((($lmax+3)*($lmax+4)/2)) -le $COUNT ]; do
	MAXLMAX=$(($lmax+2))
    done
    
fi

echo "Maximum L_{max} is set to ${MAXLMAX}."

echo 
echo Converting files for MRTrix processing...
echo 

mrconvert ${DWI} $OUTDIR/dwi.mif
mrconvert ${MASK} $OUTDIR/mask.mif
mrconvert ${WMMASK} $OUTDIR/wm.mif
mrconvert ${CCMASK} $OUTDIR/cc.mif
mrconvert ${TMASK} $OUTDIR/tm.mif

echo
echo Preparing data for tracking...
echo

estimate_response -quiet $OUTDIR/dwi.mif $OUTDIR/cc.mif -grad $GRAD $OUTDIR/response.txt


if [ $DOTENSOR == "true" ]; then

   echo
   echo Fitting tensor model...
   echo
   
   dwi2tensor -quiet $OUTDIR/dwi.mif -grad $GRAD $OUTDIR/dt.mif

fi

echo 
echo Estimating multiple CSD fits...
echo 

for (( i_lmax=2; i_lmax<=$MAXLMAX; i_lmax+=2 )); do
    
	csdeconv -quiet $OUTDIR/dwi.mif -grad $GRAD $OUTDIR/response.txt -lmax $i_lmax -mask $OUTDIR/mask.mif $OUTDIR/lmax${i_lmax}.mif

done 

echo
echo Tracking ensemble tractogram...
echo

if [ $DOTENSOR == "true" ] ; then

    echo "Performing tensor tracking..."
    streamtrack -quiet DT_STREAM $OUTDIR/dwi.mif $OUTDIR/wm_tensor.tck -seed $WMMASK -mask $TMASK -grad $GRAD -number $NUMWMFIBERS -maxnum $MAXNUMWMFIBERS
    streamtrack -quiet DT_STREAM $OUTDIR/dwi.mif $OUTDIR/cc_tensor.tck -seed $CCMASK -mask $TMASK -grad $GRAD -number $NUMCCFIBERS -maxnum $MAXNUMCCFIBERS
    
fi

if [ $DOSTREAM == "true" ] ; then
    
    for (( i_lmax=2; i_lmax<=$MAXLMAX; i_lmax+=2 )); do

	for i_curv in $STREAM_CURVS; do

	    streamtrack -quiet SD_STREAM $OUTDIR/lmax${i_lmax}.mif $OUTDIR/detr_lmax${i_lmax}_curv${i_curv}_wm.tck -seed $WMMASK -mask $TMASK -grad $GRAD -curvature ${i_curv} -number $NUMWMFIBERS -maxnum $MAXNUMWMFIBERS
	    streamtrack -quiet SD_STREAM $OUTDIR/lmax${i_lmax}.mif $OUTDIR/detr_lmax${i_lmax}_curv${i_curv}_cc.tck -seed $CCMASK -mask $TMASK -grad $GRAD -curvature ${i_curv} -number $NUMCCFIBERS -maxnum $MAXNUMCCFIBERS

	done
	
    done
fi

if [ $DOPROB == "true" ] ; then
    
    for (( i_lmax=2; i_lmax<=$MAXLMAX; i_lmax+=2 )); do

	for i_curv in $PROB_CURVS; do
	    echo "Trying to track lmax $i_lmax with curvature $i_curv"
	    streamtrack SD_PROB $OUTDIR/lmax${i_lmax}.mif $OUTDIR/prob_lmax${i_lmax}_curv${i_curv}_wm.tck -seed $WMMASK -mask $TMASK -grad $GRAD -curvature ${i_curv} -number $NUMWMFIBERS -maxnum $MAXNUMWMFIBERS
	    streamtrack SD_PROB $OUTDIR/lmax${i_lmax}.mif $OUTDIR/prob_lmax${i_lmax}_curv${i_curv}_cc.tck -seed $CCMASK -mask $TMASK -grad $GRAD -curvature ${i_curv} -number $NUMCCFIBERS -maxnum $MAXNUMCCFIBERS

	done
	
    done
fi

echo 
echo DONE tracking
echo
