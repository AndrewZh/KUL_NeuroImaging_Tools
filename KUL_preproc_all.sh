#!/bin/bash
# @ Stefan Sunaert & Ahmed Radwan- UZ/KUL - stefan.sunaert@uzleuven.be
#
# v0.1 - dd 06/11/2018 - alpha version
# v0.2a - dd 12/12/2018 - preparing for beta release 0.2
v="v0.2 - dd 19/12/2018"

# This is the main script of the KUL_NeuroImaging_Toools
#
# Description:
#    This script preprocces an entire study (multiple subjects) with structural, functional and diffusion data at Stefan's lab
#      It will:
#       - perform mriqc on structural and functional data
#       - perform fmriprep on structural and functional data
#       - perform freesurfer on the structural data (only T1w for now) 
#       - perform mrtix3 and related processing on dMRI data
#       - optionally:
#           - perform combined structural and dMRI data analysis (depends on fmriprep, freesurfer and mrtrix3 above)
#           - perform fibertractography
#
#   Requirements:
#       A correct installation of your mac (for now, maybe later also a hpc) at the lab
#           - including:
#               - dcm2niix (in KUL_apps)
#               - dcm2bids (jooh fork, using pip)
#               - docker
#               - freesurfer (in KUL_apps)
#               - mrtrix (in KUL_apps)  
#               - last but not least, a correct installation of up-to-date KUL_NeuroImaging_Tools (in KUL_apps)
#               - correct setup of your .bashrc and .bash_profile
#







# To do:
#
#       - other ideas:
#               - add processing for fmri stats






# Source KUL_main_functions
# KUL_main_functions will:
#  - Say Welcome
#  - check wether all necessary software is installed (and exit if needed)
#  - provide some general functions like logging
kul_main_dir=$(dirname "$0")
script=$(basename "$0")
cwd=$(pwd)
source $kul_main_dir/KUL_main_functions.sh






# Start with defining local functions


# A Function to provide Usage information
#   - gives information about the script
function Usage {

cat <<USAGE

`basename $0` preproccesses an entire study

Usage:

  `basename $0` -c config_file -b bids_dir

Required arguments:

     -c:  description of the subjects and settings for processing

Optional arguments:
    
     -b:  bids directory
     -n:  number of cores to use (distrubuted over mriqc/fmriprep/freesurfer/etc...)
     -m:  max memory (in gigabytes) available in docker
     -t:  temporary directory (default = /tmp)
     -r:  reset docker (clean the images and download new ones)
     -v:  verbose
     -e:  expert mode (uses a different config_file format)

Example:

  `basename $0` -c study_config/subjects_and_options.csv -b BIDS -n 6 -m 12 -t /scratch -v 
    
    uses "study_config/subjects_and_options.csv" to 
        - reads the subjects (participants) on which to do processing
        - reads what processing (mriqc/fmriprep/freesurfer/etc...) to do on those
        - reads the options to give to mriqc/fmriprep/etc...
    uses the (already converted) BIDS data in directory "BIDS"
    uses 6 cores in total for all processes (distrubuted over mriqc/fmriprep/freesurfer/etc...)
    uses & memory of 12 GB
        - for fmriprep & mriqc 
        - (set this option equal to, or slightly less than what you specify in your docker prefences)
    specifies that temporary data are written to /scratch
    spits out more verbose logging to the terminal

USAGE

    exit 1
}


# A Function to start mriqc processing (in parallel)
function task_mriqc_participant {

# check whether to use singularity-mriqc
mriqc_singularity=0
#echo $KUL_use_mriqc_singularity
if [ -z $KUL_use_mriqc_singularity ]; then

    echo "  KUL_use_mriqc_singularity not set, using docker"
    
elif [ $KUL_use_mriqc_singularity -eq 1 ]; then
    
    echo "  KUL_use_mriqc_singularity is set to 1, using it"
    mriqc_singularity=1

fi

#echo $mriqc_singularity

mriqc_log_p=$(echo ${BIDS_participant} | sed -e 's/ /_/g' )
mriqc_log="${preproc}/log/mriqc/mriqc_${mriqc_log_p}.txt"
mriqc_act="${preproc}/log/mriqc/mriqc_${mriqc_log_p}_act"
mkdir -p ${preproc}/log/mriqc

kul_e2cl " started (in parallel) mriqc on participant(s) $BIDS_participant (with options $mriqc_options, using $ncpu_mriqc cores, logging to $mriqc_log)" $log

if [ $mriqc_singularity -eq 1 ]; then 

 mkdir -p ./mriqc
 mkdir -p ./mriqc_work_${mriqc_log_p}

 local task_mriqc_cmd=$(echo "singularity run --cleanenv \
 -B ${cwd}:/work \
 $KUL_mriqc_singularity \
 --participant_label $BIDS_participant \
 $mriqc_options \
 -w /work/mriqc_work_${mriqc_log_p} \
 --n_procs $ncpu_mriqc --ants-nthreads $ncpu_mriqc_ants --mem_gb $mem_gb --no-sub \
 /work/${bids_dir} /work/mriqc participant \
 > $mriqc_log 2>&1 ") 

else

 local task_mriqc_cmd=$(echo "docker run --read-only --tmpfs /run --tmpfs /tmp --rm \
 -v ${cwd}/${bids_dir}:/data:ro -v ${cwd}/mriqc:/out \
 poldracklab/mriqc:latest \
 --participant_label $BIDS_participant \
 $mriqc_options \
 --n_procs $ncpu_mriqc --ants-nthreads $ncpu_mriqc_ants --mem_gb $mem_gb --no-sub \
 /data /out participant \
 > $mriqc_log 2>&1 ") 

fi

echo "   using cmd: $task_mriqc_cmd"

# now we start the parallel job
if [ $make_pbs_files_instead_of_running -eq 0 ]; then

    eval $task_mriqc_cmd &
    mriqc_pid="$!"
    echo " mriqc pid is $mriqc_pid"

    sleep 2
    #psrecord $mriqc_pid --log $mriqc_act.txt --plot $mriqc_act.png --interval 30 &

else

    echo " making a PBS file"
    mkdir -p VSC

#    echo $task_mriqc_cmd > VSC/pbs_task_mriqc.txt
    task_command=$(echo "singularity run --cleanenv \
 -B \${cwd}:/work \
 -B \${cwd}:/data \
 -B \${cwd}:/out \
 \$KUL_mriqc_singularity \
 --participant_label \$BIDS_participant \
 \$mriqc_options \
 -w /work/mriqc_work_\${mriqc_log_p} \
 --n_procs \$ncpu_mriqc --ants-nthreads \$ncpu_mriqc_ants --mem_gb \$mem_gb --no-sub \
 /work/\${bids_dir} /work/mriqc participant \
 > \$mriqc_log 2>&1 ")
    #chmod +x VSC/pbs_task_mriqc.sh

    cp $kul_main_dir/VSC/master.pbs VSC/run_mriqc.pbs

    perl  -pi -e "s/##LP##/${pbs_lp}/g" VSC/run_mriqc.pbs
    perl  -pi -e "s/##CPU##/${pbs_cpu}/g" VSC/run_mriqc.pbs
    perl  -pi -e "s/##MEM##/${pbs_mem}/g" VSC/run_mriqc.pbs
    esc_pbs_email=$(echo $pbs_email | sed 's#\([]\!\(\)\#\%\@\*\$\/&\-\=[]\)#\\\1#g')
    perl  -pi -e "s/##EMAIL##/${esc_pbs_email}/g" VSC/run_mriqc.pbs
    esc_pbs_walltime=$(echo $pbs_walltime | sed 's#\([]\!\(\)\#\%\@\*\$\/&\-\=[]\)#\\\1#g')
    perl  -pi -e "s/##WALLTIME##/${esc_pbs_walltime}/g" VSC/run_mriqc.pbs
    esc_pbs_singularity_fmriprep=$(echo $pbs_singularity_fmriprep | sed 's#\([]\!\(\)\#\%\@\*\$\/&\-\=[]\)#\\\1#g')
    perl  -pi -e "s/##FMRIPREP##/${esc_pbs_singularity_fmriprep}/g" VSC/run_mriqc.pbs
    esc_pbs_singularity_mriqc=$(echo $pbs_singularity_mriqc | sed 's#\([]\!\(\)\#\%\@\*\$\/&\-\=[]\)#\\\1#g')
    perl  -pi -e "s/##MRIQC##/${esc_pbs_singularity_mriqc}/g" VSC/run_mriqc.pbs
    esc_task_command=$(echo $task_command | sed 's#\([]\!\(\)\#\%\@\*\$\/&\-\=[]\)#\\\1#g')
    perl  -pi -e "s/##COMMAND##/${esc_task_command}/g" VSC/run_mriqc.pbs


    echo $pbs_data_file
    if [ ! -f $pbs_data_file ]; then
        echo "cwd,BIDS_participant,mriqc_options,mriqc_log_p,ncpu_mriqc,ncpu_mriqc_ants,mem_gb,bids_dir,mriqc_log" > $pbs_data_file
    fi 
    echo "$cwd,$BIDS_participant,$mriqc_options,$mriqc_log_p,$ncpu_mriqc,$ncpu_mriqc_ants,$mem_gb,$bids_dir,$mriqc_log" >> $pbs_data_file

fi

}


