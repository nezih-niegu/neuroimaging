scatters_vol_aseg <- function(region) {

  library(tidyverse)
  library(openxlsx)
  
  #importing ages and sex
  T_1.5 <- read.csv("C:/Users/Victor/Documents/Universitaeten/TEC/Clínicas/8° trimestre/Profesor TEC/Caraza/volumetria/volumetry/batch_1/PPMI_T1_controls_1.5T_9_10_2020.csv")
  T_3 <- read.csv("C:/Users/Victor/Documents/Universitaeten/TEC/Clínicas/8° trimestre/Profesor TEC/Caraza/volumetria/volumetry/batch_1/PPMI_T1_controls_3T_9_10_2020.csv")
  batch0 <- read.xlsx("C:/Users/Victor/Documents/Universitaeten/TEC/Clínicas/8° trimestre/Profesor TEC/Caraza/volumetria/volumetry/MRI_subjects_processed_data2.xlsx",'Sheet1')
  
  #aseg volumes of batch 0
  batch0_aseg <- as.data.frame(read_tsv("C:/Users/Victor/Documents/Universitaeten/TEC/Clínicas/8° trimestre/Profesor TEC/Caraza/volumetria/volumetry/segstats_ICBM.txt"))
  batch0_aseg$`Measure:volume` <- substr(batch0_aseg$`Measure:volume`,61,63)
  colnames(batch0_aseg)[1] <- "Num"
  colnames(batch0_aseg) <- str_replace_all(colnames(batch0_aseg),"-","_")
  colnames(batch0_aseg) <- str_replace_all(colnames(batch0_aseg),"3","thi")
  colnames(batch0_aseg) <- str_replace_all(colnames(batch0_aseg),"4","four")
  colnames(batch0_aseg) <- str_replace_all(colnames(batch0_aseg),"5","fif")
  batch0_withage <- merge(batch0_aseg[, c("Num",region)],
                          batch0[, c("Num", "Age")])
  #p <- ggplot(batch0_withage, aes(x=Age,y=`Left_Lateral_Ventricle`))
  #p + geom_point()
  
  #aseg volumes of batch 1 folder 1
  folder1_aseg <- as.data.frame(read_tsv("C:/Users/Victor/Documents/Universitaeten/TEC/Clínicas/8° trimestre/Profesor TEC/Caraza/volumetria/volumetry/batch_1/folder_1/asegstats_vol_2020-09-25_1732.txt"))
  folder1_aseg$`Measure:volume` <- substr(folder1_aseg$`Measure:volume`,6,9)
  colnames(folder1_aseg)[1] <- "Subject"
  colnames(folder1_aseg) <- str_replace_all(colnames(folder1_aseg),"-","_")
  colnames(folder1_aseg) <- str_replace_all(colnames(folder1_aseg),"3","thi")
  colnames(folder1_aseg) <- str_replace_all(colnames(folder1_aseg),"4","four")
  colnames(folder1_aseg) <- str_replace_all(colnames(folder1_aseg),"5","fif")
  T_combined <- rbind(T_1.5,T_3)
  folder1_withage <- merge(folder1_aseg[, c("Subject",region)],
                          T_combined[, c("Subject", "Age")])
  
  #aseg volumes of batch 1 folder 2
  folder2_aseg <- as.data.frame(read_tsv("C:/Users/Victor/Documents/Universitaeten/TEC/Clínicas/8° trimestre/Profesor TEC/Caraza/volumetria/volumetry/batch_1/folder_2/asegstats_vol_2020-09-26_1111.txt"))
  folder2_aseg$`Measure:volume` <- substr(folder2_aseg$`Measure:volume`,6,9)
  colnames(folder2_aseg)[1] <- "Subject"
  colnames(folder2_aseg) <- str_replace_all(colnames(folder2_aseg),"-","_")
  colnames(folder2_aseg) <- str_replace_all(colnames(folder2_aseg),"3","thi")
  colnames(folder2_aseg) <- str_replace_all(colnames(folder2_aseg),"4","four")
  colnames(folder2_aseg) <- str_replace_all(colnames(folder2_aseg),"5","fif")
  folder2_withage <- merge(folder2_aseg[, c("Subject",region)],
                           T_combined[, c("Subject", "Age")])
  
  
  region_volumes <- rbind(batch0_withage[,2:3],folder1_withage[,2:3],folder2_withage[,2:3])
  p <- ggplot(region_volumes, aes_string(x="Age",y=region))
  p <- p + geom_point()
  print(p)
  ggsave(p, file=paste('C:/Users/Victor/Documents/Universitaeten/TEC/Clínicas/8° trimestre/Profesor TEC/Caraza/volumetria/volumetry/plots_vol_aseg/',region, ".jpeg", sep=''), scale=2)
}

batch0_aseg <- as.data.frame(read_tsv("C:/Users/Victor/Documents/Universitaeten/TEC/Clínicas/8° trimestre/Profesor TEC/Caraza/volumetria/volumetry/segstats_ICBM.txt"))
batch0_aseg$`Measure:volume` <- substr(batch0_aseg$`Measure:volume`,61,63)
colnames(batch0_aseg)[1] <- "Num"
colnames(batch0_aseg) <- str_replace_all(colnames(batch0_aseg),"-","_")
colnames(batch0_aseg) <- str_replace_all(colnames(batch0_aseg),"3","thi")
colnames(batch0_aseg) <- str_replace_all(colnames(batch0_aseg),"4","four")
colnames(batch0_aseg) <- str_replace_all(colnames(batch0_aseg),"5","fif")
regions <- colnames(batch0_aseg)

for (i in regions[2:67]) {
  scatters_vol_aseg(i)
}
