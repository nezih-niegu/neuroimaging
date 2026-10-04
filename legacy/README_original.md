# neuroimaging

#### This is a set of python, r and bash scripts that uses the software freesurfer to generate laboratory reports of in .html and .pdf format.

#### The bash script recon_report.sh converts DICOM images to .nii files that are going to be processed by the command recon-all of free surfer, then the segmentations and parcellations are translated to numeric data. Finally the script runs the python files to obtain thickness, surfaces and volumes of the different brain ROIs (hippocampal subfields, right hemisphere, left hemisphere, brainstem, and subcortical regions).

#### Python scripts extract data obtained from the ICBM database, that were also processed previously in freesurfer and formatted using r scripts, to obtain normal parameters for the brain ROIs. A linear regression model with prediction intervals is characterise the distribution of ICBM, and to compare a single subject or patient to the distribution. Finally, the data is represented in terms of percentiles in a table contained .html/.pdf, so it can be delivered to the clinician that requested the quantified analysis of the brain areas.
   