# A function to start fmriprep processing (in parallel)
function task_fmriprep {

# make log dir and clean_up before starting
mkdir -p ${preproc}/log/fmriprep
#rm -fr ${cwd}/fmriprep_work_${fmriprep_log_p}

# check whether to use singularity-fmriprep
fmriprep_singularity=0
#echo $KUL_use_fmriprep_singularity
if [ -z $KUL_use_fmriprep_singularity ]; then

    echo "  KUL_use_fmriprep_singularity not set, using docker"
    
elif [ $KUL_use_fmriprep_singularity -eq 1 ]; then
    
    echo "  KUL_use_fmriprep_singularity is set to 1, using it"
    fmriprep_singularity=1

fi

#echo $fmriprep_singularity


fmriprep_log_p=$(echo ${BIDS_participant} | sed -e 's/ /_/g' )
fmriprep_log=${preproc}/log/fmriprep/${fmriprep_log_p}.txt
fmriprep_act=${preproc}/log/fmriprep/${fmriprep_log_p}_act

kul_e2cl " started (in parallel) fmriprep on participant ${BIDS_participant}... (with options $fmriprep_options, using $ncpu_fmriprep cores, logging to $fmriprep_log)" ${log}

if [ $fmriprep_singularity -eq 1 ]; then 

 mkdir -p ./fmriprep_work_${fmriprep_log_p}
        
 local task_fmriprep_cmd=$(echo "singularity run --cleanenv \
 -B ./fmriprep_work_${fmriprep_log_p}:/work \
 -B .:/data \
 -B .:/out \
 -B ${freesurfer_license}:/opt/freesurfer/license.txt \
 $KUL_fmriprep_singularity \
 /data/${bids_dir} \
 /out \
 participant \
 --participant_label ${BIDS_participant} \
 -w /work \
 --nthreads $ncpu_fmriprep --omp-nthreads $ncpu_fmriprep_ants \
 --mem_mb $mem_mb \
 $fmriprep_options \
 --notrack \
 > $fmriprep_log  2>&1") 

else

    local task_fmriprep_cmd=$(echo "docker run --rm \
 -v ${cwd}/${bids_dir}:/data \
 -v ${cwd}:/out \
 -v ${cwd}/fmriprep_work_${fmriprep_log_p}:/scratch \
 -v ${freesurfer_license}:/opt/freesurfer/license.txt \
 poldracklab/fmriprep:latest \
 /data /out \
 participant \
 --participant_label ${BIDS_participant} \
 -w /scratch \
 --nthreads $ncpu_fmriprep --omp-nthreads $ncpu_fmriprep_ants \
 --mem_mb $mem_mb \
 $fmriprep_options \
 --notrack \
 > $fmriprep_log  2>&1") 

fi

echo "   using cmd: $task_fmriprep_cmd"

# Now start the parallel job
if [ $make_pbs_files_instead_of_running -eq 0 ]; then

    eval $task_fmriprep_cmd &
    fmriprep_pid="$!"
    echo " fmriprep pid is $fmriprep_pid"

    sleep 2
    #psrecord $fmriprep_pid --include-children --log $fmriprep_act.txt --plot $fmriprep_act.png --interval 30 &

else

    echo " making a PBS file"
    mkdir -p VSC

    task_command=$(echo "mkdir -p ./fmriprep_work_\${fmriprep_log_p}; singularity run --cleanenv \
 -B ./fmriprep_work_\${fmriprep_log_p}:/work \
 -B \$FS_LICENSE:/opt/freesurfer/license.txt \
 \$KUL_fmriprep_singularity \
 ./\${bids_dir} \
 . \
 participant \
 --participant_label \${BIDS_participant} \
 -w /work \
 --nthreads \$ncpu_fmriprep --omp-nthreads \$ncpu_fmriprep_ants \
 --mem_mb \$mem_mb \
 \$fmriprep_options \
 --notrack \
 > \$fmriprep_log  2>&1") 

    cp $kul_main_dir/VSC/master.pbs VSC/run_fmriprep.pbs

    perl  -pi -e "s/##LP##/${pbs_lp}/g" VSC/run_fmriprep.pbs
    perl  -pi -e "s/##CPU##/${pbs_cpu}/g" VSC/run_fmriprep.pbs
    perl  -pi -e "s/##MEM##/${pbs_mem}/g" VSC/run_fmriprep.pbs
    esc_pbs_email=$(echo $pbs_email | sed 's#\([]\!\(\)\#\%\@\*\$\/&\-\=[]\)#\\\1#g')
    perl  -pi -e "s/##EMAIL##/${esc_pbs_email}/g" VSC/run_fmriprep.pbs
    esc_pbs_walltime=$(echo $pbs_walltime | sed 's#\([]\!\(\)\#\%\@\*\$\/&\-\=[]\)#\\\1#g')
    perl  -pi -e "s/##WALLTIME##/${esc_pbs_walltime}/g" VSC/run_fmriprep.pbs
    esc_pbs_singularity_fmriprep=$(echo $pbs_singularity_fmriprep | sed 's#\([]\!\(\)\#\%\@\*\$\/&\-\=[]\)#\\\1#g')
    perl  -pi -e "s/##FMRIPREP##/${esc_pbs_singularity_fmriprep}/g" VSC/run_fmriprep.pbs
    esc_pbs_singularity_mriqc=$(echo $pbs_singularity_mriqc | sed 's#\([]\!\(\)\#\%\@\*\$\/&\-\=[]\)#\\\1#g')
    perl  -pi -e "s/##MRIQC##/${esc_pbs_singularity_mriqc}/g" VSC/run_fmriprep.pbs
    esc_task_command=$(echo $task_command | sed 's#\([]\!\(\)\#\%\@\*\$\/&\-\=[]\)#\\\1#g')
    perl  -pi -e "s/##COMMAND##/${esc_task_command}/g" VSC/run_fmriprep.pbs


    echo $pbs_data_file
    if [ ! -f $pbs_data_file ]; then
        echo "BIDS_participant,fmriprep_log_p,bids_dir,ncpu_fmriprep,ncpu_fmriprep_ants,mem_mb,fmriprep_options,fmriprep_log" > $pbs_data_file
    fi 
    echo "$BIDS_participant,$fmriprep_log_p,$bids_dir,$ncpu_fmriprep,$ncpu_fmriprep_ants,$mem_mb,$fmriprep_options,$fmriprep_log" >> $pbs_data_file


fi
#kul_e2cl "   done fmriprep on participant $BIDS_participant" $log

}

