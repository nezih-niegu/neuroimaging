#!/bin/bash

function recon_report(){
	sub2process=$1
	#age=$2
	dicomdir=$2
	#route=$4
	#subject=$5

	#Extracting age from DICOM
	age=$(find $dicomdir -type f \( -name "I[0-9][0-9][0-9][0-9][0-9][0-9][0-9]" -o -name "[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]" -o -name "*.dcm" \) -print -quit | xargs -I {} sh -c "dctable {} -k PatientAge | cut -d '\"' -f 4 | cut -d "Y" -f 1" | bc)
	
	#Creates new directory
	mkdir ~/N1.0Dir/all_niis/$sub2process
	dcm2niix -o ~/N1.0Dir/all_niis/$sub2process -f %p_%s -g y $dicomdir
	
	#Selects heaviest T1, excludes text format exceptions    
	t1nii=$(du ~/N1.0Dir/all_niis/$sub2process/*[tT]1*.nii | grep -v "gd\|GD\|gadolinio" | sort -V | tail -1 | cut -d "	" -f 2)
	
	#recon-all (freesurfer)... this step might take a few hours
	recon-all -all -s $sub2process -i $t1nii -brainstem-structures -hippocampal-subfields-T1

	#new subject directory to store reports 	
	mkdir ~/N1.0Dir/NezihNiegu/neuroimaging_processor/Volumetry/$sub2process
	cd ~/N1.0Dir/NezihNiegu/neuroimaging_processor/Volumetry/$sub2process

	#segments (freesurfer)
	asegstats2table --subjects $sub2process --meas volume --stats=aseg.stats --table=asegstats_vol.txt
	
	#parcels (freesurfer)
	aparcstats2table --subjects $sub2process --hemi lh --meas volume --parc=aparc --tablefile=lhaparc_vol.txt
	aparcstats2table --subjects $sub2process --hemi rh --meas volume --parc=aparc --tablefile=rhaparc_vol.txt
	aparcstats2table --subjects $sub2process --hemi lh --meas thickness --parc=aparc --tablefile=lhaparc_thick.txt
	aparcstats2table --subjects $sub2process --hemi rh --meas thickness --parc=aparc --tablefile=rhaparc_thick.txt
	aparcstats2table --subjects $sub2process --hemi lh --meas area --parc=aparc --tablefile=lhaparc_area.txt
	aparcstats2table --subjects $sub2process --hemi rh --meas area --parc=aparc --tablefile=rhaparc_area.txt

	#quantifying (freesurfer) 
	quantifyHippocampalSubfields.sh T1 hipposubfield_vol.txt
	cp $SUBJECTS_DIR/hipposubfield_vol.txt ./
	quantifyBrainstemStructures.sh brainstemstruct_vol.txt
	cp $SUBJECTS_DIR/brainstemstruct_vol.txt ./

	#data_analysis (python)
	cd ../python_scripts
	export 
	python3 -c "from createPDFreport_spanish import *; createPDFreport_spanish(patient_age=$age,region='rh',metric='vol',subjectANDoutput_dir='/home/neurocogn/N1.0Dir/NezihNiegu/neuroimaging_processor/Volumetry/$sub2process/')"
	python3 -c "from createPDFreport_spanish import *; createPDFreport_spanish(patient_age=$age,region='lh',metric='vol',subjectANDoutput_dir='/home/neurocogn/N1.0Dir/NezihNiegu/neuroimaging_processor/Volumetry/$sub2process/')"
	python3 -c "from createPDFreport_spanish import *; createPDFreport_spanish(patient_age=$age,region='rh',metric='thick',subjectANDoutput_dir='/home/neurocogn/N1.0Dir/NezihNiegu/neuroimaging_processor/Volumetry/$sub2process/')"
	python3 -c "from createPDFreport_spanish import *; createPDFreport_spanish(patient_age=$age,region='lh',metric='thick',subjectANDoutput_dir='/home/neurocogn/N1.0Dir/NezihNiegu/neuroimaging_processor/Volumetry/$sub2process/')"
	python3 -c "from createPDFreport_spanish import *; createPDFreport_spanish(patient_age=$age,region='rh',metric='area',subjectANDoutput_dir='/home/neurocogn/N1.0Dir/NezihNiegu/neuroimaging_processor/Volumetry/$sub2process/')"
	python3 -c "from createPDFreport_spanish import *; createPDFreport_spanish(patient_age=$age,region='lh',metric='area',subjectANDoutput_dir='/home/neurocogn/N1.0Dir/NezihNiegu/neuroimaging_processor/Volumetry/$sub2process/')"

	python3 -c "from createPDFreport_spanish import *; createPDFreport_spanish(patient_age=$age,region='seg',metric='vol',subjectANDoutput_dir='/home/neurocogn/N1.0Dir/NezihNiegu/neuroimaging_processor/Volumetry/$sub2process/')"
	python3 -c "from createPDFreport_spanish import *; createPDFreport_spanish(patient_age=$age,region='hippo',metric='vol',subjectANDoutput_dir='/home/neurocogn/N1.0Dir/NezihNiegu/neuroimaging_processor/Volumetry/$sub2process/')"
	python3 -c "from createPDFreport_spanish import *; createPDFreport_spanish(patient_age=$age,region='brainstem',metric='vol',subjectANDoutput_dir='/home/neurocogn/N1.0Dir/NezihNiegu/neuroimaging_processor/Volumetry/$sub2process/')"
}

recon_report $1 $2 