# A Function to start freesurfer processing (in parallel)
function task_freesurfer {

# check if already performed freesurfer
freesurfer_file_to_check=freesurfer/sub-${BIDS_participant}/${BIDS_participant}/scripts/recon-all.done
        
if [ ! -f  $freesurfer_file_to_check ]; then
    
    freesurfer_log=${preproc}/log/freesurfer/${BIDS_participant}.txt
    mkdir -p ${preproc}/log/freesurfer

    kul_e2cl " started (in parallel) freesurfer recon-all on participant ${BIDS_participant}... (using $ncpu_freesurfer cores, logging to $freesurfer_log)" ${log}
    
    # search if any sessions exist
    search_sessions=($(find BIDS/sub-${BIDS_participant} -type f | grep T1w.nii.gz))
    
    # ####### CHANGE BACK!!!!!
    #search_sessions=($(find BIDS/sub-${BIDS_participant} -type f | grep ses-1 | grep T1w.nii.gz))
    
    num_sessions=${#search_sessions[@]}
    
    echo "  Freesurfer processing: number T1w data in the BIDS folder: $num_sessions"
    echo "    notably: ${search_sessions[@]}"

    # make the freesurfer input string
    freesurfer_invol=""
    for i in `seq 0 $(($num_sessions-1))`; do
    
        freesurfer_invol=" $freesurfer_invol -i ${search_sessions[$i]} "

    done

    #echo $freesurfer_invol
    
    # test for options
    # -useflair
    fs_use_flair=""
    if [[ $freesurfer_options =~ "-useflair" ]]; then

        echo "  Option -useflair given"

        # search if any sessions exist
        search_sessions_flair=($(find BIDS/sub-${BIDS_participant} -type f | grep FLAIR.nii.gz))

        # ####### CHANGE BACK!!!!!
        #search_sessions_flair=($(find BIDS/sub-${BIDS_participant} -type f | grep ses-1 | grep FLAIR.nii.gz))

        num_sessions_flair=${#search_sessions_flair[@]}

        if [ $num_sessions_flair -gt 0 ]; then 
        
            echo "  Freesurfer processing: number of FLAIR data in the BIDS folder: $num_sessions_flair"
            echo "    notably: ${search_sessions_flair[@]}"

            # make the freesurfer input string
            freesurfer_invol_flair=""
            for i in `seq 0 $(($num_sessions-1))`; do
    
                freesurfer_invol_flair=" $freesurfer_invol_flair -FLAIR ${search_sessions_flair[$i]} "

            done
            fs_use_flair=" $freesurfer_invol_flair -FLAIRpial "
        
        fi

        #echo $fs_use_flair

    fi

    # -fs_hippoT1T2
    fs_hippoT1T2=""
    if [[ $freesurfer_options =~ "-hippocampal-subfields-T1T2" ]]; then

        echo "  Option -hippocampal-subfields-T1T2 given"

        # search if any FLAIR sessions exist
        search_sessions_flair2=($(find BIDS/sub-${BIDS_participant} -type f | grep FLAIR.nii.gz))
        num_sessions_flair2=${#search_sessions_flair[@]}

        if [ $num_sessions_flair2 -gt 0 ]; then 
        
            echo "  Freesurfer processing: number of FLAIR data in the BIDS folder: $num_sessions_flair"
            echo "    notably: ${search_sessions_flair[@]}"

            # make the freesurfer input string
            freesurfer_invol_flair2=""
            for i in `seq 0 $(($num_sessions-1))`; do
    
                freesurfer_invol_flair2=" $freesurfer_invol_flair2 -hippocampal-subfields-T1T2 ${search_sessions_flair2[$i]} FLAIR-${i}"

            done
            fs_hippoT1T2=" $freesurfer_invol_flair2 -itkthreads $ncpu_freesurfer "
        
        fi

        #echo $fs_hippoT1T2

    fi

    mkdir -p freesurfer

    SUBJECTS_DIR=${cwd}/freesurfer/sub-${BIDS_participant}

    #start clean
    rm -rf $SUBJECTS_DIR
    mkdir -p $SUBJECTS_DIR
    export SUBJECTS_DIR
    notify_file=${SUBJECTS_DIR}_freesurfer_is.done
    echo $notify_file

    local task_freesurfer_cmd=$(echo "recon-all -subject $BIDS_participant $freesurfer_invol \
        $fs_use_flair $fs_hippoT1T2 $fs_options_direct -all -openmp $ncpu_freesurfer \
        -parallel -notify $notify_file > $freesurfer_log 2>&1 ")

    echo "   using cmd: $task_freesurfer_cmd"

    eval $task_freesurfer_cmd &
    freesurfer_pid="$!"
    echo "   freesurfer pid is $freesurfer_pid"
    
    sleep 2

    #kul_e2cl "   done freesufer on participant $BIDS_participant" $log

else

    freesurfer_pid=-1
    echo " freesurfer of subjet $BIDS_participant already done, skipping..."
        
fi


#done
}



# A function to start KUL_dwiprep processing (in parallel)
function task_KUL_dwiprep {

# check if already performed KUL_dwiprep
dwiprep_file_to_check=dwiprep/sub-${BIDS_participant}/dwiprep_is_done.log

#FLAG we still need to implement topup_options

if [ ! -f  $dwiprep_file_to_check ]; then

    dwiprep_log=${preproc}/log/dwiprep/dwiprep_${BIDS_participant}.txt
    mkdir -p ${preproc}/log/dwiprep

    kul_e2cl " started (in parallel) KUL_dwiprep on participant ${BIDS_participant}... (using $ncpu_dwiprep cores, logging to $dwiprep_log)" ${log}

    local task_dwiprep_cmd=$(echo "KUL_dwiprep.sh -p ${BIDS_participant} -n $ncpu_dwiprep -d \"$dwipreproc_options\" -e \"${eddy_options} \" -v \
 > $dwiprep_log 2>&1 ")

    echo "   using cmd: $task_dwiprep_cmd"

    # Now we start the parallel job
    eval $task_dwiprep_cmd &
    dwiprep_pid="$!"
    echo " KUL_dwiprep pid is $dwiprep_pid"

    sleep 2

else

    dwiprep_pid=-1
    echo " KUL_dwiprep of participant $BIDS_participant already done, skipping..."
        
fi

}




# A Function to start KUL_dwiprep_anat processing
function task_KUL_dwiprep_anat {

# check if already performed KUL_dwiprep_anat
dwiprep_anat_file_to_check=dwiprep/sub-${BIDS_participant}/dwiprep_anat_is_done.log

if [ ! -f  $dwiprep_anat_file_to_check ]; then

    dwiprep_anat_log=${preproc}/log/dwiprep/dwiprep_anat_${BIDS_participant}.txt

    kul_e2cl " performing KUL_dwiprep_anat on subject ${BIDS_participant}... (using $dwiprep_anat_ncpu cores, logging to $dwiprep_anat_log)" ${log}

    KUL_dwiprep_anat.sh -p ${BIDS_participant} -n $dwiprep_anat_ncpu -v \
        > $dwiprep_anat_log 2>&1 &

    dwiprep_anat_pid="$!"
    echo " KUL_dwiprep_anat pid is $dwiprep_anat_pid"

else

    dwiprep_anat_pid=-1
    echo " KUL_dwiprep_anat of subjet $BIDS_participant already done, skipping..."
        
fi

}


# A Function to start KUL_dwiprep_MNI processing
function task_KUL_dwiprep_MNI {

# check if already performed KUL_dwiprep_MNI
dwiprep_MNI_file_to_check=dwiprep/sub-${BIDS_participant}/dwiprep_MNI_is_done.log

if [ ! -f  $dwiprep_MNI_file_to_check ]; then

    dwiprep_MNI_log=${preproc}/log/dwiprep/dwiprep_MNI_${BIDS_participant}.txt

    kul_e2cl " performing KUL_dwiprep_MNI on subject ${BIDS_participant}... (using $dwiprep_MNI_ncpu cores, logging to $dwiprep_MNI_log)" ${log}

    KUL_dwiprep_MNI.sh -p ${BIDS_participant} -n $dwiprep_MNI_ncpu -v \
        > $dwiprep_MNI_log 2>&1 &

    dwiprep_MNI_pid="$!"
    echo " KUL_dwiprep_MNI pid is $dwiprep_MNI_pid"


else

    dwiprep_MNI_pid=-1
    echo " KUL_dwiprep_MNI of subjet $BIDS_participant already done, skipping..."
        
fi

}


# A Function to start KUL_dwiprep_drtdbs processing
function task_KUL_dwiprep_drtdbs {

# check if already performed KUL_dwiprep_drtdbs
dwiprep_drtdbs_file_to_check=dwiprep/sub-${BIDS_participant}/dwiprep_drtdbs_is_done.log

if [ ! -f  $dwiprep_drtdbs_file_to_check ]; then

    dwiprep_drtdbs_log=${preproc}/log/dwiprep/dwiprep_drtdbs_${BIDS_participant}.txt

    kul_e2cl " performing KUL_dwiprep_drtdbs on subject ${BIDS_participant}... (using $ncpu cores, logging to $dwiprep_drtdbs_log)" ${log}

    local task_dwiprep_drtdbs_cmd=$(echo "KUL_dwiprep_drtdbs.sh -p ${BIDS_participant} -n $ncpu -v -o $drtdbs_options -v \
 > $dwiprep_drtdbs_log 2>&1 ")

    echo "   using cmd: $task_dwiprep_drtdbs_cmd"
    
    eval $task_dwiprep_drtdbs_cmd

else

    echo " KUL_dwiprep_drtdbs of subjet $BIDS_participant already done, skipping..."
        
fi

}

# A Function to start KUL_dwiprep_fibertract processing
function task_KUL_dwiprep_fibertract {

# check if already performed KUL_dwiprep_drtdbs
dwiprep_fibertract_file_to_check=dwiprep/sub-${BIDS_participant}/dwiprep_fibertract_is_done.log

if [ ! -f  $dwiprep_fibertract_file_to_check ]; then

    dwiprep_fibertract_log=${preproc}/log/dwiprep/dwiprep_fibertract_${BIDS_participant}.txt

    kul_e2cl " performing KUL_dwiprep_fibertract on subject ${BIDS_participant}... (using $dwiprep_fibertract_ncpu cores, logging to $dwiprep_fibertract_log)" ${log}

    fibertract_wb_flag=""
    #echo $dwiprep_fibertract_whole_brain
    if [ $dwiprep_fibertract_whole_brain -eq 1 ]; then 

        fibertract_wb_flag=" -f "

    fi

    local task_dwiprep_fibertract_cmd=$(echo "KUL_dwiprep_fibertract.sh -p ${BIDS_participant} \
        $fibertract_wb_flag -n $dwiprep_fibertract_ncpu -v \
        -w $dwiprep_fibertract_response_file \
        -c $dwiprep_fibertract_conf_file  -r $dwiprep_fibertract_rois_file \
    > $dwiprep_fibertract_log 2>&1 ")

    echo "   using cmd: $task_dwiprep_fibertract_cmd"
    
    eval $task_dwiprep_fibertract_cmd

else

    echo " KUL_dwiprep_fibertract of subjet $BIDS_participant already done, skipping..."
        
fi

}

function WaitForTaskCompletion {
    local pidsArray=${waitforpids[@]} # pids to wait for, separated by semi-colon
    local procsArray=${waitforprocs[@]} # name of procs to wait for, separated by semi-colon
    #local soft_max_time="${3}" # If execution takes longer than $soft_max_time seconds, will log a warning, unless $soft_max_time equals 0.
    #local hard_max_time="${4}" # If execution takes longer than $hard_max_time seconds, will stop execution, unless $hard_max_time equals 0.
    #local caller_name="${5}" # Who called this function
    #local exit_on_error="${6:-false}" # Should the function exit program on subprocess errors       
    local exit_on_error="false"

    local soft_alert=0 # Does a soft alert need to be triggered, if yes, send an alert once 
    local log_ttime=0 # local time instance for comparaison

    local seconds_begin=$SECONDS # Seconds since the beginning of the script
    local exec_time=0 # Seconds since the beginning of this function

    local retval=0 # return value of monitored pid process
    local errorcount=0 # Number of pids that finished with errors

    local pidCount # number of given pids
    local c # counter for pids/procsArray

    pidCount=${#pidsArray[@]}
    echo "  pidCount: $pidCount"
    echo "  pidsArray: ${pidsArray[@]}"

    while [ ${#pidsArray[@]} -gt 0 ]; do

        newPidsArray=()
        newProcsArray=()
        c=0

        for pid in "${pidsArray[@]}"; do

            #echo "pid: $pid"
            #echo "proc: ${procsArray[c]}"

            if kill -0 $pid > /dev/null 2>&1; then
                newPidsArray+=($pid)
                #echo "newPidsArray: ${newPidsArray[@]}"
                newProcsArray+=(${procsArray[c]})
                #echo "newProcsArray: ${newProcsArray[@]}"

            else

                wait $pid
                result=$?
                #echo "result: $result"
                if [ $result -ne 0 ]; then
                    errorcount=$((errorcount+1))
                    echo "  *** WARNING! **** Process ${procsArray[c]} with pid $pid FAILED (with exitcode [$result]). Check the log-file"
                else
                    echo "  Process ${procsArray[c]} with pid $pid finished successfully (with exitcode [$result])."
                fi

            fi

            c=$((c+1))

        done

        ## Log a standby message every hour
        every_time=1200
        exec_time=$(($SECONDS - $seconds_begin))
        if [ $((($exec_time + 1) % $every_time)) -eq 0 ]; then
            if [ $log_ttime -ne $exec_time ]; then
                log_ttime=$exec_time
                log_min=$((log_ttime / 60))
                echo "  Current tasks [${procsArray[@]}] still running after $log_min minutes with pids [${pidsArray[@]}]."
            fi
        fi

        #if [ $exec_time -gt $soft_max_time ]; then
        #    if [ $soft_alert -eq 0 ] && [ $soft_max_time -ne 0 ]; then
        #        echo "Max soft execution time exceeded for task [$caller_name] with pids [${pidsArray[@]}]."
        #        soft_alert=1
        #        #SendAlert
        #
        #    fi
        #    if [ $exec_time -gt $hard_max_time ] && [ $hard_max_time -ne 0 ]; then
        #        echo "Max hard execution time exceeded for task [$caller_name] with pids [${pidsArray[@]}]. Stopping task execution."
        #        #kill -SIGTERM $pid
        #        if [ $? == 0 ]; then
        #            echo "Task stopped successfully"
        #        else
        #            errrorcount=$((errorcount+1))
        #        fi
        #    fi
        #fi

        pidsArray=("${newPidsArray[@]}")
        procsArray=("${newProcsArray[@]}")
        sleep 1



    done

    #echo "${FUNCNAME[0]} ended for [$caller_name] using [$pidCount] subprocesses with [$errorcount] errors."
    #if [ $exit_on_error == true ] && [ $errorcount -gt 0 ]; then
    #    echo "Stopping execution."
    #    exit 1337
    #else
    #    return $errorcount
    #fi

}



# end of local function --------------





# MAIN STARTS HERE

# Set some defaults
silent=1
ncpu=6
mem_gb=24
bids_dir=BIDS
expert=0
make_pbs_files_instead_of_running=0
tmp=/tmp

# Set flags
conf_flag=0
bids_flag=0
tmp_flag=0
cpu_flag=0
mem_flag=0
docker_reset_flag=0

# Check command line options, and return function Usage if required options are not given
if [ "$#" -lt 2 ]; then
    Usage >&2
    exit 1

else

    while getopts "c:b:n:m:t:ervh" OPT; do

        case $OPT in
        c) #config_file
            conf_flag=1
            conf=$OPTARG
        ;;
        b) #bids_dir
            bids_flag=1
            bids_dir=$OPTARG
        ;;
        n) #ncpu
            cpu_flag=1
            ncpu=$OPTARG
        ;;
        m) #bids_dir
            mem_flag=1
            mem_gb=$OPTARG
        ;;
        t) #temporary directory
            tmp_flag=1
            tmp=$OPTARG
        ;;
        r) #reset docker
            docker_reset_flag=1
        ;;
        v) #verbose
            silent=0
        ;;
        e) #expert
            expert=1
        ;;
        h) #help
            Usage >&2
            exit 0
        ;;
        \?)
            echo "Invalid option: -$OPTARG" >&2
            echo
            Usage >&2
            exit 1
        ;;
        :)
            echo "Option -$OPTARG requires an argument." >&2
            echo
            Usage >&2
            exit 1
        ;;
        esac

    done

fi

# check for required options
if [ $conf_flag -eq 0 ] ; then 
    echo 
    echo "Option -c is required: give the path to the file that describes the subjects" >&2
    echo
    exit 2 

elif [ ! -f $conf ] ; then
    echo 
    echo "The config file $conf does not exist"
    echo
    exit 2
fi 


# INITIATE ---



# ----------- MAIN ----------------------------------------------------------------------------------

if [ $silent -eq 0 ]; then
    echo "  The script you are running has basename `basename "$0"`, located in dirname $kul_main_dir"
    echo "  The present working directory is `pwd`"
fi

# ---------- SET MAIN DEFAULTS ---
# set mem_mb for mriqc/fmriprep
gb=1024
mem_mb=$(echo $mem_gb $gb | awk '{print $1 * $2 }')

# freesurfer license (check if set as environent variable, if not set hard coded)
if [ -z $FS_LICENSE ]; then

    echo "  freesurfer_license was not found; setting it hard to /KUL_apps/freesurfer/license.txt"
    freesurfer_license=/KUL_apps/freesurfer/license.txt

else
    
    freesurfer_license=$FS_LICENSE
    echo "  freesurfer_license was set before (notably: $freesurfer_license)"
    
fi

# ---------- PROCESS CONTROL & LOAD BALANCING --------
# We will be running 4 preprocessings in parallel: mriqc, fmriprep, freesurfer & KUL_dwiprep
# We need to do some load balancing #FLAG, needs optimisation, a.o. if some processes finished already!

# set number of cores for task mriqc
load_mriqc=37 # higher number means less cpu need (mriqc does not need much)
ncpu_mriqc=$(((($ncpu/$load_mriqc))+1))
ncpu_mriqc_ants=$(((($ncpu/$load_mriqc))+1))

# set number of cores for task fmriprep
load_fmriprep=5
ncpu_fmriprep=$(((($ncpu/$load_fmriprep))+1))
ncpu_fmriprep_ants=$(((($ncpu/$load_fmriprep))+1))

# set number of cores for task freesurfer
load_freesurfer=2
ncpu_freesurfer=$(((($ncpu/$load_freesurfer))+1))

# set number of cores for task KUL_dwiprep
load_dwiprep=2
ncpu_dwiprep=$(((($ncpu/$load_dwiprep))+1))


# Ask if docker needs to be reset
if [ $docker_reset_flag -eq 1 ];then
    docker system prune -a
fi



# ----------- STEP 1 - Preprocess each subject with mriqc, fmriprep, freesurfer and KUL_dwiprep ---
# 
# 


if [ $expert -eq 1 ]; then

    # Expert mode
    echo "  Using Expert mode"

    # check exit_after
    exit_after=$(grep exit_after $conf | grep -v \# |  sed 's/[^0-9]//g')
    if [ -z "$exit_after" ]; then
        exit_after=0
    fi 
    echo "  exit_after: $exit_after"

    #check make_pbs_files_instead_of_running
    make_pbs_files_instead_of_running=$(grep make_pbs_files_instead_of_running $conf | grep -v \# | sed 's/[^0-9]//g')
    if [ -z "$make_pbs_files_instead_of_running" ]; then
        make_pbs_files_instead_of_running=0
    fi 
    echo "  make_pbs_files_instead_of_running: $make_pbs_files_instead_of_running"

    if [ $make_pbs_files_instead_of_running -eq 1 ]; then

        pbs_cpu=$(grep pbs_cpu $conf | grep -v \# | sed 's/[^0-9]//g')
        pbs_mem=$(grep pbs_mem $conf | grep -v \# | sed 's/[^0-9]//g')
        pbs_lp=$(grep pbs_lp $conf | grep -v \# | cut -d':' -f 2 | tr -d '\r')
        pbs_email=$(grep pbs_email $conf | grep -v \# | cut -d':' -f 2 | tr -d '\r')
        pbs_walltime=$(grep pbs_walltime $conf | grep -v \# | cut -d':' -f 2- | tr -d '\r')
        pbs_singularity_mriqc=$(grep pbs_singularity_mriqc $conf | grep -v \# | cut -d':' -f 2 | tr -d '\r')
        pbs_singularity_fmriprep=$(grep pbs_singularity_fmriprep $conf | grep -v \# | cut -d':' -f 2 | tr -d '\r')

        if [ $silent -eq 0 ]; then

            echo "  pbs_cpu: $pbs_cpu"
            echo "  pbs_mem: $pbs_mem"
            echo "  pbs_lp: $pbs_lp"
            echo "  pbs_email: $pbs_email"
            echo "  pbs_walltime: $pbs_walltime"
            echo "  pbs_singularity_mriqc: ${pbs_singularity_mriqc}"
            echo "  pbs_singularity_fmriprep: $pbs_singularity_fmriprep"

        fi

        #mriqc_rand=$(cat /dev/urandom | env LC_CTYPE=C tr -dc 'a-zA-Z0-9' | fold -w 8 | head -n 1)
        #pbs_data_file="pbs_data_mriqc_${mriqc_rand}.csv"

    fi


    #check mriqc and options
    do_mriqc=$(grep do_mriqc $conf | grep -v \# | sed 's/[^0-9]//g')
    if [ -z "$do_mriqc" ]; then
        do_mriqc=0
    fi 
    echo "  do_mriqc: $do_mriqc"
    
    if [ $do_mriqc -eq 1 ]; then

        mriqc_options=$(grep mriqc_options $conf | grep -v \# | cut -d':' -f 2 | tr -d '\r')

        mriqc_ncpu=$(grep mriqc_ncpu $conf | grep -v \# | sed 's/[^0-9]//g' | tr -d '\r')
        ncpu_mriqc=$mriqc_ncpu
        ncpu_mriqc_ants=$mriqc_ncpu
        
        mriqc_mem=$(grep mriqc_mem $conf | grep -v \# | sed 's/[^0-9]//g' | tr -d '\r')
        mem_gb=$mriqc_mem
    
        #get bids_participants
        BIDS_subjects=($(grep BIDS_participants $conf | grep -v \# | cut -d':' -f 2 | tr -d '\r'))
        n_subj=${#BIDS_subjects[@]}
            
        mriqc_simultaneous=$(grep mriqc_simultaneous $conf | grep -v \# | sed 's/[^0-9]//g' | tr -d '\r')

        if [ $make_pbs_files_instead_of_running -eq 1 ]; then

            mriqc_simultaneous_pbs=$(($mriqc_simultaneous-1))
            mriqc_simultaneous=1

        else

            mriqc_simultaneous_pbs=0

        fi

        if [ $silent -eq 0 ]; then

            echo "  mriqc_options: $mriqc_options"
            echo "  mriqc_ncpu: $mriqc_ncpu"
            echo "  mriqc_mem: $mriqc_mem"
            echo "  BIDS_participants: ${BIDS_subjects[@]}"
            echo "  number of BIDS_participants: $n_subj"
            echo "  mriqc_simultaneous: $mriqc_simultaneous"
            echo "  mriqc_simultaneous_pbs: $mriqc_simultaneous_pbs"

        fi

        # check if already performed mriqc
        todo_bids_participants=()
        already_done=()

        for i_bids_participant in $(seq 0 $(($n_subj-1))); do

            mriqc_dir_to_check=mriqc/sub-${BIDS_subjects[$i_bids_participant]}

            #echo $mriqc_dir_to_check
            if [ ! -d $mriqc_dir_to_check ]; then

                todo_bids_participants+=(${BIDS_subjects[$i_bids_participant]})
            
            else

                already_done+=(${BIDS_subjects[$i_bids_participant]})
            
            fi

        done

        echo "  mriqc was already done for participant(s) ${already_done[@]}"
        
        # submit the jobs (and split them in chucks)
        n_subj_todo=${#todo_bids_participants[@]}
        task_number=1
        task_counter=1
         
        for i_bids_participant in $(seq 0 $mriqc_simultaneous $(($n_subj_todo-1))); do


            mriqc_participants=${todo_bids_participants[@]:$i_bids_participant:$mriqc_simultaneous}
            #echo " going to start mriqc with $mriqc_simultaneous participants simultaneously, notably $mriqc_participants"

            pbs_data_file="VSC/pbs_data_mriqc_job${task_number}.csv"
            if [ $task_counter -gt $mriqc_simultaneous_pbs ]; then
                task_number=$((task_number+1))
                task_counter=1
            fi
            task_counter=$((task_counter+1))    

            BIDS_participant=$mriqc_participants
            mriqc_pid=-1
            waitforprocs=()
            waitforpids=()

            task_mriqc_participant

            if [ $mriqc_pid -gt 0 ]; then
                waitforprocs+=("mriqc")
                waitforpids+=($mriqc_pid)
            fi
        
            
            kul_e2cl " waiting for processes [${waitforpids[@]}] for subject(s) $mriqc_participants to finish before continuing with further processing... (this can take hours!)... " $log
            WaitForTaskCompletion 

            kul_e2cl " processes [${waitforpids[@]}] for subject(s) $mriqc_participants have finished" $log

        done

    fi


    #check fmriprep and options
    do_fmriprep=$(grep do_fmriprep $conf | grep -v \# | sed 's/[^0-9]//g')
    if [ -z "$do_fmriprep" ]; then
        do_fmriprep=0
    fi 
    echo "  do_fmriprep: $do_fmriprep"
    
    if [ $do_fmriprep -eq 1 ]; then

        fmriprep_options=$(grep fmriprep_options $conf | grep -v \# | cut -d':' -f 2-1000)

        fmriprep_ncpu=$(grep fmriprep_ncpu $conf | grep -v \# | sed 's/[^0-9]//g')
        ncpu_fmriprep=$fmriprep_ncpu
        ncpu_fmriprep_ants=$fmriprep_ncpu
        
        fmriprep_mem=$(grep fmriprep_mem $conf | grep -v \# | sed 's/[^0-9]//g')
        gb=1024
        mem_mb=$(echo $fmriprep_mem $gb | awk '{print $1 * $2 }')

        #get bids_participants
        BIDS_subjects=($(grep BIDS_participants $conf | grep -v \# | cut -d':' -f 2))
        n_subj=${#BIDS_subjects[@]}
            
        fmriprep_simultaneous=$(grep fmriprep_simultaneous $conf | grep -v \# | sed 's/[^0-9]//g')

        if [ $make_pbs_files_instead_of_running -eq 1 ]; then

            fmriprep_simultaneous_pbs=$(($fmriprep_simultaneous-1))
            fmriprep_simultaneous=1

        else

            fmriprep_simultaneous_pbs=0

        fi

        if [ $silent -eq 0 ]; then

            echo "  fmriprep_options: $fmriprep_options"
            echo "  fmriprep_ncpu: $fmriprep_ncpu"
            echo "  fmriprep_mem: $fmriprep_mem"
            echo "  BIDS_participants: ${BIDS_subjects[@]}"
            echo "  number of BIDS_participants: $n_subj"
            echo "  fmriprep_simultaneous: $fmriprep_simultaneous"

        fi
        
        fmriprep_force_redo=$(grep fmriprep_force_redo $conf | grep -v \# | sed 's/[^0-9]//g')

        # check if already performed fmriprep
        todo_bids_participants=()
        already_done=()

        #if [ ! "$fmriprep_force_redo" == "1" ]; then

            for i_bids_participant in $(seq 0 $(($n_subj-1))); do

                fmriprep_dir_to_check=fmriprep/sub-${BIDS_subjects[$i_bids_participant]}

                #echo $fmriprep_dir_to_check
                if [ ! -d $fmriprep_dir_to_check ]; then

                    todo_bids_participants+=(${BIDS_subjects[$i_bids_participant]})
            
                else

                    already_done+=(${BIDS_subjects[$i_bids_participant]})
            
                fi

            done

            echo "  fmriprep was already done for participant(s) ${already_done[@]}"
        
        #fi
        
        # submit the jobs (and split them in chucks)
        n_subj_todo=${#todo_bids_participants[@]}
        task_number=1
        task_counter=1

        for i_bids_participant in $(seq 0 $fmriprep_simultaneous $(($n_subj_todo-1))); do

            fmriprep_participants=${todo_bids_participants[@]:$i_bids_participant:$fmriprep_simultaneous}
            #echo " going to start fmriprep with $fmriprep_simultaneous participants simultaneously, notably $fmriprep_participants"

            pbs_data_file="VSC/pbs_data_fmriprep_job${task_number}.csv"
            if [ $task_counter -gt $fmriprep_simultaneous_pbs ]; then
                task_number=$((task_number+1))
                task_counter=1
            fi
            task_counter=$((task_counter+1))   

            #for BIDS_participant in $fmriprep_participants; do
                
                BIDS_participant=$fmriprep_participants
                fmriprep_pid=-1
                waitforprocs=()
                waitforpids=()

                task_fmriprep

                if [ $fmriprep_pid -gt 0 ]; then
                    waitforprocs+=("fmriprep")
                    waitforpids+=($fmriprep_pid)
                fi

            #done

            kul_e2cl " waiting for processes [${waitforpids[@]}] for subject(s) $fmriprep_participants to finish before continuing with further processing... (this can take hours!)... " $log
            WaitForTaskCompletion 

            kul_e2cl " processes [${waitforpids[@]}] for subject(s) $fmriprep_participants have finished" $log

        done

    fi


    #check freesurfer and options
    do_freesurfer=$(grep do_freesurfer $conf | grep -v \# | sed 's/[^0-9]//g')
    if [ -z "$do_freesurfer" ]; then
        do_freesurfer=0
    fi 
    echo "  do_freesurfer: $do_freesurfer"
    
    if [ $do_freesurfer -eq 1 ]; then

        freesurfer_options=$(grep freesurfer_options $conf | grep -v \# | cut -d':' -f 2 | tr -d '\r')
        fs_options_direct=$(grep freesurfer_direct_options $conf | grep -v \# | cut -d':' -f 2 | tr -d '\r')

        freesurfer_ncpu=$(grep freesurfer_ncpu $conf | grep -v \# | sed 's/[^0-9]//g')
        ncpu_freesurfer=$freesurfer_ncpu
       
 
        #get bids_participants
        BIDS_subjects=($(grep BIDS_participants $conf | grep -v \# | cut -d':' -f 2 | tr -d '\r'))
        n_subj=${#BIDS_subjects[@]}
            
        freesurfer_simultaneous=$(grep freesurfer_simultaneous $conf | grep -v \# | sed 's/[^0-9]//g')

        if [ $silent -eq 0 ]; then

            echo "  freesurfer_options: $freesurfer_options"
            echo "  freesurfer_direct_options: $fs_options_direct"
            echo "  freesurfer_ncpu: $freesurfer_ncpu"
            echo "  BIDS_participants: ${BIDS_subjects[@]}"
            echo "  number of BIDS_participants: $n_subj"
            echo "  freesurfer_simultaneous: $freesurfer_simultaneous"

        fi

        # check if already performed freesurfer
        todo_bids_participants=()
        already_done=()


        for i_bids_participant in $(seq 0 $(($n_subj-1))); do

            freesurfer_file_to_check=${cwd}/freesurfer/sub-${BIDS_subjects[i_bids_participant]}_freesurfer_is.done

            #echo $freesurfer_file_to_check
            if [ ! -f $freesurfer_file_to_check ]; then

                todo_bids_participants+=(${BIDS_subjects[$i_bids_participant]})
            
            else

                already_done+=(${BIDS_subjects[$i_bids_participant]})
            
            fi

        done

        echo "  freesurfer was already done for participant(s) ${already_done[@]}"


        # submit the jobs (and split them in chucks)
        n_subj_todo=${#todo_bids_participants[@]}

        for i_bids_participant in $(seq 0 $freesurfer_simultaneous $(($n_subj_todo-1))); do

            fs_participants=${todo_bids_participants[@]:$i_bids_participant:$freesurfer_simultaneous}
            echo "  going to start freesurfer with $freesurfer_simultaneous participants simultaneously, notably $fs_participants"
        
            freesurfer_pid=-1
            waitforprocs=()
            waitforpids=()
    
            for BIDS_participant in $fs_participants; do
                
               
                #echo $BIDS_participant
                task_freesurfer

                if [ $freesurfer_pid -gt 0 ]; then
                    waitforprocs+=("freesurfer")
                    waitforpids+=($freesurfer_pid)
                fi
            
            done 

            kul_e2cl "  waiting for freesurfer processes [${waitforpids[@]}] for subject(s) $fs_participants to finish before continuing with further processing... (this can take hours!)... " $log
                WaitForTaskCompletion 

            kul_e2cl " freesurfer processes [${waitforpids[@]}] for subject(s) $fs_participants have finished" $log

            
        done
       
    fi


    #check dwiprep and options
    do_dwiprep=$(grep do_dwiprep: $conf | grep -v \# | sed 's/[^0-9]//g')
    if [ -z "$do_dwiprep" ]; then
        do_dwiprep=0
    fi 
    echo "  do_dwiprep: $do_dwiprep"
    
    if [ $do_dwiprep -eq 1 ]; then

        dwiprep_options=$(grep dwiprep_options $conf | grep -v \# | cut -d':' -f 2 | tr -d '\r')
        dwipreproc_options=$dwiprep_options

        topup_options=$(grep topup_options $conf | grep -v \# | cut -d':' -f 2 | tr -d '\r')
        eddy_options=$(grep eddy_options $conf | grep -v \# | cut -d':' -f 2 | tr -d '\r')

        dwiprep_ncpu=$(grep dwiprep_ncpu $conf | grep -v \# | sed 's/[^0-9]//g')
        ncpu_dwiprep=$dwiprep_ncpu
        
        #get bids_participants
        BIDS_subjects=($(grep BIDS_participants $conf | grep -v \# | cut -d':' -f 2 | tr -d '\r'))
        n_subj=${#BIDS_subjects[@]}
            
        dwiprep_simultaneous=$(grep dwiprep_simultaneous $conf | grep -v \# | sed 's/[^0-9]//g')

        if [ $silent -eq 0 ]; then

            echo "  dwiprep_options: $dwiprep_options"
            echo "  topup_options: $topup_options"
            echo "  eddy_options: $eddy_options"
            echo "  dwiprep_ncpu: $dwiprep_ncpu"
            echo "  BIDS_participants: ${BIDS_subjects[@]}"
            echo "  number of BIDS_participants: $n_subj"
            echo "  dwiprep_simultaneous: $dwiprep_simultaneous"

        fi

        # check if already performed dwiprep
        todo_bids_participants=()
        already_done=()

        for i_bids_participant in $(seq 0 $(($n_subj-1))); do

            dwiprep_file_to_check=${cwd}/dwiprep/sub-${BIDS_subjects[$i_bids_participant]}/dwiprep_is_done.log

            #echo $dwiprep_file_to_check
            if [ ! -f $dwiprep_file_to_check ]; then

                todo_bids_participants+=(${BIDS_subjects[$i_bids_participant]})
            
            else

                already_done+=(${BIDS_subjects[$i_bids_participant]})
            
            fi

        done

        echo "  dwiprep was already done for participant(s) ${already_done[@]}"
        
        # submit the jobs (and split them in chucks)
        n_subj_todo=${#todo_bids_participants[@]}

        for i_bids_participant in $(seq 0 $dwiprep_simultaneous $(($n_subj_todo-1))); do

            fs_participants=${todo_bids_participants[@]:$i_bids_participant:$dwiprep_simultaneous}
            echo "  going to start dwiprep with $dwiprep_simultaneous participants simultaneously, notably $fs_participants"

            dwiprep_pid=-1
            waitforprocs=()
            waitforpids=()

            for BIDS_participant in $fs_participants; do
                
              
                #echo $BIDS_participant
                task_KUL_dwiprep

                if [ $dwiprep_pid -gt 0 ]; then
                    waitforprocs+=("dwiprep")
                    waitforpids+=($dwiprep_pid)
                fi
            
            done 

            kul_e2cl "  waiting for dwiprep processes [${waitforpids[@]}] for subject(s) $fs_participants to finish before continuing with further processing... (this can take hours!)... " $log
                WaitForTaskCompletion 

            kul_e2cl " dwiprep processes [${waitforpids[@]}] for subject(s) $fs_participants have finished" $log

            
        done
       
    fi

    if [ $exit_after -eq 1 ]; then

        kul_e2cl "  we exit here, you will need to do further processing with another config_file... " $log
        exit 0
    
    fi

    # Rest of processing steps

    #check dwiprep_anat and options
    do_dwiprep_anat=$(grep do_dwiprep_anat: $conf | grep -v \# | sed 's/[^0-9]//g')
    if [ -z "$do_dwiprep_anat" ]; then
        do_dwiprep_anat=0
    fi 
    echo "  do_dwiprep_anat: $do_dwiprep_anat"

    #get bids_participants
    BIDS_subjects=($(grep BIDS_participants $conf | grep -v \# | cut -d':' -f 2 | tr -d '\r'))
    n_subj=${#BIDS_subjects[@]}
            
    dwiprep_anat_simultaneous=$(grep dwiprep_anat_simultaneous $conf | grep -v \# | sed 's/[^0-9]//g')

    # continue with KUL_dwiprep_anat, which depends on finished data from freesurfer, fmriprep & KUL_dwiprep
    if [ $do_dwiprep_anat -eq 1 ]; then

        dwiprep_anat_ncpu=$(grep dwiprep_anat_ncpu $conf | grep -v \# | sed 's/[^0-9]//g')
        
        if [ $silent -eq 0 ]; then

            echo "  dwiprep_anat_ncpu: $dwiprep_anat_ncpu"
            echo "  BIDS_participants: ${BIDS_subjects[@]}"
            echo "  number of BIDS_participants: $n_subj"
            echo "  dwiprep_anat_simultaneous: $dwiprep_anat_simultaneous"

        fi

        # check if already performed dwiprep
        todo_bids_participants=()
        already_done=()

        for i_bids_participant in $(seq 0 $(($n_subj-1))); do

            dwiprep_anat_file_to_check=${cwd}/dwiprep/sub-${BIDS_subjects[$i_bids_participant]}/dwiprep_anat_is_done.log

            #echo $dwiprep_anat_file_to_check
            if [ ! -f $dwiprep_anat_file_to_check ]; then

                todo_bids_participants+=(${BIDS_subjects[$i_bids_participant]})
            
            else

                already_done+=(${BIDS_subjects[$i_bids_participant]})
            
            fi

        done

        echo "  dwiprep_anat was already done for participant(s) ${already_done[@]}"
        
        # submit the jobs (and split them in chucks)
        n_subj_todo=${#todo_bids_participants[@]}
        

        for i_bids_participant in $(seq 0 $dwiprep_anat_simultaneous $(($n_subj_todo-1))); do

            fs_participants=${todo_bids_participants[@]:$i_bids_participant:$dwiprep_anat_simultaneous}
            echo "  going to start dwiprep_anat with $dwiprep_anat_simultaneous participants simultaneously, notably $fs_participants"

            dwiprep_anat_pid=-1
            waitforprocs=()
            waitforpids=()

            for BIDS_participant in $fs_participants; do
                
              
                #echo $BIDS_participant
                task_KUL_dwiprep_anat

                if [ $dwiprep_anat_pid -gt 0 ]; then
                    waitforprocs+=("dwiprep_anat")
                    waitforpids+=($dwiprep_anat_pid)
                fi
            
            done 

            kul_e2cl "  waiting for dwiprep_anat processes [${waitforpids[@]}] for subject(s) $fs_participants to finish before continuing with further processing... (this can take hours!)... " $log
                WaitForTaskCompletion 

            kul_e2cl " dwiprep_anat processes [${waitforpids[@]}] for subject(s) $fs_participants have finished" $log

            
        done


    fi 

    #check dwiprep_MNI and options
    do_dwiprep_MNI=$(grep do_dwiprep_MNI: $conf | grep -v \# | sed 's/[^0-9]//g')
    if [ -z "$do_dwiprep_MNI" ]; then
        do_dwiprep_MNI=0
    fi 
    echo "  do_dwiprep_MNI: $do_dwiprep_MNI"

    #get bids_participants
    BIDS_subjects=($(grep BIDS_participants $conf | grep -v \# | cut -d':' -f 2 | tr -d '\r'))
    n_subj=${#BIDS_subjects[@]}
            
    dwiprep_MNI_simultaneous=$(grep dwiprep_MNI_simultaneous $conf | grep -v \# | sed 's/[^0-9]//g')

    # continue with KUL_dwiprep_MNI, which depends on finished data from freesurfer, fmriprep & KUL_dwiprep
    if [ $do_dwiprep_MNI -eq 1 ]; then

        dwiprep_MNI_ncpu=$(grep dwiprep_MNI_ncpu $conf | grep -v \# | sed 's/[^0-9]//g')

        if [ $silent -eq 0 ]; then

            echo "  dwiprep_MNI_ncpu: $dwiprep_MNI_ncpu"
            echo "  BIDS_participants: ${BIDS_subjects[@]}"
            echo "  number of BIDS_participants: $n_subj"
            echo "  dwiprep_MNI_simultaneous: $dwiprep_MNI_simultaneous"

        fi

        # check if already performed dwiprep
        todo_bids_participants=()
        already_done=()

        for i_bids_participant in $(seq 0 $(($n_subj-1))); do

            dwiprep_MNI_file_to_check=${cwd}/dwiprep/sub-${BIDS_subjects[$i_bids_participant]}/dwiprep_MNI_is_done.log

            #echo $dwiprep_MNI_file_to_check
            if [ ! -f $dwiprep_MNI_file_to_check ]; then

                todo_bids_participants+=(${BIDS_subjects[$i_bids_participant]})
            
            else

                already_done+=(${BIDS_subjects[$i_bids_participant]})
            
            fi

        done

        echo "  dwiprep_MNI was already done for participant(s) ${already_done[@]}"
        
        # submit the jobs (and split them in chucks)
        n_subj_todo=${#todo_bids_participants[@]}
        

        for i_bids_participant in $(seq 0 $dwiprep_MNI_simultaneous $(($n_subj_todo-1))); do

            fs_participants=${todo_bids_participants[@]:$i_bids_participant:$dwiprep_MNI_simultaneous}
            echo "  going to start dwiprep_MNI with $dwiprep_MNI_simultaneous participants simultaneously, notably $fs_participants"

            dwiprep_MNI_pid=-1
            waitforprocs=()
            waitforpids=()

            for BIDS_participant in $fs_participants; do
                
              
                #echo $BIDS_participant
                task_KUL_dwiprep_MNI

                if [ $dwiprep_MNI_pid -gt 0 ]; then
                    waitforprocs+=("dwiprep_MNI")
                    waitforpids+=($dwiprep_MNI_pid)
                fi
            
            done 

            kul_e2cl "  waiting for dwiprep_MNI processes [${waitforpids[@]}] for subject(s) $fs_participants to finish before continuing with further processing... (this can take hours!)... " $log
                WaitForTaskCompletion 

            kul_e2cl " dwiprep_MNI processes [${waitforpids[@]}] for subject(s) $fs_participants have finished" $log

            
        done


    fi 
        

    # Here we could also have some whole brain tractography processing e.g.
    # task_KUL_mrtix_wb_tckgen # needs to be made
    # task_KUL_mrtrix_tractsegment # needs to be made
        
    # continue with KUL_dwiprep_fibertract
    #check do_dwiprep_fibertract and options
    do_dwiprep_fibertract=$(grep do_dwiprep_fibertract $conf | grep -v \# | sed 's/[^0-9]//g')
    if [ -z "$do_dwiprep_fibertract" ]; then
        do_dwiprep_fibertract=0
    fi 
    echo "  do_dwiprep_fibertract: $do_dwiprep_fibertract"
    
    if [ $do_dwiprep_fibertract -eq 1 ]; then

        # get bids_participants
        BIDS_subjects=($(grep BIDS_participants $conf | grep -v \# | cut -d':' -f 2 | tr -d '\r'))
        n_subj=${#BIDS_subjects[@]}
        # get other parameters    
        dwiprep_fibertract_ncpu=$(grep dwiprep_fibertract_ncpu $conf | grep -v \# | sed 's/[^0-9]//g')
        dwiprep_fibertract_simultaneous=$(grep dwiprep_fibertract_simultaneous $conf | grep -v \# | sed 's/[^0-9]//g')
        dwiprep_fibertract_rois_file=$(grep dwiprep_fibertract_rois_file $conf | grep -v \# | cut -d':' -f 2 | tr -d '\r')
        dwiprep_fibertract_conf_file=$(grep dwiprep_fibertract_conf_file $conf | grep -v \# | cut -d':' -f 2 | tr -d '\r')
        dwiprep_fibertract_response_file=$(grep dwiprep_fibertract_response_file $conf | grep -v \# | cut -d':' -f 2 | tr -d '\r')
        dwiprep_fibertract_whole_brain=$(grep dwiprep_fibertract_whole_brain $conf | grep -v \# | sed 's/[^0-9]//g')

        if [ $silent -eq 0 ]; then

            echo "  BIDS_participants: ${BIDS_subjects[@]}"
            echo "  number of BIDS_participants: $n_subj"
            echo "  dwiprep_fibertract_cpu: $dwiprep_fibertract_cpu"
            echo "  dwiprep_fibertract_rois_file: $dwiprep_fibertract_rois_file"
            echo "  dwiprep_fibertract_conf_file: $dwiprep_fibertract_conf_file"
            echo "  dwiprep_fibertract_response_file: $dwiprep_fibertract_response_file"
            echo "  dwiprep_fibertract_whole_brain: $dwiprep_fibertract_whole_brain"
            echo "  dwiprep_fibertract_simultaneous: $dwiprep_fibertract_simultaneous"

        fi

        # check if already performed dwiprep_fibertract
        todo_bids_participants=()
        already_done=()

        for i_bids_participant in $(seq 0 $(($n_subj-1))); do

            dwiprep_fibertract_file_to_check=${cwd}/dwiprep/sub-${BIDS_subjects[$i_bids_participant]}/dwiprep_fibertract_is_done.log

            #echo $dwiprep_fibertract_file_to_check
            if [ ! -f $dwiprep_fibertract_file_to_check ]; then

                todo_bids_participants+=(${BIDS_subjects[$i_bids_participant]})
            
            else

                already_done+=(${BIDS_subjects[$i_bids_participant]})
            
            fi

        done

        echo "  dwiprep_fibertract was already done for participant(s) ${already_done[@]}"
        
        # submit the jobs (and split them in chucks)
        n_subj_todo=${#todo_bids_participants[@]}

        for i_bids_participant in $(seq 0 $dwiprep_fibertract_simultaneous $(($n_subj_todo-1))); do

            fs_participants=${todo_bids_participants[@]:$i_bids_participant:$dwiprep_fibertract_simultaneous}
            echo "  going to start dwiprep_fibertract with $dwiprep_fibertract_simultaneous participants simultaneously, notably $fs_participants"

            dwiprep_fibertract_pid=-1
            waitforprocs=()
            waitforpids=()

            for BIDS_participant in $fs_participants; do
                
              
                #echo $BIDS_participant

                task_KUL_dwiprep_fibertract
                
                if [ $dwiprep_fibertract_pid -gt 0 ]; then
                    waitforprocs+=("dwiprep_fibertract")
                    waitforpids+=($dwiprep_fibertract_pid)
                fi
            
            done 

            kul_e2cl "  waiting for dwiprep_fibertract processes [${waitforpids[@]}] for subject(s) $fs_participants to finish before continuing with further processing... (this can take hours!)... " $log
                WaitForTaskCompletion 

            kul_e2cl " dwiprep_fibertract processes [${waitforpids[@]}] for subject(s) $fs_participants have finished" $log

            
        done

    fi

else

    # regular mode 


 # we read the config file (and it may be csv, tsv or ;-seperated)
 while IFS=$'\t,;' read -r BIDS_participant do_mriqc mriqc_options do_fmriprep fmriprep_options do_freesurfer freesurfer_options do_dwiprep dwipreproc_options topup_options  eddy_options do_dwiprep_anat anat_options do_dwiprep_fibertract; do
    
    
    if [ "$BIDS_participant" = "BIDS_participant" ]; then
        
        echo "first line" > /dev/null 2>&1

    else

        kul_e2cl "Performing preprocessing of subject $BIDS_participant... " $log
        
        kul_e2cl " Now starting (depending on your config-file) mriqc, fmriprep, freesurfer and KUL_dwiprep... " $log
        echo "   note: further processing with KUL_dwiprep_anat, KUL_dwiprep_drtdbs depend on fmriprep, freesurfer and KUL_dwiprep (which need to run fully)"

        if [ $silent -eq 0 ]; then
            
            echo "  if this script fails, please check your configuration file (given to -c); for now this was what was defined:"
            echo "    BIDS_participant: $BIDS_participant"
            echo "    do_mriqc: $do_mriqc"
            echo "    mriqc_options: $mriqc_options"
            echo "    do_fmriprep: $do_fmriprep"
            echo "    fmriprep_options: $fmriprep_options"
            echo "    do_freesurfer: $do_freesurfer"
            echo "    freesurfer_options: $freesurfer_options"
            echo "    do_dwiprep: $do_dwiprep"
            echo "    dwipreproc_options: $dwipreproc_options"
            echo "    topup_options: $topup_options"
            echo "    eddy_options: $eddy_options"
            echo "    do_dwiprep_anat: $do_dwiprep_anat"
            echo "    anat_options: $anat_options"
            echo "    do_dwiprep_drtdbs: $do_dwiprep_drtdbs"
            #echo "    drtdbs_options: $drtdbs_options"
        
        fi

        # reset pids
        mriqc_pid=-1
        fmriprep_pid=-1
        freesurfer_pid=-1
        dwiprep_pid=-1

        if [ $do_mriqc -eq 1 ]; then

            # check if already performed mriqc
            mriqc_dir_to_check=mriqc/sub-${BIDS_participant}

            if [ ! -d $mriqc_dir_to_check ]; then
            
                task_mriqc_participant 

            else

                echo " mriqc of participant $BIDS_participant already done, skipping..."

            fi

        fi

        if [ $do_fmriprep -eq 1 ]; then
            
            # check if already performed fmriprep
            fmriprep_file_to_check=fmriprep/sub-${BIDS_participant}.html

            if [ ! -f $fmriprep_file_to_check ]; then

                task_fmriprep 

            else

                echo " fmriprep of participant $BIDS_participant already done, skipping..."

            fi

        fi

        if [ $do_freesurfer -eq 1 ]; then
            
            task_freesurfer 

        fi

        if [ $do_dwiprep -eq 1 ]; then
            
            task_KUL_dwiprep

        fi

        # wait for mriqc, fmriprep, freesurfer and KUL_dwiprep to finish
        waitforprocs=()
        waitforpids=()
        if [ $mriqc_pid -gt 0 ]; then
            waitforprocs+=("mriqc")
            waitforpids+=($mriqc_pid)
        fi
        if [ $fmriprep_pid -gt 0 ]; then
            waitforprocs+=("fmriprep")
            waitforpids+=($fmriprep_pid)
        fi
        if [ $freesurfer_pid -gt 0 ]; then
            waitforprocs+=("freesurfer")
            waitforpids+=($freesurfer_pid)
        fi
        if [ $dwiprep_pid -gt 0 ]; then
            waitforprocs+=("dwiprep")
            waitforpids+=($dwiprep_pid)
        fi
        
        #echo ${waitforprocs[@]}
        #echo ${waitforpids[@]}
        

        kul_e2cl " waiting for processes [${waitforprocs[@]}] for subject $BIDS_participant to finish before continuing with further processing... (this can take hours!)... " $log
        WaitForTaskCompletion 
        #$waitforpids $waitforprocs 0 0 test false
        
        #wait $mriqc_pid $fmriprep_pid $dwiprep_pid $freesurfer_pid

        kul_e2cl " processes [${waitforprocs[@]}] for subject $BIDS_participant have finished" $log

        # clean up after jobs finished
        #rm -fr ${cwd}/fmriprep_work


        # Here we could also have fMRI statistical analysis e.g.
        # task_KUL_fmri_model # needs to be made

        # Here we could also have rsfMRI processing e.g.
        # task_KUL_fmri_melodic # needs to be made

        # continue with KUL_dwiprep_anat, which depends on finished data from freesurfer, fmriprep & KUL_dwiprep
        if [ $do_dwiprep_anat -eq 1 ]; then

            task_KUL_dwiprep_anat
            task_KUL_dwiprep_MNI

        fi 

        

        # Here we could also have some whole brain tractography processing e.g.
        # task_KUL_mrtix_wb_tckgen # needs to be made
        # task_KUL_mrtrix_tractsegment # needs to be made
        
        # continue with KUL_dwiprep_fibertract
        if [ $do_dwiprep_fibertract -eq 1 ]; then
            
            task_KUL_dwiprep_fibertract

        fi

    fi

 # leave a few spaces before logging to console
 echo ""
 echo ""


 done < $conf


fi


# ----------- STEP 3 - Compute mriqc group summary ---

kul_e2cl "Performing mriqc group summary" $log

# check if already performed group mriqc
mriqc_file_to_check=mriqc/group_bold.html

if [ ! -f $mriqc_file_to_check ]; then
    
    docker run --read-only --tmpfs /run --tmpfs /tmp --rm \
        -v ${cwd}/${bids_dir}:/data:ro -v ${cwd}/mriqc:/out \
        poldracklab/mriqc:latest \
        /data /out group

else

    kul_e2cl " group mriqc already done, skipping..." $log

fi

# ----------- STEP 4 - Compute dwiprep group summary ---

cat dwiprep/sub-*/tracts_info.csv > dwiprep/group_tracts_info.csv &




kul_e2cl "Finished all... " $log